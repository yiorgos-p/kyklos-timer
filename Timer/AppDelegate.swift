import Cocoa
import SwiftUI
import Combine
import UserNotifications
import Carbon.HIToolbox

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// SwiftUI installs its own object as NSApp.delegate, so views reach this one through here instead.
    private(set) static weak var shared: AppDelegate?

    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var viewModel: TimerViewModel!
    var timerHostingController: NSHostingController<ContentView>!
    var cancellables: Set<AnyCancellable> = []
    var mainWindowController: NSWindowController?
    private var globalShortcut: GlobalHotKey?
    private var registeredShortcut: GlobalShortcut?
    private var globalShortcutSuspended = false
    /// False when the shortcut is on but macOS wouldn't register it, usually because another app already uses it.
    private(set) var globalShortcutWorks = true
    private var showsInDock: Bool?
    private var presetMinutes: [TimerPhase: Int]?
    private var minimalPanel: NSPanel?
    private var lastMinimalMode: String?
    private var lastTimerState = TimerState.stopped

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        Self.shared = self

        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
        }

        // Initialize the timer with the saved Focus preset.
        viewModel = TimerViewModel(duration: Double(TimerPhase.focus.minutes))

        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = ""
            button.action = #selector(togglePopover(_:))
        }

        // Create the popover
        timerHostingController = NSHostingController(
            rootView: ContentView(viewModel: viewModel)
        )
        timerHostingController.sizingOptions = []

        popover = NSPopover()
        popover.animates = true
        popover.contentViewController = timerHostingController
        popover.contentSize = timerHostingController.sizeThatFits(
            in: NSSize(width: 360, height: 10_000)
        )
        popover.behavior = .transient

        // Keep the menu bar title in sync with the timer
        Publishers.CombineLatest4(
            viewModel.$remainingTime,
            viewModel.$timerState,
            viewModel.$overtime,
            viewModel.$task
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.updateStatusBarTitle()
        }
        .store(in: &cancellables)

        // Apply settings now, and again whenever they change.
        applySettings()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applySettings()
            }
            .store(in: &cancellables)

        // Switch to and from the minimal timer as sessions start and stop.
        viewModel.$timerState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.timerStateDidChange()
            }
            .store(in: &cancellables)

        if minimalMode == "always" {
            showMinimalTimer()
        } else {
            showMainWindow()
        }
    }

    // Clicking the Dock icon brings the window back after it was closed (the floating pill doesn't count).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if mainWindowController?.window?.isVisible != true {
            showMainWindow()
        }
        return true
    }

    // Show the "Time's up" banner even when the app is in front.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    @objc func togglePopover(_ sender: Any?) {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(sender)
            } else {
                // The menu bar item always opens the popover. An open window fades out as it does,
                // so there's one timer on screen and it seems to go back into the menu bar.
                if let window = mainWindowController?.window, window.isVisible, !window.isMiniaturized {
                    fadeOut(window)
                }

                popover.contentSize = timerHostingController.sizeThatFits(
                    in: NSSize(width: 360, height: 10_000)
                )
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.becomeKey()
                clearInitialFocus(in: popover.contentViewController?.view.window)
            }
        }
    }

    func updateStatusBarTitle() {
        if let button = statusItem.button {
            var title = viewModel.displayTime

            if viewModel.timerState == .paused {
                title = "⏸ " + title
            }

            // While a session is on, show what it's for, so a glance at the menu bar is a reminder.
            let task = viewModel.task.trimmingCharacters(in: .whitespaces)
            if viewModel.timerState != .stopped, !task.isEmpty {
                title += " · " + (task.count > 24 ? String(task.prefix(23)) + "…" : task)
            }

            // Create an attributed string with monospace font
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            ]
            if viewModel.timerState == .finished {
                attributes[.foregroundColor] = NSColor.systemOrange
            }
            let style = UserDefaults.standard.string(forKey: "menuBarStyle") ?? "time"

            // "off" hides the menu bar item; the Dock icon then stays on so Anchor can still be reached.
            statusItem.isVisible = style != "off"
            if style == "off", popover.isShown {
                popover.performClose(nil)
            }

            button.image = style == "time" ? nil : statusCircleImage()
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(
                string: style == "circle" ? "" : (style == "both" ? " " : "") + title,
                attributes: attributes
            )
            button.setAccessibilityLabel(title)
        }
    }

    /// A small pie that empties as the session runs: green, then yellow with a third left, red for the last tenth.
    private func statusCircleImage() -> NSImage {
        let state = viewModel.timerState
        let fraction: CGFloat
        let color: NSColor

        switch state {
        case .stopped:
            fraction = 0
            color = .secondaryLabelColor
        case .paused:
            fraction = viewModel.progress
            color = .systemGray
        case .running:
            fraction = viewModel.progress
            color = fraction > 1.0 / 3.0 ? .systemGreen : fraction > 0.1 ? .systemYellow : .systemRed
        case .finished:
            fraction = 1
            color = .systemRed
        }

        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let ringRect = rect.insetBy(dx: 1.5, dy: 1.5)
            let ring = NSBezierPath(ovalIn: ringRect)
            ring.lineWidth = 1.5
            color.setStroke()
            ring.stroke()

            if fraction > 0 {
                let center = NSPoint(x: rect.midX, y: rect.midY)
                let pie = NSBezierPath()
                pie.move(to: center)
                pie.appendArc(
                    withCenter: center,
                    radius: ringRect.width / 2 - 2,
                    startAngle: 90,
                    endAngle: 90 - 360 * fraction,
                    clockwise: true
                )
                pie.close()
                color.setFill()
                pie.fill()
            }

            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Settings

    private func applySettings() {
        updateGlobalShortcut()
        updateStatusBarTitle()
        updateAppearance()

        // A preset changed in Settings: show its new length now, unless the timer is in use.
        let presets = Dictionary(uniqueKeysWithValues: TimerPhase.allCases.map { ($0, $0.minutes) })
        if let presetMinutes, presetMinutes[viewModel.phase] != presets[viewModel.phase], viewModel.timerState == .stopped {
            viewModel.setPhase(viewModel.phase)
        }
        presetMinutes = presets

        // Minimal Mode changed in Settings: switch now rather than at the next session.
        let mode = minimalMode
        if let lastMinimalMode, mode != lastMinimalMode {
            switch mode {
            case "always":
                showMinimalTimer()
            case "start" where viewModel.timerState != .stopped:
                showMinimalTimer()
            case "off" where isShowingMinimalTimer:
                showMainWindow()
            default:
                break
            }
        }
        lastMinimalMode = mode

        // With the menu bar item off, the Dock icon is the way back in, so it stays on whatever the setting says.
        let menuBarOff = UserDefaults.standard.string(forKey: "menuBarStyle") == "off"
        let showInDock = menuBarOff || UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true

        // Only act on a real change: this runs on every settings write, including each keystroke in the task field.
        guard showInDock != showsInDock else {
            return
        }

        let isFirstApply = showsInDock == nil
        showsInDock = showInDock
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)

        // Switching the Dock icon off sends the app to the background; keep its windows in front.
        if !isFirstApply {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.filter(\.isVisible).forEach { $0.orderFrontRegardless() }
            }
        }
    }

    /// "system" follows macOS Light/Dark (including Auto), or the user can pin either one.
    private func updateAppearance() {
        let appearance: NSAppearance?

        switch UserDefaults.standard.string(forKey: "appearance") {
        case "light":
            appearance = NSAppearance(named: .aqua)
        case "dark":
            appearance = NSAppearance(named: .darkAqua)
        default:
            appearance = nil
        }

        if NSApp.appearance?.name != appearance?.name {
            NSApp.appearance = appearance
            // The popover otherwise takes its look from the menu bar, not the app.
            popover.appearance = appearance
        }
    }

    // MARK: - Global shortcut

    /// The saved shortcut (Control-Option-A unless changed) starts, pauses or resumes the timer from any app.
    func updateGlobalShortcut() {
        let enabled = UserDefaults.standard.object(forKey: "globalShortcutEnabled") as? Bool ?? true
        let wanted = enabled && !globalShortcutSuspended ? GlobalShortcut.saved : nil

        guard wanted != registeredShortcut else {
            return
        }

        // Let go of the old keys first, so registering the same keys again can't clash with itself.
        globalShortcut = nil
        registeredShortcut = wanted

        if let wanted {
            globalShortcut = GlobalHotKey(keyCode: wanted.keyCode, modifiers: wanted.modifiers) { [weak self] in
                self?.viewModel.toggleTimer()
            }
        }

        globalShortcutWorks = wanted == nil || globalShortcut != nil
    }

    /// Settings turns the shortcut off while recording a new one, so pressing the current keys doesn't start the timer.
    func setGlobalShortcutSuspended(_ suspended: Bool) {
        globalShortcutSuspended = suspended
        updateGlobalShortcut()
    }

    // MARK: - Main window

    func showMainWindow() {
        if let popover, popover.isShown {
            popover.performClose(nil)
        }
        minimalPanel?.orderOut(nil)

        NSApp.activate(ignoringOtherApps: true)

        if let window = mainWindowController?.window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            if !window.isVisible {
                window.alphaValue = 0
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            fadeIn(window)
            clearInitialFocus(in: window)
            return
        }

        let hostingController = NSHostingController(
            rootView: ContentView(viewModel: viewModel, presentation: .window)
        )
        // The window is sized by fitMainWindowToContent, not by SwiftUI constraints.
        hostingController.sizingOptions = []
        // Turn the view's .toolbar into the window's real toolbar, drawn by the system.
        hostingController.sceneBridgingOptions = [.toolbars]

        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        if #available(macOS 26.0, *) {
            // The whole window is one glass surface (drawn by ContentView), so it needs to see through.
            window.isOpaque = false
            window.backgroundColor = .clear
        }
        window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Timer"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.setContentSize(fittingWindowSize(for: hostingController))
        window.setFrameAutosaveName("MainWindow")
        if window.setFrameUsingName("MainWindow") {
            // Keep the saved position but not a saved size, which may be from an older layout.
            fitMainWindowToContent(window: window, animate: false)
        } else {
            window.center()
        }
        applyWindowLevel(to: window)

        let controller = NSWindowController(window: window)
        mainWindowController = controller
        controller.showWindow(nil)
        window.orderFrontRegardless()
        clearInitialFocus(in: window)
    }

    /// Counts fades, so a fade-out that finishes after the window was brought back doesn't hide it again.
    private var windowFade = 0

    private func fadeOut(_ window: NSWindow) {
        windowFade += 1
        let fade = windowFade

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard self?.windowFade == fade else {
                return
            }
            window.orderOut(nil)
            window.alphaValue = 1
        }
    }

    private func fadeIn(_ window: NSWindow) {
        windowFade += 1

        guard window.alphaValue < 1 else {
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 1
        }
    }

    /// Resizes the window to fit its content, keeping the top edge where it is.
    func fitMainWindowToContent() {
        guard let window = mainWindowController?.window else {
            return
        }

        // Wait a turn so SwiftUI has applied the change being resized for.
        DispatchQueue.main.async { [weak self] in
            self?.fitMainWindowToContent(window: window, animate: true)
        }
    }

    private func fitMainWindowToContent(window: NSWindow, animate: Bool) {
        guard let hostingController = window.contentViewController as? NSHostingController<ContentView> else {
            return
        }

        // The content fills the whole window under a transparent title bar, and its fitting size
        // already includes the title bar's safe area, so the frame is exactly that size.
        let size = fittingWindowSize(for: hostingController)
        let frame = NSRect(
            x: window.frame.minX,
            y: window.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )

        if frame != window.frame {
            window.setFrame(frame, display: true, animate: animate)
        }
    }

    private func fittingWindowSize(for hostingController: NSHostingController<ContentView>) -> NSSize {
        hostingController.sizeThatFits(in: NSSize(width: 360, height: 10_000))
    }

    /// Don't start with the cursor in the task field, where it would swallow the Space shortcut.
    private func clearInitialFocus(in window: NSWindow?) {
        DispatchQueue.main.async {
            window?.makeFirstResponder(nil)
        }
    }

    func applyWindowLevel() {
        if let window = mainWindowController?.window {
            applyWindowLevel(to: window)
        }
    }

    private func applyWindowLevel(to window: NSWindow) {
        let keepOnTop = UserDefaults.standard.bool(forKey: "keepWindowOnTop")
        window.level = keepOnTop ? .floating : .normal
    }

    // MARK: - Minimal timer

    /// "off", "start" (the pill replaces the window while a session is on) or "always".
    private var minimalMode: String {
        UserDefaults.standard.string(forKey: "minimalMode") ?? "off"
    }

    private var isShowingMinimalTimer: Bool {
        minimalPanel?.isVisible == true
    }

    /// Hides the window and shows the small floating pill instead.
    func showMinimalTimer() {
        if let popover, popover.isShown {
            popover.performClose(nil)
        }
        mainWindowController?.window?.orderOut(nil)

        let panel = minimalPanel ?? makeMinimalPanel()
        minimalPanel = panel
        panel.orderFrontRegardless()
    }

    /// The pill doesn't take the keyboard by itself; this hands it over while the minutes are typed.
    func makeMinimalTimerKey() {
        minimalPanel?.makeKey()
    }

    private func timerStateDidChange() {
        // Read the current state rather than each published value: going from "time's up" to the next phase
        // passes through .stopped for an instant, which shouldn't flash the full window.
        let state = viewModel.timerState
        let previous = lastTimerState
        lastTimerState = state

        guard state != previous else {
            return
        }

        if state == .running, previous == .stopped || previous == .finished, minimalMode != "off" {
            showMinimalTimer()
        } else if state == .stopped, minimalMode == "start", isShowingMinimalTimer {
            showMainWindow()
        }
    }

    private func makeMinimalPanel() -> NSPanel {
        let size = MinimalTimerView.size
        let panel = MinimalPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Clicking its button shouldn't take the keyboard away from the app being worked in.
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let hostingView = FirstMouseHostingView(rootView: MinimalTimerView(viewModel: viewModel))
        let cornerRadius = size.height / 2

        if #available(macOS 26.0, *) {
            // Real Liquid Glass, so it follows the Liquid Glass setting in System Settings.
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = hostingView
            panel.contentView = glass
        } else {
            // A behind-window blur ignores layer masks, so the capsule shape is a mask image.
            let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            background.material = .popover
            background.blendingMode = .behindWindow
            background.state = .active
            background.maskImage = NSImage(size: size, flipped: false) { rect in
                NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
                return true
            }
            hostingView.frame = background.bounds
            hostingView.autoresizingMask = [.width, .height]
            background.addSubview(hostingView)
            panel.contentView = background
        }

        panel.setFrameAutosaveName("MinimalTimer")
        if !panel.setFrameUsingName("MinimalTimer") {
            // First time: the top-right corner, just under the menu bar.
            let screen = NSScreen.main?.visibleFrame ?? .zero
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 16))
        }
        panel.setContentSize(size)

        return panel
    }
}

// MARK: - Minimal timer panel

/// Borderless panels can't become key by default, which SwiftUI controls need to work reliably.
private final class MinimalPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}

/// Lets the pill's button work on the first click, without first bringing Anchor to the front.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

// MARK: - Global shortcut setting

/// The global shortcut as saved in Settings: a Carbon key code and modifier mask, plus the key's label for display.
struct GlobalShortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyName: String

    static let standard = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_A),
        modifiers: UInt32(controlKey | optionKey),
        keyName: "A"
    )

    static var saved: GlobalShortcut {
        let defaults = UserDefaults.standard

        guard let keyName = defaults.string(forKey: "globalShortcutKey") else {
            return .standard
        }

        return GlobalShortcut(
            keyCode: UInt32(defaults.integer(forKey: "globalShortcutKeyCode")),
            modifiers: UInt32(defaults.integer(forKey: "globalShortcutModifiers")),
            keyName: keyName
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(Int(keyCode), forKey: "globalShortcutKeyCode")
        defaults.set(Int(modifiers), forKey: "globalShortcutModifiers")
        defaults.set(keyName, forKey: "globalShortcutKey")
    }

    /// In Apple's usual order, like ⌃⌥⇧⌘A.
    var displayString: String {
        let symbols: [(Int, String)] = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        return symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + keyName
    }
}

extension GlobalShortcut {
    /// Reads a key press from the shortcut recorder. It needs ⌘ or ⌃ plus one more modifier,
    /// so the shortcut can't take over typing (⌥ alone types accented letters) or a common app shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }

        let count = [controlKey, optionKey, shiftKey, cmdKey].filter { modifiers & $0 != 0 }.count
        guard count >= 2, modifiers & (controlKey | cmdKey) != 0 else {
            return nil
        }

        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(modifiers), keyName: Self.keyName(for: event))
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
    ]

    private static func keyName(for event: NSEvent) -> String {
        if let name = specialKeyNames[Int(event.keyCode)] {
            return name
        }

        // The key's own character on the current layout, without Shift or Option changing it.
        let character = event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        return character.isEmpty ? "Key \(event.keyCode)" : character
    }
}

// MARK: - Global hot key

/// A system-wide keyboard shortcut. Carbon's hot key API works inside the sandbox and needs no Accessibility permission.
private final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )

        // "ANCR"
        let hotKeyID = EventHotKeyID(signature: OSType(0x414E_4352), id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard handlerStatus == noErr, registerStatus == noErr else {
            // Another app already owns this shortcut.
            return nil
        }
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}
