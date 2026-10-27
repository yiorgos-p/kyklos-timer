import AppKit
import AVFoundation
import Combine
import UserNotifications

final class TimerViewModel: ObservableObject {
    /// Whole seconds left, rounded up: a fresh 25-minute timer reads 25:00 and the alarm goes off the instant it would read 00:00.
    @Published private(set) var remainingTime: Int
    @Published var timerDuration: Double
    @Published private(set) var timerState: TimerState = .stopped
    @Published private(set) var phase: TimerPhase = .focus
    /// Whole seconds since the timer finished, while it waits for the next phase to be started.
    @Published private(set) var overtime = 0
    /// The length of the current run in seconds, so views can show how much of it is left.
    @Published private(set) var sessionLength: Int
    @Published private(set) var completedFocusToday = 0
    @Published var task: String {
        didSet {
            UserDefaults.standard.set(task, forKey: "currentTask")
        }
    }

    // Time left is always measured against ContinuousClock, which keeps counting while the Mac sleeps
    // and ignores manual clock changes. The display timer only decides when to redraw, never how much time has passed.
    private let clock = ContinuousClock()
    private var endInstant: ContinuousClock.Instant?
    private var pausedRemaining: Duration
    private var tickTimer: Timer?
    private var activity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    private var audioPlayer: AVAudioPlayer?
    /// The minute of overtime the alarm last rang for, so each minute rings at most once.
    private var lastAlarmMinute = 0

    /// How long the alarm keeps ringing in overtime, so it doesn't go on all day if nobody is at the Mac.
    private static let alarmRepeatMinutes = 10

    init(duration: Double) {
        self.timerDuration = duration
        self.pausedRemaining = .seconds(Int(duration) * 60)
        self.remainingTime = Int(duration) * 60
        self.sessionLength = Int(duration) * 60
        self.task = UserDefaults.standard.string(forKey: "currentTask") ?? ""
        loadTodaysSessions()
        prepareAlarmSound()
        observeSystemChanges()
    }

    deinit {
        tickTimer?.invalidate()
        observers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
    }

    // MARK: - Derived state

    /// Fraction of the current run still left, from 1 down to 0.
    var progress: Double {
        guard sessionLength > 0 else {
            return 0
        }

        return min(1, Double(remainingTime) / Double(sessionLength))
    }

    /// How much of a 60-minute dial the time left fills, so 25 minutes always looks like 25 minutes
    /// and a 5-minute break looks short. Full once time is up, so the whole ring turns orange.
    var dialFraction: Double {
        timerState == .finished ? 1 : min(1, Double(remainingTime) / Double(Self.maximumMinutes * 60))
    }

    /// The longest session the dial allows.
    static let maximumMinutes = 60

    /// When the running timer will reach zero, on the wall clock.
    var endDate: Date? {
        guard timerState == .running, let endInstant else {
            return nil
        }

        return Date(timeIntervalSinceNow: (endInstant - clock.now).timeInterval)
    }

    /// The phase that follows the current one: a break after focus (a long one every few sessions), focus after a break.
    var nextPhase: TimerPhase {
        guard phase == .focus else {
            return .focus
        }

        // Once a focus session has finished it is already counted, so look at the count as it will be after this one.
        // (It is 0 only if the count was reset in the meantime, which isn't a full round.)
        let sessions = completedFocusToday + (timerState == .finished ? 0 : 1)
        return sessions > 0 && sessions % TimerPhase.focusSessionsPerLongBreak == 0 ? .longBreak : .shortBreak
    }

    // MARK: - Controls

    func toggleTimer() {
        switch timerState {
        case .running:
            pauseTimer()
        case .paused:
            resumeTimer()
        case .stopped:
            startTimer()
        case .finished:
            startNextPhase()
        }
    }

    func startTimer() {
        sessionLength = Int(timerDuration) * 60
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

    /// Stops the timer. After a finished session this moves on to the next phase without starting it.
    func resetTimer() {
        if timerState == .finished {
            setPhase(nextPhase)
            return
        }

        stopTicking()
        timerState = .stopped
        updateRemainingTime()
    }

    func setPhase(_ newPhase: TimerPhase) {
        stopTicking()
        timerState = .stopped
        phase = newPhase
        timerDuration = Double(newPhase.minutes)
        updateRemainingTime()
    }

    /// Dragging the dial or typing in it: set the length of a timer that hasn't started yet.
    func setDuration(minutes: Int) {
        let minutes = min(Self.maximumMinutes, max(1, minutes))

        guard timerState == .stopped, minutes != Int(timerDuration) else {
            return
        }

        timerDuration = Double(minutes)
        updateRemainingTime()
    }

    func startNextPhase() {
        setPhase(nextPhase)
        startTimer()
    }

    func updateRemainingTime() {
        overtime = 0
        pausedRemaining = .seconds(Int(timerDuration) * 60)
        remainingTime = Self.wholeSeconds(pausedRemaining)
        sessionLength = remainingTime
    }

    func timeString(from seconds: Int) -> String {
        let minutes = seconds / 60
        let seconds = seconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// The main time readout: the countdown, or "+mm:ss" of overtime once the session has finished.
    var displayTime: String {
        timerState == .finished
            ? "+" + timeString(from: overtime)
            : timeString(from: remainingTime)
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

        guard let endInstant else {
            return
        }

        let untilNextChange: Duration

        switch timerState {
        case .running:
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
            untilNextChange = left - .seconds(shown - 1)

        case .finished:
            let over = clock.now - endInstant
            let shown = max(0, Int((over.timeInterval + 0.001).rounded(.down)))

            if overtime != shown {
                overtime = shown
                repeatAlarmIfDue()
            }

            untilNextChange = .seconds(shown + 1) - over

        case .paused, .stopped:
            return
        }

        let timer = Timer(
            fire: Date(timeIntervalSinceNow: untilNextChange.timeInterval),
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
        endActivity()
    }

    private func endActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func finish() {
        // Keep endInstant so overtime can be counted from the exact moment the timer ran out.
        endActivity()
        remainingTime = 0
        overtime = 0
        lastAlarmMinute = 0
        timerState = .finished

        if phase == .focus {
            recordFocusSession()
        }

        playAlarmSound()
        postFinishedNotification()
        tick()
    }

    /// Timers don't fire while the Mac sleeps, so catch up as soon as it wakes or the clock changes.
    private func observeSystemChanges() {
        let catchUp: (Notification) -> Void = { [weak self] _ in
            self?.tick()
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        observers = [
            workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: catchUp),
            workspaceCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: catchUp),
            NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main, using: catchUp),
            NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
                self?.loadTodaysSessions()
            }
        ]
    }

    private static func wholeSeconds(_ duration: Duration) -> Int {
        // The small margin keeps an exact 1500 s from rounding up to 1501 because of floating-point noise.
        max(0, Int((duration.timeInterval - 0.001).rounded(.up)))
    }

    // MARK: - Today's sessions

    static var todayKey: String {
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(today.year ?? 0)-\(today.month ?? 0)-\(today.day ?? 0)"
    }

    private func loadTodaysSessions() {
        let defaults = UserDefaults.standard
        completedFocusToday = defaults.string(forKey: "sessionsDay") == Self.todayKey
            ? defaults.integer(forKey: "sessionsToday")
            : 0
    }

    private func recordFocusSession() {
        loadTodaysSessions()
        saveTodaysSessions(completedFocusToday + 1)
    }

    func resetTodaysSessions() {
        saveTodaysSessions(0)
    }

    private func saveTodaysSessions(_ count: Int) {
        completedFocusToday = count

        let defaults = UserDefaults.standard
        defaults.set(Self.todayKey, forKey: "sessionsDay")
        defaults.set(count, forKey: "sessionsToday")
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

    /// Rings again at each full minute of overtime, for the first few minutes, unless turned off in Settings.
    private func repeatAlarmIfDue() {
        let minute = overtime / 60

        guard minute > lastAlarmMinute else {
            return
        }

        lastAlarmMinute = minute

        // After a long sleep the overtime jumps far past the limit; stay quiet then rather than ring once on wake.
        let enabled = UserDefaults.standard.object(forKey: "repeatAlarm") as? Bool ?? true
        if enabled, minute <= Self.alarmRepeatMinutes {
            playAlarmSound()
        }
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

        if phase == .focus {
            content.title = task.isEmpty ? "Focus done" : "Focus done: \(task)"
            content.body = "Time for a \(nextPhase.title.lowercased())."
        } else {
            content.title = "Break's over"
            content.body = task.isEmpty ? "Ready to focus again?" : "Back to: \(task)"
        }
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
