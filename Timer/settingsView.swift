import SwiftUI
import LaunchAtLogin
import UserNotifications
import Carbon.HIToolbox

struct TimerSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            TimerSettings()
                .tabItem {
                    Label("Timer", systemImage: "timer")
                }

            AboutSettings()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 480)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage("useMouseControls") private var useMouseControls = false
    @AppStorage("zenMode") private var zenMode = false
    @AppStorage("repeatAlarm") private var repeatAlarm = true
    @AppStorage("minimalMode") private var minimalMode = "off"
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("menuBarStyle") private var menuBarStyle = "time"
    @AppStorage("showInDock") private var showInDock = true
    @AppStorage("globalShortcutEnabled") private var globalShortcutEnabled = true
    @State private var notificationsDenied = false
    @State private var shortcutMessage: String?

    var body: some View {
        Form {
            if notificationsDenied {
                Section {
                    notificationsWarning
                }
            }

            Section("Timer") {
                Toggle(isOn: $repeatAlarm) {
                    Text("Repeat alarm")
                    Text("When time's up, ring again every minute until you start the next phase or stop, for up to 10 minutes.")
                }

                Picker(selection: $useMouseControls) {
                    Text("Buttons").tag(false)
                    Text("Mouse").tag(true)
                } label: {
                    Text("Controls")
                    Text("With Mouse, click the dial to start or pause and triple-click it to reset.")
                }

                Toggle(isOn: $zenMode) {
                    Text("Zen Mode")
                    Text("Hide the phase switcher while the timer runs.")
                }
            }

            Section("Window") {
                Picker(selection: $minimalMode) {
                    Text("Off").tag("off")
                    Text("On Start").tag("start")
                    Text("Always").tag("always")
                } label: {
                    Text("Minimal Mode")
                    Text("A small timer that floats above other apps. Double-click it for the full window.")
                }

                Picker("Appearance", selection: $appearance) {
                    Text("Auto").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }

                Picker(selection: $menuBarStyle) {
                    Text("Time").tag("time")
                    Text("Circle").tag("circle")
                    Text("Both").tag("both")
                    Text("Off").tag("off")
                } label: {
                    Text("Menu Bar")
                    Text("The circle empties as time runs out: green, then yellow with a third left, red near the end.")
                }

                // With the menu bar item off, the Dock icon is the only way back in, so it can't be turned off too.
                Toggle(isOn: menuBarStyle == "off" ? .constant(true) : $showInDock) {
                    Text("Show in Dock")
                    Text(
                        menuBarStyle == "off"
                            ? "Stays on while the menu bar item is off, so you can always get back to Anchor."
                            : "When off, Anchor lives in the menu bar and its window."
                    )
                }
                .disabled(menuBarStyle == "off")
            }

            Section("System") {
                LaunchAtLogin.Toggle {
                    Text("Launch at Login")
                }

                LabeledContent {
                    HStack(spacing: 10) {
                        ShortcutRecorder(message: $shortcutMessage)
                            .disabled(!globalShortcutEnabled)

                        Toggle("Global Shortcut", isOn: $globalShortcutEnabled)
                            .labelsHidden()
                    }
                } label: {
                    Text("Global Shortcut")
                    Text("Start, pause, or resume from any app. Click the shortcut to change it.")

                    if let shortcutMessage {
                        Text(shortcutMessage)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            await refreshNotificationStatus()

            if AppDelegate.shared?.globalShortcutWorks == false {
                shortcutMessage = ShortcutRecorder.takenMessage
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await refreshNotificationStatus()
            }
        }
    }

    /// macOS only asks for notification permission once, so if it was turned down, say so and link to the fix.
    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsDenied = settings.authorizationStatus == .denied
    }

    private var notificationsWarning: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.slash.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications are off")

                Text("You won't get a \"Time's up\" banner. Turn on Allow Notifications for Anchor in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open Settings") {
                let bundleID = Bundle.main.bundleIdentifier ?? ""
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

// MARK: - Timer

private struct TimerSettings: View {
    @AppStorage("standardTimer") private var standardTimer = 25
    @AppStorage("shortBreak") private var shortBreak = 5
    @AppStorage("longBreak") private var longBreak = 10
    @AppStorage("sessionsPerLongBreak") private var sessionsPerLongBreak = 4
    @AppStorage("sessionsToday") private var sessionsToday = 0
    @AppStorage("sessionsDay") private var sessionsDay = ""

    var body: some View {
        Form {
            Section("Durations") {
                MinutesRow(title: "Focus", value: $standardTimer, range: 1...TimerViewModel.maximumMinutes)
                MinutesRow(title: "Short Break", value: $shortBreak, range: 1...30)
                MinutesRow(title: "Long Break", value: $longBreak, range: 1...TimerViewModel.maximumMinutes)
            }

            Section("Rhythm") {
                LabeledContent {
                    HStack(spacing: 6) {
                        Text("\(TimerPhase.focusSessionsPerLongBreak)")
                            .monospacedDigit()

                        Stepper(
                            "Sessions before a long break",
                            value: $sessionsPerLongBreak,
                            in: TimerPhase.sessionsPerLongBreakRange
                        )
                        .labelsHidden()
                    }
                } label: {
                    Text("Sessions before a long break")
                    Text("One dot per focus session. Once they're all filled, the next break is a long one.")
                }

                LabeledContent {
                    Button("Reset") {
                        AppDelegate.shared?.viewModel.resetTodaysSessions()
                    }
                    .disabled(sessionsDoneToday == 0)
                } label: {
                    Text("Finished today: \(sessionsDoneToday)")
                        .monospacedDigit()
                    Text("Starts again from zero each day. The ↺ next to the dots resets it too.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sessionsDoneToday: Int {
        sessionsDay == TimerViewModel.todayKey ? sessionsToday : 0
    }
}

/// A preset length: type it or step it, always kept within range.
private struct MinutesRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    private var clamped: Binding<Int> {
        Binding(
            get: { value },
            set: { value = min(range.upperBound, max(range.lowerBound, $0)) }
        )
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: clamped, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 44)

                Text("min")
                    .foregroundStyle(.secondary)

                Stepper(title, value: clamped, in: range)
                    .labelsHidden()
            }
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

            VStack(spacing: 3) {
                Text("Anchor")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(versionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text("A small timer for one thing at a time, with focus and break rhythm, a reminder of what you're working on, and no ads or data collection.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Text("Open source under the GNU GPLv3")
                .font(.caption)
                .foregroundStyle(.secondary)

            Link(destination: URL(string: "https://github.com/YYUUGGOO/Cloud")!) {
                Label("Based on Cloud by David", systemImage: "arrow.up.right.square")
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    private var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info?["CFBundleVersion"] as? String ?? "Unknown"

        return "Version \(version) (Build \(build))"
    }
}

// MARK: - Shortcut recorder

/// Shows the global shortcut; click it, then press the new keys. Escape cancels.
private struct ShortcutRecorder: View {
    static let takenMessage = "macOS wouldn't take this shortcut. Another app may be using it."

    @Binding var message: String?

    // Only here so the button redraws when the shortcut changes.
    @AppStorage("globalShortcutKey") private var savedKeyName = ""
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(isRecording ? "Type shortcut…" : GlobalShortcut.saved.displayString)
                .monospacedDigit()
                .frame(minWidth: 96)
        }
        .help("Click, then press the new shortcut. Escape cancels.")
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        message = nil
        isRecording = true
        AppDelegate.shared?.setGlobalShortcutSuspended(true)

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
            } else if let shortcut = GlobalShortcut(event: event) {
                shortcut.save()
                stopRecording()

                if AppDelegate.shared?.globalShortcutWorks == false {
                    message = Self.takenMessage
                }
            } else {
                message = "Use ⌘ or ⌃ plus at least one more modifier key, like ⌃⌥A."
            }

            // Swallow every key while recording, so nothing else reacts to it.
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil

        if isRecording {
            isRecording = false
            // Registers the new shortcut straight away, so globalShortcutWorks is up to date.
            AppDelegate.shared?.setGlobalShortcutSuspended(false)
        }
    }
}

// MARK: - Preview

#Preview {
    TimerSettingsView()
}
