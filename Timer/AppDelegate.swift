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
    private var popoverResizeTimer: Timer?
    var cancellables: Set<AnyCancellable> = []
    var mainWindowController: NSWindowController?
    private var globalShortcut: GlobalHotKey?
    private var showsInDock: Bool?

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

        showMainWindow()
    }

    // Clicking the Dock icon brings the window back after it was closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
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
        // Only one full timer UI at a time: if the window is open, bring it forward instead of opening the popover.
        if let window = mainWindowController?.window, window.isVisible, !window.isMiniaturized {
            showMainWindow()
            return
        }

        if let button = statusItem.button {
            if popover.isShown {
                stopPopoverResizeAnimation()
                popover.performClose(sender)
            } else {
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

        let showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true

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

    // MARK: - Global shortcut

    /// Control-Option-P starts, pauses or resumes the timer from any app.
    private func updateGlobalShortcut() {
        let enabled = UserDefaults.standard.object(forKey: "globalShortcutEnabled") as? Bool ?? true

        if enabled, globalShortcut == nil {
            globalShortcut = GlobalHotKey(
                keyCode: UInt32(kVK_ANSI_P),
                modifiers: UInt32(controlKey | optionKey)
            ) { [weak self] in
                self?.viewModel.toggleTimer()
            }
        } else if !enabled {
            globalShortcut = nil
        }
    }

    // MARK: - Main window

    func showMainWindow() {
        if let popover, popover.isShown {
            popover.performClose(nil)
        }

        NSApp.activate(ignoringOtherApps: true)

        if let window = mainWindowController?.window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            clearInitialFocus(in: window)
            return
        }

        let hostingController = NSHostingController(
            rootView: ContentView(viewModel: viewModel, presentation: .window)
        )
        // The window is sized by fitMainWindowToContent, not by SwiftUI constraints.
        hostingController.sizingOptions = []

        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
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

    // MARK: - Popover resizing

    func animatePopoverToFitContent() {
        guard
            popover.isShown,
            let timerHostingController
        else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                self.popover.isShown
            else {
                return
            }

            let targetSize = timerHostingController.sizeThatFits(
                in: NSSize(width: 360, height: 10_000)
            )

            guard targetSize != self.popover.contentSize else {
                self.stopPopoverResizeAnimation()
                return
            }

            self.popoverResizeTimer?.invalidate()
            self.popover.animates = false

            let startingSize = self.popover.contentSize
            let startTime = Date.timeIntervalSinceReferenceDate
            let duration = 0.42

            let resizeTimer = Timer(
                timeInterval: 1.0 / 60.0,
                repeats: true
            ) { [weak self] timer in
                guard
                    let self,
                    self.popover.isShown
                else {
                    timer.invalidate()
                    self?.popover.animates = true
                    return
                }

                let elapsed = Date.timeIntervalSinceReferenceDate - startTime
                let progress = min(max(elapsed / duration, 0), 1)
                let easedProgress = progress * progress * (3 - 2 * progress)

                self.popover.contentSize = NSSize(
                    width: startingSize.width
                        + (targetSize.width - startingSize.width)
                        * easedProgress,
                    height: startingSize.height
                        + (targetSize.height - startingSize.height)
                        * easedProgress
                )

                if progress >= 1 {
                    timer.invalidate()
                    self.popover.contentSize = targetSize
                    self.popover.animates = true
                    self.popoverResizeTimer = nil
                }
            }

            self.popoverResizeTimer = resizeTimer
            RunLoop.main.add(resizeTimer, forMode: .common)
        }
    }

    private func stopPopoverResizeAnimation() {
        popoverResizeTimer?.invalidate()
        popoverResizeTimer = nil
        popover?.animates = true
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
