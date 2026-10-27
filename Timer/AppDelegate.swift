import Cocoa
import SwiftUI
import Combine
import UserNotifications
import Carbon.HIToolbox

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var viewModel: TimerViewModel!
    var timerHostingController: NSHostingController<ContentView>!
    private var popoverResizeTimer: Timer?
    var cancellables: Set<AnyCancellable> = []
    var mainWindowController: NSWindowController?
    private var globalShortcut: GlobalHotKey?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
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

        // Turn the global shortcut on or off when it is changed in Settings.
        updateGlobalShortcut()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateGlobalShortcut()
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
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
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
            let attributedTitle = NSAttributedString(string: title, attributes: attributes)

            button.attributedTitle = attributedTitle
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
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hostingController = NSHostingController(
            rootView: ContentView(viewModel: viewModel, presentation: .window)
        )
        // Size the window to the content, including when Zen Mode hides controls.
        hostingController.sizingOptions = [.minSize, .maxSize]

        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Timer"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") {
            window.center()
        }
        applyWindowLevel(to: window)

        let controller = NSWindowController(window: window)
        mainWindowController = controller
        controller.showWindow(nil)
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
