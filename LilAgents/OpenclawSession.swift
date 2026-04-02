import Foundation
import CryptoKit

// MARK: - OpenclawSession
//
// 通过 openclaw Gateway WebSocket 实现流式对话。
// 协议版本 3，连接地址 ws://127.0.0.1:18789
//
// 流程：
//  1. start() — 检查 Gateway 健康（HTTP /health），未运行则启动再 poll
//  2. 握手：等待 server challenge 帧，然后发送 connect req，等待 hello-ok
//  3. send() — sessions.create（首轮）或 sessions.send（后续轮）
//             同时 sessions.messages.subscribe 订阅 chat 事件流
//  4. chat event delta/final → onText / onTurnComplete
//  5. terminate() — sessions.abort + WebSocket 关闭

class OpenclawSession: AgentSession {

    // MARK: - 公开属性（协议要求）

    private(set) var isRunning = false
    private(set) var isBusy = false
    var history: [AgentMessage] = []

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolUse: ((String, [String: Any]) -> Void)?
    var onToolResult: ((String, Bool) -> Void)?
    var onSessionReady: (() -> Void)?
    var onTurnComplete: (() -> Void)?
    var onProcessExit: (() -> Void)?

    // MARK: - 私有状态

    private static let gatewayURL = URL(string: "ws://127.0.0.1:18789")!
    private static let healthURL  = URL(string: "http://127.0.0.1:18789/health")!

    private var wsTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    private var sessionKey: String?          // openclaw sessions.create 返回的 key
    private var connId: String?              // Gateway 握手返回的 connId
    private var isHandshakeDone = false
    private var pendingMessage: String?      // start() 期间缓存的首条消息
    private var challengeNonce: String = ""  // connect.challenge 帧中的 nonce，签名时使用

    private var currentDeltaText = ""        // 当前轮 delta 累积（用于去重）
    private var currentRunId: String?

    // 等待中的 req，key = req id，value = 回调
    private var pendingRequests: [String: ([String: Any]) -> Void] = [:]

    private static var binaryPath: String?
    private var pollTimer: Timer?
    private var gatewayProcess: Process?

    // MARK: - start()

    func start() {
        print("[Openclaw] start()")
        checkGatewayAndConnect()
    }

    // MARK: - Gateway 健康检查 + 自动启动

    private func checkGatewayAndConnect() {
        checkHealth { [weak self] alive in
            guard let self = self else { return }
            if alive {
                print("[Openclaw] Gateway 已运行，直接连接")
                self.connectWebSocket()
            } else {
                print("[Openclaw] Gateway 未运行，尝试启动")
                self.startGateway()
            }
        }
    }

    private func checkHealth(completion: @escaping (Bool) -> Void) {
        let req = URLRequest(url: Self.healthURL, timeoutInterval: 3)
        URLSession.shared.dataTask(with: req) { data, response, _ in
            DispatchQueue.main.async {
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["ok"] as? Bool == true {
                    completion(true)
                } else {
                    completion(false)
                }
            }
        }.resume()
    }

    private func startGateway() {
        // 先找 openclaw binary
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        ShellEnvironment.findBinary(name: "openclaw", fallbackPaths: [
            "\(home)/.nvm/versions/node/v24.14.0/bin/openclaw",
            "\(home)/.local/bin/openclaw",
            "/usr/local/bin/openclaw",
            "/opt/homebrew/bin/openclaw"
        ]) { [weak self] path in
            guard let self = self else { return }
            guard let binaryPath = path else {
                let msg = "openclaw not found.\n\n\(AgentProvider.openclaw.installInstructions)"
                self.onError?(msg)
                self.history.append(AgentMessage(role: .error, text: msg))
                return
            }
            Self.binaryPath = binaryPath
            print("[Openclaw] 找到 binary: \(binaryPath)，执行 gateway start")
            self.runGatewayStart(binaryPath: binaryPath)
        }
    }

    private func runGatewayStart(binaryPath: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["gateway", "start"]
        proc.environment = ShellEnvironment.processEnvironment()
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()

        do {
            try proc.run()
            gatewayProcess = proc
            print("[Openclaw] gateway start 命令已执行，开始 poll health")
        } catch {
            print("[Openclaw] gateway start 启动失败: \(error)")
        }

        // 等 Gateway 就绪，最多 poll 15 次（每次间隔 1s）
        pollHealth(remaining: 15)
    }

    private func pollHealth(remaining: Int) {
        guard remaining > 0 else {
            let msg = "openclaw Gateway 启动超时，请手动运行：openclaw gateway start"
            print("[Openclaw] pollHealth 超时")
            onError?(msg)
            history.append(AgentMessage(role: .error, text: msg))
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.checkHealth { alive in
                if alive {
                    print("[Openclaw] Gateway 就绪，连接 WebSocket")
                    self.connectWebSocket()
                } else {
                    self.pollHealth(remaining: remaining - 1)
                }
            }
        }
    }

    // MARK: - WebSocket 连接 + 握手

    private func connectWebSocket() {
        let session = URLSession(configuration: .default)
        urlSession = session
        let task = session.webSocketTask(with: Self.gatewayURL)
        wsTask = task
        task.resume()
        print("[Openclaw] WebSocket 已启动，等待 challenge 帧")
        receiveNextMessage()
    }

    private func receiveNextMessage() {
        wsTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    if self.isRunning {
                        print("[Openclaw] WebSocket 接收错误: \(error)")
                        self.handleConnectionLost()
                    }
                }
            case .success(let message):
                DispatchQueue.main.async {
                    self.handleIncomingMessage(message)
                }
                // 继续接收下一条
                self.receiveNextMessage()
            }
        }
    }

    private func handleIncomingMessage(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s):  text = s
        case .data(let d):    text = String(data: d, encoding: .utf8) ?? ""
        @unknown default:     return
        }

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[Openclaw] JSON 解析失败: \(text.prefix(100))")
            return
        }

        let frameType = json["type"] as? String ?? ""
        let eventName = json["event"] as? String ?? ""
        print("[Openclaw] 收到帧 type=\(frameType) event=\(eventName)")

        switch frameType {
        case "res":
            handleResFrame(json)

        case "event":
            if eventName == "connect.challenge" {
                // Server 发来 challenge，发送 connect req（nonce 可忽略，本地无 auth）
                print("[Openclaw] 收到 connect.challenge，发送 connect req")
                if let payload = json["payload"] as? [String: Any],
                   let nonce = payload["nonce"] as? String {
                    challengeNonce = nonce
                }
                sendConnectRequest()
            } else {
                handleEventFrame(json)
            }

        default:
            print("[Openclaw] 未知帧类型: \(frameType)")
        }
    }

    // MARK: - Device Identity 结构

    private struct DeviceIdentity {
        let deviceId: String
        let publicKeyPem: String
        let privateKeyPem: String
    }

    // MARK: - Gateway 认证凭据结构

    private struct GatewayCredentials {
        let gatewayToken: String   // openclaw.json gateway.auth.token，用于 connect params auth.token 及 V3 签名
        let deviceToken: String?   // device-auth.json tokens.operator.token，可选
    }

    /// 从本地配置文件读取 gateway auth token 和 device auth token
    private func loadGatewayCredentials() -> GatewayCredentials? {
        let home = FileManager.default.homeDirectoryForCurrentUser

        // 1. 读取 gateway auth token（~/.openclaw/openclaw.json gateway.auth.token）
        let configPath = home.appendingPathComponent(".openclaw/openclaw.json")
        guard let configData = try? Data(contentsOf: configPath),
              let configJson = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let gateway = configJson["gateway"] as? [String: Any],
              let auth = gateway["auth"] as? [String: Any],
              let gatewayToken = auth["token"] as? String,
              !gatewayToken.isEmpty else {
            print("[Openclaw] 未能从 openclaw.json 读取 gateway.auth.token")
            return nil
        }

        // 2. 读取 device auth token（~/.openclaw/identity/device-auth.json tokens.operator.token，可选）
        var deviceToken: String? = nil
        let deviceAuthPath = home.appendingPathComponent(".openclaw/identity/device-auth.json")
        if let deviceAuthData = try? Data(contentsOf: deviceAuthPath),
           let deviceAuthJson = try? JSONSerialization.jsonObject(with: deviceAuthData) as? [String: Any],
           let tokens = deviceAuthJson["tokens"] as? [String: Any],
           let operatorToken = tokens["operator"] as? [String: Any],
           let token = operatorToken["token"] as? String,
           !token.isEmpty {
            deviceToken = token
            print("[Openclaw] 读取 device auth token 成功")
        }

        print("[Openclaw] 读取 gateway credentials 成功，gatewayToken=\(String(gatewayToken.prefix(8)))...")
        return GatewayCredentials(gatewayToken: gatewayToken, deviceToken: deviceToken)
    }

    /// 从 ~/.openclaw/identity/device.json 加载本地 ED25519 密钥对
    private func loadDeviceIdentity() -> DeviceIdentity? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/identity/device.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceId = json["deviceId"] as? String,
              let publicKeyPem = json["publicKeyPem"] as? String,
              let privateKeyPem = json["privateKeyPem"] as? String else {
            print("[Openclaw] 加载 device identity 失败，文件路径: \(path.path)")
            return nil
        }
        return DeviceIdentity(deviceId: deviceId, publicKeyPem: publicKeyPem, privateKeyPem: privateKeyPem)
    }

    /// 将 PEM 字符串（PKCS8 或 SPKI）解码为 DER 字节
    private func derFromPem(_ pem: String) -> Data? {
        let lines = pem.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let base64 = lines.joined()
        return Data(base64Encoded: base64)
    }

    /// Data → base64url（无 padding）
    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func buildAndSignDevice(nonce: String, signatureToken: String) -> [String: Any]? {
        guard let identity = loadDeviceIdentity() else { return nil }

        let signedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let scopes = "operator.read,operator.write"

        // V3 payload 格式（来自 gateway 源码 method-scopes-D3wXggJU.js buildDeviceAuthPayloadV3）
        // signatureToken = authToken（gateway auth token），与 connect params auth.token 保持一致
        let payloadStr = ["v3", identity.deviceId, "openclaw-macos", "ui",
                          "operator", scopes, String(signedAtMs), signatureToken, nonce, "darwin", ""]
                         .joined(separator: "|")
        print("[Openclaw] 签名 payload: \(payloadStr)")

        // 解析 PKCS8 ED25519 私钥
        // PKCS8 ED25519 DER 结构：48 字节，最后 32 字节是私钥原始数据
        guard let privateKeyDER = derFromPem(identity.privateKeyPem) else {
            print("[Openclaw] 私钥 PEM 解码失败")
            return nil
        }
        guard privateKeyDER.count >= 32 else {
            print("[Openclaw] 私钥 DER 长度不足: \(privateKeyDER.count)")
            return nil
        }
        let rawPrivKey = privateKeyDER.suffix(32)
        guard let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawPrivKey) else {
            print("[Openclaw] 创建 ED25519 私钥失败")
            return nil
        }

        // 签名
        guard let signature = try? signingKey.signature(for: Data(payloadStr.utf8)) else {
            print("[Openclaw] ED25519 签名失败")
            return nil
        }
        let sigBase64url = base64url(Data(signature))

        // 解析 SPKI ED25519 公钥
        // SPKI ED25519 DER 结构：44 字节，前 12 字节是固定头 302a300506032b6570032100，后 32 字节是公钥
        guard let publicKeyDER = derFromPem(identity.publicKeyPem) else {
            print("[Openclaw] 公钥 PEM 解码失败")
            return nil
        }
        guard publicKeyDER.count >= 32 else {
            print("[Openclaw] 公钥 DER 长度不足: \(publicKeyDER.count)")
            return nil
        }
        let rawPubKey = publicKeyDER.suffix(32)
        let pubKeyBase64url = base64url(Data(rawPubKey))

        print("[Openclaw] device 签名成功，deviceId=\(identity.deviceId)")
        return [
            "id": identity.deviceId,
            "publicKey": pubKeyBase64url,
            "signature": sigBase64url,
            "signedAt": signedAtMs,
            "nonce": nonce
        ]
    }

    // MARK: - 握手：connect req

    private func sendConnectRequest() {
        // 加载 gateway credentials（必须先于签名，因为 signatureToken = gatewayToken）
        guard let creds = loadGatewayCredentials() else {
            let msg = "openclaw：未能读取 gateway token，请确认 ~/.openclaw/openclaw.json 存在且包含 gateway.auth.token"
            print("[Openclaw] \(msg)")
            onError?(msg)
            return
        }

        // buildAndSignDevice 需要 signatureToken = gatewayToken（V3 payload 第 8 字段）
        guard let device = buildAndSignDevice(nonce: challengeNonce, signatureToken: creds.gatewayToken) else {
            let msg = "openclaw：无法加载 device identity（~/.openclaw/identity/device.json）"
            print("[Openclaw] \(msg)")
            onError?(msg)
            return
        }

        let reqId = UUID().uuidString

        var authDict: [String: Any] = ["token": creds.gatewayToken]
        if let deviceToken = creds.deviceToken {
            authDict["deviceToken"] = deviceToken
        }

        let payload: [String: Any] = [
            "type": "req",
            "id": reqId,
            "method": "connect",
            "params": [
                "minProtocol": 3,
                "maxProtocol": 3,
                "client": [
                    "id": "openclaw-macos",
                    "version": "1.1.1",
                    "platform": "darwin",
                    "mode": "ui",
                    "instanceId": UUID().uuidString
                ],
                "caps": [] as [Any],
                "role": "operator",
                "scopes": ["operator.read", "operator.write"],
                "auth": authDict,
                "device": device
            ] as [String: Any]
        ]

        sendReq(id: reqId, payload: payload) { [weak self] res in
            guard let self = self else { return }
            guard let ok = res["ok"] as? Bool, ok,
                  let resPayload = res["payload"] as? [String: Any] else {
                let errMsg = (res["error"] as? [String: Any])?["message"] as? String ?? "握手失败"
                print("[Openclaw] connect 失败: \(errMsg)")
                self.onError?("openclaw Gateway 握手失败：\(errMsg)")
                return
            }

            if let server = resPayload["server"] as? [String: Any] {
                self.connId = server["connId"] as? String
            }
            print("[Openclaw] 握手成功 connId=\(self.connId ?? "nil")")
            self.isHandshakeDone = true
            self.isRunning = true
            self.onSessionReady?()

            // 如果 start 期间已有消息缓存，立即发送
            if let pending = self.pendingMessage {
                self.pendingMessage = nil
                self.sendTurn(message: pending)
            }
        }
    }

    // MARK: - send()

    func send(message: String) {
        print("[Openclaw] send() isHandshakeDone=\(isHandshakeDone), msg=\(message.prefix(60))")
        if !isHandshakeDone {
            // Gateway/握手还未完成，缓存消息
            pendingMessage = message
            return
        }
        sendTurn(message: message)
    }

    private func sendTurn(message: String) {
        isBusy = true
        currentDeltaText = ""
        currentRunId = nil
        history.append(AgentMessage(role: .user, text: message))

        if let key = sessionKey {
            // 后续轮：先订阅，再 send
            subscribeAndSend(sessionKey: key, message: message)
        } else {
            // 首轮：sessions.create（携带首条消息）
            createSession(message: message)
        }
    }

    // MARK: - sessions.create（首轮）

    private func createSession(message: String) {
        let reqId = UUID().uuidString
        let payload: [String: Any] = [
            "type": "req",
            "id": reqId,
            "method": "sessions.create",
            "params": [
                "message": message
            ] as [String: Any]
        ]

        sendReq(id: reqId, payload: payload) { [weak self] res in
            guard let self = self else { return }
            guard let ok = res["ok"] as? Bool, ok,
                  let resPayload = res["payload"] as? [String: Any],
                  let key = resPayload["key"] as? String else {
                let errMsg = (res["error"] as? [String: Any])?["message"] as? String ?? "sessions.create 失败"
                print("[Openclaw] sessions.create 失败: \(errMsg)")
                self.isBusy = false
                self.onError?("openclaw sessions.create 失败：\(errMsg)")
                return
            }
            print("[Openclaw] sessions.create 成功, key=\(key)")
            self.sessionKey = key
            // 订阅消息流
            self.subscribe(sessionKey: key)
        }
    }

    // MARK: - sessions.messages.subscribe

    private func subscribe(sessionKey: String) {
        let reqId = UUID().uuidString
        let payload: [String: Any] = [
            "type": "req",
            "id": reqId,
            "method": "sessions.messages.subscribe",
            "params": ["key": sessionKey]
        ]

        sendReq(id: reqId, payload: payload) { [weak self] res in
            guard let self = self else { return }
            guard let ok = res["ok"] as? Bool, ok else {
                let errMsg = (res["error"] as? [String: Any])?["message"] as? String ?? "subscribe 失败"
                print("[Openclaw] subscribe 失败: \(errMsg)")
                self.isBusy = false
                self.onError?("openclaw subscribe 失败：\(errMsg)")
                return
            }
            print("[Openclaw] subscribe 成功，等待 chat events")
        }
    }

    // MARK: - 后续轮：subscribe + send

    private func subscribeAndSend(sessionKey: String, message: String) {
        let subId = UUID().uuidString
        let subPayload: [String: Any] = [
            "type": "req",
            "id": subId,
            "method": "sessions.messages.subscribe",
            "params": ["key": sessionKey]
        ]
        sendReq(id: subId, payload: subPayload) { [weak self] res in
            guard let self = self else { return }
            guard let ok = res["ok"] as? Bool, ok else {
                let errMsg = (res["error"] as? [String: Any])?["message"] as? String ?? "subscribe 失败"
                self.isBusy = false
                self.onError?("openclaw subscribe 失败：\(errMsg)")
                return
            }
            // 订阅成功后发送消息
            self.sendMessage(sessionKey: sessionKey, message: message)
        }
    }

    // MARK: - sessions.send

    private func sendMessage(sessionKey: String, message: String) {
        let reqId = UUID().uuidString
        let payload: [String: Any] = [
            "type": "req",
            "id": reqId,
            "method": "sessions.send",
            "params": [
                "key": sessionKey,
                "message": message,
                "idempotencyKey": UUID().uuidString
            ] as [String: Any]
        ]
        sendReq(id: reqId, payload: payload) { res in
            let ok = res["ok"] as? Bool ?? false
            print("[Openclaw] sessions.send 响应 ok=\(ok)")
            if !ok {
                let errMsg = (res["error"] as? [String: Any])?["message"] as? String ?? "sessions.send 失败"
                print("[Openclaw] sessions.send 失败: \(errMsg)")
            }
        }
    }

    // MARK: - 处理 res 帧

    private func handleResFrame(_ json: [String: Any]) {
        guard let reqId = json["id"] as? String else { return }
        if let handler = pendingRequests.removeValue(forKey: reqId) {
            handler(json)
        }
    }

    // MARK: - 处理 event 帧（流式消息）

    private func handleEventFrame(_ json: [String: Any]) {
        guard let eventName = json["event"] as? String else { return }

        if eventName == "chat" {
            guard let chatPayload = json["payload"] as? [String: Any] else { return }
            handleChatEvent(chatPayload)
        }
    }

    private func handleChatEvent(_ payload: [String: Any]) {
        let state = payload["state"] as? String ?? ""
        let runId = payload["runId"] as? String

        switch state {
        case "delta":
            guard let msg = payload["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { return }

            // delta 的 text 是累积全量，提取最新全量后 diff 出增量推给 UI
            var fullText = ""
            for block in content {
                if block["type"] as? String == "text",
                   let t = block["text"] as? String {
                    fullText += t
                }
            }

            // 计算增量（新字符）
            if fullText.count > currentDeltaText.count {
                let newPart = String(fullText.suffix(fullText.count - currentDeltaText.count))
                currentDeltaText = fullText
                onText?(newPart)
            }
            if runId != nil { currentRunId = runId }

        case "final":
            guard let msg = payload["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else {
                // final 无 message 也要结束 turn
                finishTurn(finalText: nil)
                return
            }

            var finalText = ""
            for block in content {
                if block["type"] as? String == "text",
                   let t = block["text"] as? String {
                    finalText += t
                }
            }
            finishTurn(finalText: finalText.isEmpty ? nil : finalText)

        default:
            print("[Openclaw] chat event 未知 state=\(state)")
        }
    }

    private func finishTurn(finalText: String?) {
        isBusy = false
        let text = finalText ?? currentDeltaText
        if !text.isEmpty {
            history.append(AgentMessage(role: .assistant, text: text))
        }
        currentDeltaText = ""
        currentRunId = nil
        print("[Openclaw] turn 完成，onTurnComplete 触发")
        onTurnComplete?()
    }

    // MARK: - terminate()

    func terminate() {
        print("[Openclaw] terminate()")

        // 如果有正在运行的 session，发 abort
        if let key = sessionKey, isBusy {
            let reqId = UUID().uuidString
            let payload: [String: Any] = [
                "type": "req",
                "id": reqId,
                "method": "sessions.abort",
                "params": ["key": key]
            ]
            // 发完即走，不等响应
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let text = String(data: data, encoding: .utf8) {
                wsTask?.send(.string(text)) { _ in }
            }
        }

        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isRunning = false
        isBusy = false
        isHandshakeDone = false
        pendingRequests.removeAll()
    }

    // MARK: - 连接断开处理

    private func handleConnectionLost() {
        print("[Openclaw] 连接断开")
        isRunning = false
        isHandshakeDone = false
        if isBusy {
            isBusy = false
            onError?("openclaw Gateway 连接断开")
            onTurnComplete?()
        }
        onProcessExit?()
    }

    // MARK: - 底层发送 req

    private func sendReq(id: String, payload: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            print("[Openclaw] sendReq JSON 序列化失败 id=\(id)")
            return
        }
        pendingRequests[id] = completion
        wsTask?.send(.string(text)) { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    print("[Openclaw] sendReq 发送失败 id=\(id): \(error)")
                    self?.pendingRequests.removeValue(forKey: id)
                }
            }
        }
    }
}
