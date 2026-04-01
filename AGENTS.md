# lil-agents — Agent Instructions

## 项目概览

macOS menu bar app（Swift 5.0，SwiftUI + AppKit 混合），在屏幕底部展示两个会走路的 AI 角色（Bruce、Jazz），每个角色绑定一个 AI provider 的对话 session。目标平台 macOS 14.0+（Sonoma），通用二进制（Apple Silicon + Intel）。

**Bundle ID:** `com.lilagents.app` · **Version:** 1.1.1 · **Dependency:** Sparkle 2.0 (auto-update only)

---

## 代码结构

```
LilAgents/                  # 全部源码在此
  LilAgentsApp.swift        # @main 入口，AppDelegate，Sparkle updater
  LilAgentsController.swift # CVDisplayLink 动画循环，dock 几何，角色管理
  WalkerCharacter.swift     # 角色状态机：走路物理、弹出气泡、点击检测（~850行）
  TerminalView.swift        # NSTextView 终端 UI，Markdown 渲染，slash 命令（~490行）
  CharacterContentView.swift# SwiftUI 视图，像素级点击判定
  AgentSession.swift        # AgentProvider enum，AgentSession 协议，AgentMessage，TitleFormat
  ClaudeSession.swift       # 持久进程 + NDJSON stream-json 解析
  CodexSession.swift        # 每轮 spawn 新进程，JSONL 解析
  CopilotSession.swift      # 每轮 spawn 新进程，first-turn/follow-up 区分
  GeminiSession.swift       # 每轮 spawn 新进程
  PopoverTheme.swift        # 4 主题：playful/teenageEngineering/wii/iPod
  ShellEnvironment.swift    # zsh login shell 环境捕获与缓存
  Sounds/                   # 9 个音效文件（mp3/m4a），不含代码
lil-agents.xcodeproj/       # Xcode 项目元数据，通常不需手动编辑
appcast.xml                 # Sparkle 更新 feed
```

---

## Session 架构（关键差异）

| Provider | 进程模式 | 解析格式 | 特殊逻辑 |
|----------|----------|----------|----------|
| Claude   | **持久进程**（stdin/stdout pipe 复用） | NDJSON `stream-json` | `--dangerously-skip-permissions`，不能嵌套 |
| Codex    | **每轮 spawn** | JSONL | `execPrompt()` 注入 |
| Copilot  | **每轮 spawn** | JSONL | `useJsonOutput`，首轮/后续轮区分 |
| Gemini   | **每轮 spawn** | 自定义解析 | `isFirstTurn` flag |

---

## 关键约定

### ShellEnvironment
- `ShellEnvironment.processEnvironment()` **必须**移除 `CLAUDECODE` 和 `CLAUDE_CODE_ENTRYPOINT` 环境变量，防止 Claude 进程嵌套报错。
- 环境变量有缓存；修改环境逻辑后需 invalidate 缓存。

### 点击检测
- `WalkerCharacter` 和 `CharacterContentView` 都用 `CGWindowListCreateImage` 做像素 alpha 采样；fallback 是中心 60% hitbox。
- **禁止**改成简单矩形 hit test——会破坏透明角色的点击穿透行为。

### 动画循环
- `CVDisplayLink` → `DispatchQueue.main.async`。
- **所有 UI 更新必须在 main queue**；`CVDisplayLink` 回调本身在后台线程。

### Popover 单例
- 同一时刻只能有一个 popover 打开；`WalkerCharacter` 打开自己的 popover 时会关闭兄弟 popover。

### UserDefaults 持久化键
- `PopoverTheme.current` → `"popoverTheme"`
- `AgentProvider.current` → `"agentProvider"`
- `pinnedScreenIndex` → `LilAgentsController` 中管理
- 修改 key 名会导致用户设置丢失，需 migration。

### 声音
- `WalkerCharacter.soundsEnabled` 是 static，影响全部角色。
- 9 个音效文件名不能随意重命名（代码中硬编码）。

---

## 构建与运行

```bash
# 在 Xcode 打开
open lil-agents.xcodeproj

# 命令行构建（需要 Xcode Command Line Tools）
xcodebuild -project lil-agents.xcodeproj -scheme lil-agents -configuration Debug build

# 运行（构建后）
open build/Debug/lil-agents.app
```

**无测试框架、无 CI、无 lint 配置。** 改动后用 Xcode 手动运行验证。

---

## 添加新 AI Provider 的步骤

1. 在 `AgentSession.swift` 的 `AgentProvider` enum 新增 case
2. 新建 `XxxSession.swift`，遵循 `AgentSession` 协议
3. 在 `LilAgentsController.swift` 的 session 工厂逻辑中注册
4. 在 `PopoverTheme` 中视需要添加主题配色
5. 在 `ShellEnvironment.findBinary()` 中添加 binary 搜索路径

---

## 禁止事项

- 不要在 `CVDisplayLink` 回调中直接操作 UI（必须 dispatch 到 main）
- 不要移除 `CLAUDECODE` 环境变量的剥离逻辑
- 不要将多个 popover 同时打开
- 不要将角色 video 文件（`walk-bruce-01.mov` / `walk-jazz-01.mov`）改名，代码中硬编码
- 不要用矩形 hit test 替代像素 alpha 采样
