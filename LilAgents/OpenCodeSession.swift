import Foundation

class OpenCodeSession: AgentSession {
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var lineBuffer = ""
    private var currentResponseText = ""
    private var sessionID: String?
    private(set) var isRunning = false
    private(set) var isBusy = false
    private static var binaryPath: String?

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolUse: ((String, [String: Any]) -> Void)?
    var onToolResult: ((String, Bool) -> Void)?
    var onSessionReady: (() -> Void)?
    var onTurnComplete: (() -> Void)?
    var onProcessExit: (() -> Void)?

    var history: [AgentMessage] = []

    // MARK: - 进程生命周期

    func start() {
        print("[OpenCode] start() called")

        if let cached = Self.binaryPath {
            print("[OpenCode] start() 使用缓存 binary 路径: \(cached)")
            isRunning = true
            onSessionReady?()
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        print("[OpenCode] start() 开始查找 binary，home=\(home)")

        ShellEnvironment.findBinary(name: "opencode", fallbackPaths: [
            "\(home)/.opencode/bin/opencode",
            "\(home)/.local/bin/opencode",
            "/usr/local/bin/opencode",
            "/opt/homebrew/bin/opencode"
        ]) { [weak self] path in
            guard let self = self else { return }
            guard let binaryPath = path else {
                let msg = "OpenCode CLI not found.\n\n\(AgentProvider.opencode.installInstructions)"
                print("[OpenCode] start() binary 未找到，报错")
                self.onError?(msg)
                self.history.append(AgentMessage(role: .error, text: msg))
                return
            }
            print("[OpenCode] start() binary 找到: \(binaryPath)")
            Self.binaryPath = binaryPath
            self.isRunning = true
            self.onSessionReady?()
        }
    }

    func send(message: String) {
        print("[OpenCode] send() called, isRunning=\(isRunning), message=\(message.prefix(60))")
        guard isRunning, let binaryPath = Self.binaryPath else {
            print("[OpenCode] send() 未就绪，丢弃消息")
            return
        }

        isBusy = true
        currentResponseText = ""
        lineBuffer = ""
        history.append(AgentMessage(role: .user, text: message))

        launchProcess(binaryPath: binaryPath, message: message)
    }

    private func launchProcess(binaryPath: String, message: String) {
        // 构建 CLI 参数：opencode run --format json [--session <id>] <message>
        var args = ["run", "--format", "json"]
        if let sid = sessionID {
            args += ["--session", sid]
            print("[OpenCode] launchProcess() 复用 session: \(sid)")
        } else {
            print("[OpenCode] launchProcess() 首轮对话，无 session ID")
        }
        args.append(message)

        print("[OpenCode] launchProcess() 启动: \(binaryPath) \(args.joined(separator: " ").prefix(120))")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = args
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        proc.environment = ShellEnvironment.processEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self = self else { return }
                print("[OpenCode] 进程退出，exitCode=\(p.terminationStatus), isBusy=\(self.isBusy)")
                self.process = nil
                // 刷新剩余 buffer
                if !self.lineBuffer.isEmpty {
                    self.parseLine(self.lineBuffer)
                    self.lineBuffer = ""
                }
                // 如果正常退出但未触发 step_finish，补触发 onTurnComplete
                if self.isBusy {
                    print("[OpenCode] 进程退出但 isBusy=true，补触发 onTurnComplete")
                    self.isBusy = false
                    if !self.currentResponseText.isEmpty {
                        self.history.append(AgentMessage(role: .assistant, text: self.currentResponseText))
                        self.currentResponseText = ""
                    }
                    self.onTurnComplete?()
                }
                self.onProcessExit?()
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.processOutput(text)
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                print("[OpenCode] stderr: \(text.prefix(200))")
                DispatchQueue.main.async {
                    // opencode 把进度/状态也输出到 stderr，不一定是错误，暂不转发给用户
                    // self?.onError?(text)
                }
            }
        }

        do {
            try proc.run()
            process = proc
            outputPipe = outPipe
            errorPipe = errPipe
            print("[OpenCode] launchProcess() 进程启动成功，PID=\(proc.processIdentifier)")
        } catch {
            isBusy = false
            let msg = "Failed to launch OpenCode CLI: \(error.localizedDescription)\n\n\(AgentProvider.opencode.installInstructions)"
            print("[OpenCode] launchProcess() 进程启动失败: \(error)")
            onError?(msg)
            history.append(AgentMessage(role: .error, text: msg))
        }
    }

    func terminate() {
        print("[OpenCode] terminate() called")
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        isRunning = false
        isBusy = false
    }

    // MARK: - NDJSON 解析

    private func processOutput(_ text: String) {
        lineBuffer += text
        while let newlineRange = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound])
            lineBuffer = String(lineBuffer[newlineRange.upperBound...])
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                parseLine(line)
            }
        }
    }

    private func parseLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[OpenCode] parseLine() JSON 解析失败: \(line.prefix(100))")
            return
        }

        let type = json["type"] as? String ?? ""

        // 所有事件都携带 sessionID，首次提取后保存
        if sessionID == nil, let sid = json["sessionID"] as? String, !sid.isEmpty {
            print("[OpenCode] parseLine() 获取到 sessionID: \(sid)")
            sessionID = sid
        }

        print("[OpenCode] parseLine() type=\(type)")

        switch type {
        case "step_start":
            // 工具步骤开始，可选：触发 thinking bubble（当前忽略）
            break

        case "text":
            // 文本流式输出
            if let part = json["part"] as? [String: Any],
               let text = part["text"] as? String, !text.isEmpty {
                print("[OpenCode] text 事件: \(text.prefix(60))")
                currentResponseText += text
                onText?(text)
            }

        case "tool-input":
            // 工具调用输入
            if let part = json["part"] as? [String: Any] {
                let toolName = part["toolName"] as? String ?? "Tool"
                let input = part["input"] as? [String: Any] ?? [:]
                print("[OpenCode] tool-input: \(toolName)")
                history.append(AgentMessage(role: .toolUse, text: "\(toolName): \(formatToolSummary(toolName: toolName, input: input))"))
                onToolUse?(toolName, input)
            }

        case "tool-output":
            // 工具调用输出
            if let part = json["part"] as? [String: Any] {
                let output = part["output"] as? String ?? ""
                let isError = part["error"] as? Bool ?? false
                let summary = String(output.prefix(80))
                print("[OpenCode] tool-output: isError=\(isError), summary=\(summary.prefix(40))")
                history.append(AgentMessage(role: .toolResult, text: isError ? "ERROR: \(summary)" : summary))
                onToolResult?(summary, isError)
            }

        case "step_finish":
            // 步骤完成
            if let part = json["part"] as? [String: Any] {
                let reason = part["reason"] as? String ?? ""
                print("[OpenCode] step_finish reason=\(reason)")
                if reason == "stop" || reason == "end_turn" {
                    isBusy = false
                    if !currentResponseText.isEmpty {
                        history.append(AgentMessage(role: .assistant, text: currentResponseText))
                        currentResponseText = ""
                    }
                    print("[OpenCode] onTurnComplete 触发")
                    onTurnComplete?()
                }
                // reason == "tool_use" 表示还有工具调用轮次，继续等待
            }

        case "error":
            let msg = (json["part"] as? [String: Any])?["message"] as? String
                ?? json["message"] as? String
                ?? "OpenCode error"
            print("[OpenCode] error 事件: \(msg)")
            isBusy = false
            onError?(msg)
            history.append(AgentMessage(role: .error, text: msg))
            onTurnComplete?()

        default:
            // 忽略未知事件（如 progress、thinking 等）
            print("[OpenCode] 未知事件类型: \(type)")
            break
        }
    }

    private func formatToolSummary(toolName: String, input: [String: Any]) -> String {
        switch toolName {
        case "Bash", "bash":
            return input["command"] as? String ?? ""
        case "Read", "read", "ReadFile":
            return input["file_path"] as? String ?? input["path"] as? String ?? ""
        case "Edit", "Write", "WriteFile":
            return input["file_path"] as? String ?? input["path"] as? String ?? ""
        case "Glob", "glob":
            return input["pattern"] as? String ?? ""
        case "Grep", "grep":
            return input["pattern"] as? String ?? ""
        default:
            if let desc = input["description"] as? String { return desc }
            return input.keys.sorted().prefix(3).joined(separator: ", ")
        }
    }
}
