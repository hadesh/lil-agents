import AppKit

class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class CharacterContentView: NSView {
    weak var character: WalkerCharacter?

    private var dragStarted = false
    private var mouseDownLocation: NSPoint = .zero
    private let dragThreshold: CGFloat = 3.0

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }

        // AVPlayerLayer is GPU-rendered so layer.render(in:) won't capture video pixels.
        // Use CGWindowListCreateImage to sample actual on-screen alpha at click point.
        let screenPoint = window?.convertPoint(toScreen: convert(localPoint, to: nil)) ?? .zero
        // Use the full virtual display height for the CG coordinate flip, not just
        // the main screen. NSScreen coordinates have origin at bottom-left of the
        // primary display, while CG uses top-left. The primary screen's height is
        // the correct basis for the flip across all monitors.
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let flippedY = primaryScreen.frame.height - screenPoint.y

        let captureRect = CGRect(x: screenPoint.x - 0.5, y: flippedY - 0.5, width: 1, height: 1)
        guard let windowID = window?.windowNumber, windowID > 0 else { return nil }

        if let image = CGWindowListCreateImage(
            captureRect,
            .optionIncludingWindow,
            CGWindowID(windowID),
            [.boundsIgnoreFraming, .bestResolution]
        ) {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            var pixel: [UInt8] = [0, 0, 0, 0]
            if let ctx = CGContext(
                data: &pixel, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                if pixel[3] > 30 {
                    return self
                }
                return nil
            }
        }

        // Fallback: accept click if within center 60% of the view
        let insetX = bounds.width * 0.2
        let insetY = bounds.height * 0.15
        let hitRect = bounds.insetBy(dx: insetX, dy: insetY)
        return hitRect.contains(localPoint) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        dragStarted = false
        mouseDownLocation = event.locationInWindow
        let screenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        character?.beginDrag(mouseScreenPoint: screenPoint)
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = event.locationInWindow
        let dx = loc.x - mouseDownLocation.x
        let dy = loc.y - mouseDownLocation.y
        if !dragStarted && (dx * dx + dy * dy) >= dragThreshold * dragThreshold {
            dragStarted = true
        }
        if dragStarted {
            let screenPoint = window?.convertPoint(toScreen: loc) ?? loc
            character?.continueDrag(to: screenPoint)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragStarted {
            character?.endDrag()
        } else {
            character?.endDrag()
            character?.handleClick()
        }
        dragStarted = false
    }

    // MARK: - 右键菜单

    override func rightMouseDown(with event: NSEvent) {
        guard let character = character else { return }
        let menu = NSMenu()

        // 角色名称（不可点击）
        let name = character.videoName.contains("bruce") ? "Bruce" : "Jazz"
        let nameItem = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        nameItem.isEnabled = false
        menu.addItem(nameItem)
        menu.addItem(NSMenuItem.separator())

        // 显示/隐藏当前角色
        let hideTitle = character.isManuallyVisible ? "Hide \(name)" : "Show \(name)"
        let hideItem = NSMenuItem(title: hideTitle, action: #selector(toggleSelf), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        menu.addItem(NSMenuItem.separator())

        // Provider 子菜单
        let providerItem = NSMenuItem(title: "Provider", action: nil, keyEquivalent: "")
        let providerMenu = NSMenu(title: "Provider")
        for (i, provider) in AgentProvider.allCases.enumerated() {
            let item = NSMenuItem(
                title: provider.displayName,
                action: #selector(switchProvider(_:)),
                keyEquivalent: ""
            )
            item.tag = i
            item.state = provider == AgentProvider.current ? .on : .off
            item.target = self
            providerMenu.addItem(item)
        }
        providerItem.submenu = providerMenu
        menu.addItem(providerItem)

        menu.addItem(NSMenuItem.separator())

        // Display 子菜单
        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu(title: "Display")
        let pinnedIdx = character.controller?.pinnedScreenIndex ?? -1

        let autoItem = NSMenuItem(
            title: "Auto (Main Display)",
            action: #selector(switchDisplay(_:)),
            keyEquivalent: ""
        )
        autoItem.tag = -1
        autoItem.state = pinnedIdx == -1 ? .on : .off
        autoItem.target = self
        displayMenu.addItem(autoItem)
        displayMenu.addItem(NSMenuItem.separator())

        for (i, screen) in NSScreen.screens.enumerated() {
            let item = NSMenuItem(
                title: screen.localizedName,
                action: #selector(switchDisplay(_:)),
                keyEquivalent: ""
            )
            item.tag = i
            item.state = pinnedIdx == i ? .on : .off
            item.target = self
            displayMenu.addItem(item)
        }
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        menu.popUp(positioning: nil, at: event.locationInWindow, in: self)
    }

    @objc private func toggleSelf() {
        guard let character = character else { return }
        character.setManuallyVisible(!character.isManuallyVisible)
    }

    @objc private func switchProvider(_ sender: NSMenuItem) {
        let idx = sender.tag
        let allProviders = AgentProvider.allCases
        guard idx < allProviders.count else { return }
        AgentProvider.current = allProviders[idx]

        // 终止所有现有 session，清空 popover/bubble，使新 provider 生效
        character?.controller?.characters.forEach { char in
            char.session?.terminate()
            char.session = nil
            if char.isIdleForPopover { char.closePopover() }
            char.popoverWindow?.orderOut(nil)
            char.popoverWindow = nil
            char.terminalView = nil
            char.thinkingBubbleWindow?.orderOut(nil)
            char.thinkingBubbleWindow = nil
        }

        // 同步更新菜单栏 provider 状态
        if let appDelegate = NSApp.delegate as? AppDelegate,
           let statusMenu = appDelegate.statusItem?.menu {
            for item in statusMenu.items {
                if let sub = item.submenu {
                    for subItem in sub.items where AgentProvider(rawValue: subItem.representedObject as? String ?? "") != nil {
                        subItem.state = subItem.tag == idx ? .on : .off
                    }
                }
            }
        }
    }

    @objc private func switchDisplay(_ sender: NSMenuItem) {
        let idx = sender.tag
        character?.controller?.pinnedScreenIndex = idx

        // 同步更新菜单栏 display 状态
        if let appDelegate = NSApp.delegate as? AppDelegate,
           let statusMenu = appDelegate.statusItem?.menu {
            for item in statusMenu.items {
                if item.title == "Display", let sub = item.submenu {
                    for subItem in sub.items { subItem.state = subItem.tag == idx ? .on : .off }
                }
            }
        }
    }
}
