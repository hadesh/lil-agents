# LilAgents/ — 源码目录说明

> 父文件 `../AGENTS.md` 已覆盖整体架构、构建命令和禁止事项，本文件只补充源码级细节。

---

## 文件职责速查

| 文件 | 核心职责 | 注意点 |
|------|----------|--------|
| `LilAgentsApp.swift` | `@main`，`AppDelegate`，`SPUStandardUpdaterController` | 唯一注册 `CVDisplayLink` 的地方 |
| `LilAgentsController.swift` | 动画循环驱动，dock 几何计算，两角色生命周期 | `pinnedScreenIndex` 在此管理 |
| `WalkerCharacter.swift` | 角色完整状态机（~920 行） | 像素 alpha 点击检测，勿改为矩形；拖拽、右键菜单均在此 |
| `CharacterContentView.swift` | SwiftUI 渲染层，透明窗口 hit-test，右键菜单 | 与 `WalkerCharacter` 共享像素采样逻辑 |
| `TerminalView.swift` | `NSTextView` 终端，Markdown 渲染，流式追加（~490 行） | slash 命令：`/clear` `/copy` `/help` |
| `AgentSession.swift` | `AgentProvider` enum，`AgentSession` 协议，`AgentMessage`，`TitleFormat` | 新增 provider 先改这里 |
| `ClaudeSession.swift` | 持久进程，stdin/stdout pipe，NDJSON `stream-json` | 不可嵌套；环境变量必须剥离 |
| `CodexSession.swift` | 每轮 spawn，`execPrompt()` 多轮注入，JSONL | — |
| `CopilotSession.swift` | 每轮 spawn，`useJsonOutput`，首轮/后续轮区分，JSONL | — |
| `GeminiSession.swift` | 每轮 spawn，`isFirstTurn` flag | 输出格式自定义解析 |
| `PopoverTheme.swift` | 4 主题枚举，`withCharacterColor()`，`withCustomFont()` | key `"popoverTheme"` 存 UserDefaults |
| `ShellEnvironment.swift` | zsh login shell 环境捕获，`findBinary()`，环境缓存 | 必须剥离 `CLAUDECODE`、`CLAUDE_CODE_ENTRYPOINT` |

---

## WalkerCharacter 状态机关键点

- **走路物理**：加速/减速曲线在 `updateWalkingPhysics()` 中，改动需同步调整碰撞边界。
- **气泡弹出**：`showThinkingBubble()` / `hideThinkingBubble()` 由 session 回调触发，不要在动画帧里直接调用。
- **popover 生命周期**：`openPopover()` 先调 `controller?.closeOtherPopovers(except: self)`，再打开自身。
- **拖拽**：
  - `isDragging: Bool` — 拖拽进行中标志，`true` 时 `tick()` 跳过走路物理更新。
  - `dragMouseOffset: NSPoint` — 鼠标按下时相对于窗口左下角的偏移，防止角色跳位。
  - `beginDrag(mouseScreenPoint:)` — 暂停播放，记录偏移；由 `CharacterContentView.mouseDown` 调用。
  - `continueDrag(to:)` — 全屏自由移动，限制在屏幕边界内；由 `CharacterContentView.mouseDragged` 调用。
  - `endDrag()` — 反算 `positionProgress`，用 0.35 s ease-out 动画回到屏幕底部；由 `CharacterContentView.mouseUp` 调用。

## CharacterContentView 右键菜单

`rightMouseDown` 动态构建 `NSMenu`，包含三组项目：

1. **隐藏/显示当前角色**：调用 `toggleSelf()`，通过 `controller?.hideCharacter(self)` / `showCharacter(self)` 切换 `isHidden`。
2. **AI Provider 子菜单**：列出 `AgentProvider.allCases`，调用 `switchProvider(_:)`，终止所有 session/popover，同步菜单栏 `NSMenuItem` 状态。
3. **Display 子菜单**：列出 `NSScreen.screens`，调用 `switchDisplay(_:)`，更新 `controller?.pinnedScreenIndex`，同步菜单栏状态。

## TerminalView 渲染管线

```
AgentSession.onMessage(AgentMessage)
  → WalkerCharacter.appendMessage()
    → TerminalView.appendStreamingText() / finalizeMessage()
      → NSAttributedString (Markdown inline + block)
        → NSTextView append
```

- `appendStreamingText` 必须在 main queue 调用（已在内部 assert）。
- Block-level Markdown（code fence、blockquote）在 `finalizeMessage()` 时整体重渲染。

## PopoverTheme 四主题速查

| case | 显示名 | 背景色调 |
|------|--------|----------|
| `playful` | Peach | 暖橙粉 |
| `teenageEngineering` | Midnight | 深蓝黑 |
| `wii` | Cloud | 浅灰白 |
| `iPod` | Moss | 草绿 |

## ShellEnvironment 缓存失效

```swift
ShellEnvironment.invalidateCache()  // 修改环境逻辑后调用
```

缓存 key 在 `ShellEnvironment.cacheKey`；修改 zsh 调用参数后必须 invalidate。

---

## 扩展 TerminalView slash 命令

1. 在 `TerminalView.handleSlashCommand(_:)` 的 `switch` 中新增 case
2. 在 `/help` 的输出文本中补充说明
3. 命令名用小写，`/` 前缀由调用方统一处理
