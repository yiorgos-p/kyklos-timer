import AppKit
import AVFoundation
import Combine
import UserNotifications

final class TimerViewModel: ObservableObject {
    /// Whole seconds left, rounded up: a fresh 25-minute timer reads 25:00 and the alarm goes off the instant it would read 00:00.
    @Published private(set) var remainingTime: Int
    @Published var timerDuration: Double
    @Published private(set) var timerState: TimerState = .stopped

    // Time left is always measured against ContinuousClock, which keeps counting while the Mac sleeps
    // and ignores manual clock changes. The display timer only decides when to redraw, never how much time has passed.
    private let clock = ContinuousClock()
    private var endInstant: ContinuousClock.Instant?
    private var pausedRemaining: Duration
    private var tickTimer: Timer?
    private var activity: NSObjectProtocol?
    private var wakeObservers: [NSObjectProtocol] = []
    private var audioPlayer: AVAudioPlayer?

    init(duration: Double) {
        self.timerDuration = duration
        self.pausedRemaining = .seconds(Int(duration) * 60)
        self.remainingTime = Int(duration) * 60
        prepareAlarmSound()
        observeWakeAndClockChanges()
    }

    deinit {
        tickTimer?.invalidate()
        wakeObservers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
    }

    func toggleTimer() {
        switch timerState {
        case .running:
            pauseTimer()
        case .paused:
            resumeTimer()
        case .stopped:
            startTimer()
        }
    }

    func startTimer() {
        run()
    }

    func pauseTimer() {
        guard timerState == .running, let endInstant else {
            return
        }

        pausedRemaining = max(.zero, endInstant - clock.now)
        stopTicking()
        timerState = .paused

        let shown = Self.wholeSeconds(pausedRemaining)
        if remainingTime != shown {
            remainingTime = shown
        }
    }

    func resumeTimer() {
        run()
    }

    func resetTimer() {
        stopTicking()
        timerState = .stopped
        updateRemainingTime()
    }

    func setPresetTimer(minutes: Int) {
        timerDuration = Double(minutes)
        resetTimer()
    }

    func updateRemainingTime() {
        pausedRemaining = .seconds(Int(timerDuration) * 60)
        remainingTime = Self.wholeSeconds(pausedRemaining)
    }

    func timeString(from seconds: Int) -> String {
        let minutes = seconds / 60
        let seconds = seconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Ticking

    private func run() {
        endInstant = clock.now + pausedRemaining
        timerState = .running
        requestNotificationPermission()

        // Without this, App Nap can delay timers by several seconds while the app is in the background.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Counting down a timer"
            )
        }

        tick()
    }

    private func tick() {
        tickTimer?.invalidate()

        guard timerState == .running, let endInstant else {
            return
        }

        let left = endInstant - clock.now

        if left <= .milliseconds(1) {
            finish()
            return
        }

        let shown = Self.wholeSeconds(left)

        if remainingTime != shown {
            remainingTime = shown
        }

        // Fire exactly when the display should change to the next second, rather than on a drifting 1-second repeat.
        let untilNextSecond = left - .seconds(shown - 1)
        let timer = Timer(
            fire: Date(timeIntervalSinceNow: untilNextSecond.timeInterval),
            interval: 0,
            repeats: false
        ) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
        endInstant = nil

        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func finish() {
        resetTimer()
        playAlarmSound()
        postFinishedNotification()
    }

    /// Timers don't fire while the Mac sleeps, so catch up as soon as it wakes or the clock changes.
    private func observeWakeAndClockChanges() {
        let catchUp: (Notification) -> Void = { [weak self] _ in
            self?.tick()
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        wakeObservers = [
            workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: catchUp),
            workspaceCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: catchUp),
            NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main, using: catchUp)
        ]
    }

    private static func wholeSeconds(_ duration: Duration) -> Int {
        // The small margin keeps an exact 1500 s from rounding up to 1501 because of floating-point noise.
        max(0, Int((duration.timeInterval - 0.001).rounded(.up)))
    }

    // MARK: - Alarm

    private func prepareAlarmSound() {
        if let soundURL = Bundle.main.url(forResource: "alarm", withExtension: "mp3") {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: soundURL)
                audioPlayer?.prepareToPlay()
            } catch {
                print("Failed to initialize audio player: \(error)")
            }
        }
    }

    func playAlarmSound() {
        audioPlayer?.currentTime = 0
        audioPlayer?.play()
    }

    // MARK: - Notifications

    /// Notifications need a real app bundle; skip them when running outside one (previews, scripts).
    private var canUseNotifications: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private func requestNotificationPermission() {
        guard canUseNotifications else {
            return
        }

        // Only asks the first time; later calls return the saved answer.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func postFinishedNotification() {
        guard canUseNotifications else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Time's up"
        content.body = "Your \(Int(timerDuration))-minute timer has finished."
        // No sound: the app already plays its own alarm.

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "timer-finished", content: content, trigger: nil)
        )
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
