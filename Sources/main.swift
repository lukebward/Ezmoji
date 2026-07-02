// Ezmoji — system-wide :shortcode: emoji autocomplete, Slack/Discord style.
// Type `:` then a few letters anywhere; a picker appears; Tab or Enter inserts.
import AppKit
import ApplicationServices
import Darwin
import ServiceManagement

// MARK: - Emoji index

struct EmojiEntry: Decodable {
    let e: String
    let a: [String]
}

final class EmojiIndex {
    struct Item {
        let alias: String
        let emoji: String
    }

    let items: [Item]
    private let byAlias: [String: Item]

    init(entries: [EmojiEntry]) {
        var all: [Item] = []
        var lookup: [String: Item] = [:]
        for entry in entries {
            for alias in entry.a {
                let item = Item(alias: alias.lowercased(), emoji: entry.e)
                all.append(item)
                lookup[item.alias] = item
            }
        }
        items = all.sorted { $0.alias < $1.alias }
        byAlias = lookup
    }

    static func load() -> EmojiIndex? {
        guard let url = dataURL(),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([EmojiEntry].self, from: data)
        else { return nil }
        return EmojiIndex(entries: entries)
    }

    private static func dataURL() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("emoji.json") {
            candidates.append(bundled)
        }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent("emoji.json"))
        candidates.append(exeDir.deletingLastPathComponent().appendingPathComponent("Resources/emoji.json"))
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    func exact(_ query: String) -> Item? {
        byAlias[query.lowercased()]
    }

    // Prefix matches first, then substring matches; deduped by emoji.
    func match(_ query: String, limit: Int = 8) -> [Item] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        var out: [Item] = []
        var seen = Set<String>()
        for item in items where item.alias.hasPrefix(q) {
            if seen.insert(item.emoji).inserted { out.append(item) }
            if out.count >= limit { return out }
        }
        for item in items where item.alias.contains(q) && !item.alias.hasPrefix(q) {
            if seen.insert(item.emoji).inserted { out.append(item) }
            if out.count >= limit { return out }
        }
        return out
    }
}

// MARK: - Per-app exclusions

final class ExclusionList {
    static let shared = ExclusionList(defaults: .standard)

    // Apps with their own :emoji: autocomplete; Ezmoji stays dormant in these out of the box.
    // Deliberately absent: Zoom (shortcodes exist but no keyboard autocomplete), editors like
    // VS Code / Cursor / Zed / Obsidian (plugin-only or none).
    static let seed: [String: String] = [
        // Chat
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "com.hnc.DiscordPTB": "Discord PTB",
        "com.hnc.DiscordCanary": "Discord Canary",
        "ru.keepcoder.Telegram": "Telegram",
        "org.telegram.desktop": "Telegram Desktop",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "org.whispersystems.signal-desktop": "Signal",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams (classic)",
        "im.riot.app": "Element",
        "Mattermost.Desktop": "Mattermost",
        "chat.rocket": "Rocket.Chat",
        "org.zulip.zulip-electron": "Zulip",
        "im.beeper.desktop": "Beeper",
        // Productivity / dev
        "notion.id": "Notion",
        "com.figma.Desktop": "Figma",
        "com.linear": "Linear",
        "com.clickup.desktop-app": "ClickUp",
        "com.electron.asana": "Asana",
        "com.github.GitHubClient": "GitHub Desktop",
    ]

    private let defaults: UserDefaults
    private let key = "excludedApps"
    private(set) var apps: [String: String] // bundle ID → display name

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let stored = defaults.dictionary(forKey: key) as? [String: String] {
            apps = stored
        } else {
            apps = Self.seed
            defaults.set(apps, forKey: key)
        }
    }

    func contains(_ bundleID: String) -> Bool {
        apps[bundleID] != nil
    }

    func toggle(bundleID: String, name: String) {
        if apps[bundleID] != nil {
            apps.removeValue(forKey: bundleID)
        } else {
            apps[bundleID] = name
        }
        defaults.set(apps, forKey: key)
    }

    func remove(bundleID: String) {
        apps.removeValue(forKey: bundleID)
        defaults.set(apps, forKey: key)
    }
}

// MARK: - Caret location (Accessibility API, mouse fallback)

enum CaretLocator {
    // Caret rect in Cocoa (bottom-left origin) screen coordinates.
    static func anchorRect() -> NSRect {
        if let ax = axCaretRect() {
            let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
            return NSRect(x: ax.minX, y: primaryMaxY - ax.maxY, width: max(ax.width, 2), height: max(ax.height, 4))
        }
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x, y: mouse.y - 8, width: 2, height: 18)
    }

    // AX bounds come back in top-left-origin global coordinates.
    private static func axCaretRect() -> CGRect? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        let element = focusedRef as! AXUIElement

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }

        var probe = CFRange(location: max(range.location + range.length - 1, 0), length: 1)
        guard let probeValue = AXValueCreate(.cfRange, &probe) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, probeValue, &boundsRef
        ) == .success,
            let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect),
              rect != .zero, rect.origin.x.isFinite, rect.origin.y.isFinite
        else { return nil }
        return rect
    }
}

// MARK: - Synthetic keystrokes

enum Typist {
    // Marks our own events so the tap lets them pass untouched.
    static let syntheticMarker: Int64 = 0x454D_4F4A // "EMOJ"
    private static let backspaceKey: CGKeyCode = 51
    private static let interEventDelayMicros: UInt32 = 1500

    static func replace(deleteCount: Int, with text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<deleteCount {
            post(CGEvent(keyboardEventSource: source, virtualKey: backspaceKey, keyDown: true))
            post(CGEvent(keyboardEventSource: source, virtualKey: backspaceKey, keyDown: false))
        }
        let units = Array(text.utf16)
        // Events carry a limited unicode payload; chunking keeps long sequences safe.
        for chunk in units.chunked(16) {
            var buffer = chunk
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
            post(down)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
            post(up)
        }
    }

    private static func post(_ event: CGEvent?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        event.post(tap: .cghidEventTap)
        usleep(interEventDelayMicros)
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

// MARK: - Picker panel

final class PickerPanel: NSPanel {
    static let panelWidth: CGFloat = 300
    static let rowHeight: CGFloat = 30
    static let padding: CGFloat = 6

    private let effectView = NSVisualEffectView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        animationBehavior = .none

        effectView.material = .menu
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 10
        effectView.layer?.masksToBounds = true
        contentView = effectView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(matches: [EmojiIndex.Item], selectedIndex: Int, near caret: NSRect) {
        let height = Self.padding * 2 + Self.rowHeight * CGFloat(matches.count)
        setContentSize(NSSize(width: Self.panelWidth, height: height))
        rebuildRows(matches: matches, selectedIndex: selectedIndex, totalHeight: height)
        position(near: caret)
        orderFrontRegardless()
    }

    private func rebuildRows(matches: [EmojiIndex.Item], selectedIndex: Int, totalHeight: CGFloat) {
        effectView.subviews.forEach { $0.removeFromSuperview() }
        for (i, item) in matches.enumerated() {
            let selected = i == selectedIndex
            let rowY = totalHeight - Self.padding - Self.rowHeight * CGFloat(i + 1)
            let row = NSView(frame: NSRect(
                x: Self.padding, y: rowY,
                width: Self.panelWidth - Self.padding * 2, height: Self.rowHeight
            ))
            row.wantsLayer = true
            row.layer?.cornerRadius = 6
            if selected {
                row.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            }

            let emojiLabel = NSTextField(labelWithString: item.emoji)
            emojiLabel.font = .systemFont(ofSize: 18)
            emojiLabel.sizeToFit()
            emojiLabel.setFrameOrigin(NSPoint(x: 8, y: (Self.rowHeight - emojiLabel.frame.height) / 2))
            row.addSubview(emojiLabel)

            let aliasLabel = NSTextField(labelWithString: ":\(item.alias):")
            aliasLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            aliasLabel.textColor = selected ? .white : .labelColor
            aliasLabel.lineBreakMode = .byTruncatingTail
            aliasLabel.sizeToFit()
            let aliasX: CGFloat = 40
            aliasLabel.frame = NSRect(
                x: aliasX,
                y: (Self.rowHeight - aliasLabel.frame.height) / 2,
                width: min(aliasLabel.frame.width, row.frame.width - aliasX - 8),
                height: aliasLabel.frame.height
            )
            row.addSubview(aliasLabel)

            effectView.addSubview(row)
        }
    }

    private func position(near caret: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        var x = caret.minX
        x = min(max(visible.minX + 4, x), visible.maxX - frame.width - 4)
        var topY = caret.minY - 6 // below the caret
        if topY - frame.height < visible.minY {
            topY = caret.maxY + 6 + frame.height // no room: above the caret
        }
        setFrameTopLeftPoint(NSPoint(x: x, y: topY))
    }
}

// MARK: - Event tap controller

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<EmojiTapController>.fromOpaque(refcon).takeUnretainedValue()
    return controller.handle(type: type, event: event)
}

final class EmojiTapController {
    enum State {
        case idle
        case active(query: String)
    }

    private enum Key {
        static let tab: Int = 48
        static let ret: Int = 36
        static let keypadEnter: Int = 76
        static let escape: Int = 53
        static let backspace: Int = 51
        static let up: Int = 126
        static let down: Int = 125
    }

    var paused = false
    private(set) var tapRunning = false

    private var index: EmojiIndex?
    private var tap: CFMachPort?
    private var state: State = .idle
    private var lastTypedWasBoundary = true
    private var matches: [EmojiIndex.Item] = []
    private var selectedIndex = 0
    private var sessionAnchor: NSRect?
    private let panel = PickerPanel()
    private let postQueue = DispatchQueue(label: "Ezmoji.typist")
    private let maxQueryLength = 32

    func start() -> Bool {
        guard tap == nil else { return tapRunning }
        index = EmojiIndex.load()
        guard index != nil else {
            NSLog("Ezmoji: emoji.json not found or unreadable; not starting")
            return false
        }

        func bit(_ t: CGEventType) -> CGEventMask {
            CGEventMask(1) << CGEventMask(t.rawValue)
        }
        let mask = bit(.keyDown) | bit(.leftMouseDown) | bit(.rightMouseDown) | bit(.otherMouseDown)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Ezmoji: failed to create event tap (missing Accessibility/Input Monitoring permission?)")
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        tapRunning = true

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reset()
        }
        return true
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Typist.syntheticMarker {
            return pass
        }
        if paused { return pass }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            lastTypedWasBoundary = true
            reset()
            return pass
        }
        guard type == .keyDown, let ns = NSEvent(cgEvent: event) else { return pass }

        let flags = ns.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !flags.isDisjoint(with: [.command, .control, .option]) {
            lastTypedWasBoundary = true
            reset()
            return pass
        }

        let keyCode = Int(ns.keyCode)
        let chars = ns.characters ?? ""

        switch state {
        case .idle:
            if chars == ":" && lastTypedWasBoundary && !frontAppIsExcluded() {
                state = .active(query: "")
            }
            updateBoundary(chars: chars)
            return pass

        case .active(var query):
            switch keyCode {
            case Key.escape:
                let panelWasVisible = panel.isVisible
                reset()
                return panelWasVisible ? nil : pass
            case Key.tab, Key.ret, Key.keypadEnter:
                if panel.isVisible, matches.indices.contains(selectedIndex) {
                    commit(matches[selectedIndex], deleteCount: query.count + 1)
                    return nil
                }
                reset()
                return pass
            case Key.up:
                if panel.isVisible {
                    moveSelection(-1)
                    return nil
                }
                reset()
                return pass
            case Key.down:
                if panel.isVisible {
                    moveSelection(1)
                    return nil
                }
                reset()
                return pass
            case Key.backspace:
                if query.isEmpty {
                    // They deleted the trigger colon itself.
                    reset()
                    return pass
                }
                query.removeLast()
                state = .active(query: query)
                refresh(query)
                return pass
            default:
                break
            }

            if chars == ":" {
                if !query.isEmpty, let item = index?.exact(query) {
                    // Full `:name:` typed — replace immediately, swallow the closing colon.
                    commit(item, deleteCount: query.count + 1)
                    return nil
                }
                // No such shortcode; this colon may start a fresh session.
                reset()
                state = .active(query: "")
                return pass
            }

            if chars.count == 1, let ch = chars.first, isAliasChar(ch), query.count < maxQueryLength {
                query += chars.lowercased()
                state = .active(query: query)
                refresh(query)
                return pass
            }

            // Space, punctuation, function keys, etc. end the session.
            updateBoundary(chars: chars)
            reset()
            return pass
        }
    }

    private func frontAppIsExcluded() -> Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return ExclusionList.shared.contains(id)
    }

    private func isAliasChar(_ ch: Character) -> Bool {
        ("a"..."z").contains(ch) || ("A"..."Z").contains(ch) || ("0"..."9").contains(ch)
            || ch == "_" || ch == "+" || ch == "-"
    }

    private func updateBoundary(chars: String) {
        if let last = chars.last {
            lastTypedWasBoundary = !(last.isLetter || last.isNumber)
        } else {
            lastTypedWasBoundary = true
        }
    }

    private func refresh(_ query: String) {
        matches = query.isEmpty ? [] : (index?.match(query) ?? [])
        guard !matches.isEmpty else {
            panel.orderOut(nil)
            return
        }
        selectedIndex = 0
        if sessionAnchor == nil {
            sessionAnchor = CaretLocator.anchorRect()
        }
        panel.show(matches: matches, selectedIndex: selectedIndex, near: sessionAnchor!)
    }

    private func moveSelection(_ delta: Int) {
        guard !matches.isEmpty, let anchor = sessionAnchor else { return }
        selectedIndex = (selectedIndex + delta + matches.count) % matches.count
        panel.show(matches: matches, selectedIndex: selectedIndex, near: anchor)
    }

    private func commit(_ item: EmojiIndex.Item, deleteCount: Int) {
        reset()
        let emoji = item.emoji
        postQueue.async {
            Typist.replace(deleteCount: deleteCount, with: emoji)
        }
    }

    private func reset() {
        state = .idle
        matches = []
        selectedIndex = 0
        sessionAnchor = nil
        lastTypedWasBoundary = true
        panel.orderOut(nil)
    }
}

// MARK: - App delegate / menu bar

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let controller = EmojiTapController()
    private var permissionTimer: Timer?
    private var permissionItem: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var disableHereItem: NSMenuItem!
    private var excludedSubmenuItem: NSMenuItem!
    private var lastFrontApp: (id: String, name: String)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        trackFrontmostApp()

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            _ = controller.start()
        } else {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.permissionTimer = nil
                _ = self?.controller.start()
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Ezmoji") {
                button.image = image
            } else {
                button.title = "😊"
            }
        }

        let menu = NSMenu()
        menu.delegate = self

        let title = NSMenuItem(title: "Ezmoji — type :name then ⇥", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        permissionItem = NSMenuItem(
            title: "Accessibility permission…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        permissionItem.target = self
        menu.addItem(permissionItem)

        pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        disableHereItem = NSMenuItem(title: "Disable in current app", action: nil, keyEquivalent: "")
        disableHereItem.target = self
        menu.addItem(disableHereItem)

        excludedSubmenuItem = NSMenuItem(title: "Excluded Apps", action: nil, keyEquivalent: "")
        excludedSubmenuItem.submenu = NSMenu()
        menu.addItem(excludedSubmenuItem)

        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Ezmoji", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // The status-item click may briefly make us the frontmost app, so prefer the live
    // frontmost app but fall back to the last non-self app we saw activate.
    private func trackFrontmostApp() {
        if let app = NSWorkspace.shared.frontmostApplication,
           let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            lastFrontApp = (id, app.localizedName ?? id)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier
            else { return }
            self?.lastFrontApp = (id, app.localizedName ?? id)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if controller.tapRunning {
            permissionItem.title = "Accessibility: granted ✓"
        } else if AXIsProcessTrusted() {
            permissionItem.title = "Tap inactive — check Input Monitoring…"
        } else {
            permissionItem.title = "Grant Accessibility permission…"
        }
        pauseItem.state = controller.paused ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        if let app = NSWorkspace.shared.frontmostApplication,
           let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            lastFrontApp = (id, app.localizedName ?? id)
        }
        if let front = lastFrontApp {
            let excluded = ExclusionList.shared.contains(front.id)
            disableHereItem.title = excluded ? "Disabled in \(front.name)" : "Disable in \(front.name)"
            disableHereItem.state = excluded ? .on : .off
            disableHereItem.action = #selector(toggleDisableHere)
        } else {
            disableHereItem.title = "Disable in current app"
            disableHereItem.state = .off
            disableHereItem.action = nil
        }

        let submenu = excludedSubmenuItem.submenu!
        submenu.removeAllItems()
        let entries = ExclusionList.shared.apps.sorted {
            $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending
        }
        if entries.isEmpty {
            let none = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
            submenu.addItem(none)
        } else {
            for (id, name) in entries {
                let item = NSMenuItem(title: name, action: #selector(removeExcluded(_:)), keyEquivalent: "")
                item.target = self
                item.state = .on
                item.representedObject = id
                submenu.addItem(item)
            }
        }
    }

    @objc private func toggleDisableHere() {
        guard let front = lastFrontApp else { return }
        ExclusionList.shared.toggle(bundleID: front.id, name: front.name)
    }

    @objc private func removeExcluded(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ExclusionList.shared.remove(bundleID: id)
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func togglePause() {
        controller.paused.toggle()
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Ezmoji: launch-at-login toggle failed: \(error)")
        }
    }
}

// MARK: - Self test

func runSelfTest() -> Bool {
    var ok = true
    func check(_ name: String, _ condition: Bool) {
        print("\(condition ? "PASS" : "FAIL")  \(name)")
        if !condition { ok = false }
    }

    guard let index = EmojiIndex.load() else {
        print("FAIL  emoji.json loads")
        return false
    }
    check("emoji.json loads", true)
    check("index has >1500 aliases (\(index.items.count))", index.items.count > 1500)
    check("exact :smile: → 😄", index.exact("smile")?.emoji == "😄")
    check("exact :+1: → 👍", index.exact("+1")?.emoji == "👍")
    check("exact :tada: → 🎉", index.exact("tada")?.emoji == "🎉")
    check("exact :thinking_face: → 🤔", index.exact("thinking_face")?.emoji == "🤔")
    check("exact is case-insensitive", index.exact("TADA")?.emoji == "🎉")
    check("match 'smi' starts with smile", index.match("smi").first?.alias == "smile")
    check("match 'rocke' contains 🚀", index.match("rocke").contains { $0.emoji == "🚀" })
    check("match '' is empty", index.match("").isEmpty)
    check("match 'zzzznope' is empty", index.match("zzzznope").isEmpty)
    check("match dedupes same emoji", index.match("thumbsu").filter { $0.emoji == "👍" }.count == 1)
    check("match caps at 8", index.match("s").count <= 8)

    let suiteName = "dev.lukeward.Ezmoji.selftest"
    let suite = UserDefaults(suiteName: suiteName)!
    suite.removePersistentDomain(forName: suiteName)
    let exclusions = ExclusionList(defaults: suite)
    check("exclusions seed includes Slack", exclusions.contains("com.tinyspeck.slackmacgap"))
    check("exclusions seed includes Discord", exclusions.contains("com.hnc.Discord"))
    exclusions.toggle(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
    check("exclusion toggle removes", !exclusions.contains("com.tinyspeck.slackmacgap"))
    check(
        "exclusion removal persists (no re-seed)",
        !ExclusionList(defaults: suite).contains("com.tinyspeck.slackmacgap")
    )
    exclusions.toggle(bundleID: "com.example.someapp", name: "SomeApp")
    check("exclusion toggle adds", ExclusionList(defaults: suite).contains("com.example.someapp"))
    exclusions.remove(bundleID: "com.example.someapp")
    check("exclusion remove works", !exclusions.contains("com.example.someapp"))
    suite.removePersistentDomain(forName: suiteName)
    return ok
}

// MARK: - Entry point

if CommandLine.arguments.contains("--selftest") {
    exit(runSelfTest() ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
