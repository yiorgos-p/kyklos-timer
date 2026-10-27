import SwiftUI
import AppKit

struct ContentView: View {
    enum Presentation {
        case popover
        case window
    }

    @ObservedObject var viewModel: TimerViewModel
    var presentation: Presentation = .popover

    @AppStorage("standardTimer") private var standardTimer = 25
    @AppStorage("shortBreak") private var shortBreak = 5
    @AppStorage("longBreak") private var longBreak = 10
    @AppStorage("useMouseControls") private var useMouseControls = false
    @AppStorage("zenMode") private var zenMode = false
    @AppStorage("keepWindowOnTop") private var keepWindowOnTop = false
    @AppStorage("minimalMode") private var minimalMode = "off"
    // Read through TimerPhase so the value is clamped; stored here only so the dots redraw when it changes.
    @AppStorage("sessionsPerLongBreak") private var savedSessionsPerLongBreak = 4

    private var sessionsPerLongBreak: Int {
        _ = savedSessionsPerLongBreak
        return TimerPhase.focusSessionsPerLongBreak
    }
    @FocusState private var taskFieldFocused: Bool
    @Environment(\.openSettings) private var openSettings

    private let width: CGFloat = 360

    var body: some View {
        VStack(spacing: 16) {
            phaseHeader

            timerDial

            sessionRow

            taskField

            primaryControls

            footerControls
        }
        .padding(18)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
                // Clicking anywhere outside the task field takes the focus off it, so Space starts the timer again.
                .onTapGesture {
                    taskFieldFocused = false
                }
        }
        .animation(.snappy(duration: 0.25), value: shouldShowSetupControls)
        .onChange(of: useMouseControls) { _, _ in
            // Mouse mode hides the buttons, so the window gets shorter.
            if presentation == .window {
                appDelegate?.fitMainWindowToContent()
            }
        }
    }

    // MARK: - Phase

    /// The phase switcher, or just the phase's name while Zen Mode hides the setup controls.
    /// Both are the same height, so the window doesn't jump when one replaces the other.
    @ViewBuilder
    private var phaseHeader: some View {
        if shouldShowSetupControls {
            PhasePicker(
                selection: viewModel.phase,
                minutes: presetMinutes(for:),
                select: applyPreset
            )
        } else {
            Label(viewModel.phase.title, systemImage: viewModel.phase.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(viewModel.phase.tint)
                .frame(height: PhasePicker.height)
        }
    }

    // MARK: - Dial

    private var timerDial: some View {
        HStack(spacing: 8) {
            durationButton(step: -1, systemImage: "minus")

            Group {
                if useMouseControls {
                    MouseCommandSurface(
                        onSingleClick: {
                            viewModel.toggleTimer()
                        },
                        onTripleClick: {
                            viewModel.resetTimer()
                        }
                    ) {
                        disk
                    }
                } else {
                    disk
                }
            }

            durationButton(step: 1, systemImage: "plus")
        }
    }

    private var disk: some View {
        TimeDisk(
            fraction: viewModel.dialFraction,
            tint: dialTint,
            // Drain smoothly between ticks while running; jump straight to the new value otherwise.
            animation: viewModel.timerState == .running
                ? .linear(duration: 1)
                : .snappy(duration: 0.3)
        ) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.15), radius: 5, y: 1)
                    .padding(42)

                VStack(spacing: 1) {
                    Text(viewModel.displayTime)
                        .font(.system(size: 36, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                        .foregroundStyle(viewModel.timerState == .finished ? Palette.timesUpColor : .primary)

                    Text(statusCaption)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(viewModel.timerState == .finished ? Palette.timesUpColor : .secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 50)
            }
        }
        .frame(width: 220, height: 220)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Remaining time")
        .accessibilityValue("\(viewModel.displayTime), \(statusCaption)")
    }

    /// − and + beside the dial set the length before starting; hold to keep changing it.
    private func durationButton(step: Int, systemImage: String) -> some View {
        let minutes = Int(viewModel.timerDuration)
        let canChange = step < 0 ? minutes > 1 : minutes < TimerViewModel.maximumMinutes
        let isStopped = viewModel.timerState == .stopped

        return Button {
            viewModel.adjustDuration(by: step)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.primary.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .disabled(!isStopped || !canChange)
        // Hidden but still taking up space once the timer is going, so the dial stays put.
        .opacity(isStopped ? (canChange ? 1 : 0.35) : 0)
        .help(step < 0 ? "One minute less" : "One minute more")
        .accessibilityLabel(step < 0 ? "One minute less" : "One minute more")
    }

    // MARK: - Sessions and task

    private var sessionRow: some View {
        HStack(spacing: 6) {
            SessionDots(
                completed: viewModel.completedFocusToday,
                perCycle: sessionsPerLongBreak
            )
            .contextMenu {
                Button("Reset Today's Sessions") {
                    viewModel.resetTodaysSessions()
                }
                .disabled(viewModel.completedFocusToday == 0)
            }

            if viewModel.completedFocusToday > 0 {
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        viewModel.resetTodaysSessions()
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Reset today's sessions")
                .accessibilityLabel("Reset today's sessions")
            }
        }
        .frame(height: 18)
    }

    private var taskField: some View {
        TextField("What are you working on?", text: $viewModel.task)
            .textFieldStyle(.plain)
            .focused($taskFieldFocused)
            .onSubmit {
                taskFieldFocused = false
            }
            .multilineTextAlignment(.center)
            .font(.system(size: 14, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                Capsule()
                    .fill(Color.primary.opacity(0.05))
            }
            .accessibilityLabel("Current task")
    }

    // MARK: - Primary controls

    @ViewBuilder
    private var primaryControls: some View {
        if !useMouseControls {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        Button(action: viewModel.toggleTimer) {
                            primaryButtonLabel
                        }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.space, modifiers: [])

                        Button(action: viewModel.resetTimer) {
                            secondaryButtonLabel
                        }
                        .buttonStyle(.glass)
                    }
                }
                .tint(buttonTint)
            } else {
                HStack(spacing: 10) {
                    Button(action: viewModel.toggleTimer) {
                        primaryButtonLabel
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.space, modifiers: [])

                    Button(action: viewModel.resetTimer) {
                        secondaryButtonLabel
                    }
                    .buttonStyle(.bordered)
                }
                .tint(buttonTint)
            }
        }
    }

    private var primaryButtonLabel: some View {
        Label(primaryActionTitle, systemImage: primaryButtonIcon)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
    }

    private var secondaryButtonLabel: some View {
        Label(
            viewModel.timerState == .finished ? "Stop" : "Reset",
            systemImage: viewModel.timerState == .finished ? "stop.fill" : "arrow.counterclockwise"
        )
        .frame(maxWidth: .infinity)
        .frame(height: 34)
    }

    // MARK: - Footer

    private var footerControls: some View {
        HStack(spacing: 8) {
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Anchor")
            .modifier(SecondaryGlassButtonModifier())

            Spacer()

            switch presentation {
            case .popover:
                Button {
                    appDelegate?.showMainWindow()
                } label: {
                    Label("Open Window", systemImage: "macwindow")
                }
                .help("Open the timer in its own window")
                .modifier(SecondaryGlassButtonModifier())

            case .window:
                if minimalMode != "off" {
                    Button {
                        appDelegate?.showMinimalTimer()
                    } label: {
                        Image(systemName: "capsule")
                    }
                    .help("Switch to the small floating timer")
                    .modifier(SecondaryGlassButtonModifier())
                }

                Button {
                    keepWindowOnTop.toggle()
                    appDelegate?.applyWindowLevel()
                } label: {
                    Label(
                        "On Top",
                        systemImage: keepWindowOnTop ? "pin.fill" : "pin"
                    )
                }
                .help(
                    keepWindowOnTop
                        ? "Stop keeping this window above other windows"
                        : "Keep this window above other windows"
                )
                .modifier(SecondaryGlassButtonModifier())
            }

            Button {
                // Bring the app forward first, or Settings can open behind other apps when the Dock icon is hidden.
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Open Anchor Settings")
            .modifier(SecondaryGlassButtonModifier())
        }
    }

    // MARK: - Derived state

    private var shouldShowSetupControls: Bool {
        !zenMode || viewModel.timerState != .running
    }

    private var dialTint: Color {
        switch viewModel.timerState {
        case .finished:
            return Palette.timesUpColor
        case .paused:
            return viewModel.phase.tint.opacity(0.5)
        case .running, .stopped:
            return viewModel.phase.tint
        }
    }

    /// When time is up, the button starts the next phase, so it takes that phase's colour.
    private var buttonTint: Color {
        viewModel.timerState == .finished ? viewModel.nextPhase.tint : viewModel.phase.tint
    }

    private var statusCaption: String {
        switch viewModel.timerState {
        case .running:
            guard let endDate = viewModel.endDate else {
                return ""
            }
            return "ends \(endDate.formatted(date: .omitted, time: .shortened))"

        case .paused:
            return "paused"

        case .stopped:
            return "ready"

        case .finished:
            return "time's up"
        }
    }

    private var primaryButtonIcon: String {
        switch viewModel.timerState {
        case .running:
            return "pause.fill"

        case .paused, .stopped:
            return "play.fill"

        case .finished:
            return viewModel.nextPhase.systemImage
        }
    }

    private var primaryActionTitle: String {
        switch viewModel.timerState {
        case .running:
            return "Pause"

        case .paused:
            return "Resume"

        case .stopped:
            return "Start"

        case .finished:
            return "Start \(viewModel.nextPhase.title)"
        }
    }

    private func presetMinutes(for phase: TimerPhase) -> Int {
        switch phase {
        case .focus:
            return standardTimer
        case .shortBreak:
            return shortBreak
        case .longBreak:
            return longBreak
        }
    }

    // MARK: - Actions

    private func applyPreset(_ phase: TimerPhase) {
        withAnimation(.snappy(duration: 0.25)) {
            viewModel.setPhase(phase)
        }
    }

    private var appDelegate: AppDelegate? {
        AppDelegate.shared
    }
}

// MARK: - Phase picker

/// Focus · Short Break · Long Break, with the current one filled in its own colour.
private struct PhasePicker: View {
    static let height: CGFloat = 32

    let selection: TimerPhase
    let minutes: (TimerPhase) -> Int
    let select: (TimerPhase) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TimerPhase.allCases, id: \.self) { phase in
                let isSelected = phase == selection

                Button {
                    select(phase)
                } label: {
                    Text(phase.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.height - 6)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(phase.tint)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(phase.title), \(minutes(phase)) min")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background {
            Capsule()
                .fill(Color.primary.opacity(0.06))
        }
    }
}

// MARK: - Time disk

/// A 60-minute dial: the coloured wedge is the time left, shrinking back toward 12 o'clock as it runs.
private struct TimeDisk<Center: View>: View {
    let fraction: Double
    let tint: Color
    let animation: Animation
    var showsBezel = true
    @ViewBuilder let center: Center

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let faceInset = showsBezel ? size * 0.06 : 0

            ZStack {
                if showsBezel {
                    BezelTicks(major: false)
                        .stroke(Color.primary.opacity(0.18), lineWidth: 1)

                    BezelTicks(major: true)
                        .stroke(Color.primary.opacity(0.4), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }

                Circle()
                    .fill(tint.opacity(0.13))
                    .padding(faceInset)

                Wedge(fraction: fraction)
                    .fill(tint)
                    .padding(faceInset)
                    .animation(animation, value: fraction)

                center
            }
            .frame(width: size, height: size)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Minute marks around the edge of the dial, longer every five minutes.
private struct BezelTicks: Shape {
    let major: Bool

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2 - 1
        let inner = outer - (major ? 7 : 3.5)
        var path = Path()

        for minute in 0..<60 where (minute % 5 == 0) == major {
            let angle = Double(minute) / 60 * 2 * .pi - .pi / 2
            path.move(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
        }

        return path
    }
}

/// A slice of the dial from 12 o'clock, clockwise.
private struct Wedge: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard fraction > 0 else {
            return Path()
        }

        guard fraction < 1 else {
            return Path(ellipseIn: rect)
        }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        // SwiftUI's y axis points down, so "clockwise: false" draws clockwise on screen.
        path.addArc(
            center: center,
            radius: min(rect.width, rect.height) / 2,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * fraction),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Minimal timer

/// The small floating pill: ring, time, task and one button. Drag it anywhere; double-click for the full window.
struct MinimalTimerView: View {
    @ObservedObject var viewModel: TimerViewModel

    static let size = CGSize(width: 260, height: 44)

    var body: some View {
        ZStack {
            WindowDragArea {
                AppDelegate.shared?.showMainWindow()
            }

            HStack(spacing: 10) {
                HStack(spacing: 9) {
                    TimeDisk(
                        fraction: viewModel.dialFraction,
                        tint: tint,
                        animation: viewModel.timerState == .running ? .linear(duration: 1) : .snappy(duration: 0.3),
                        showsBezel: false
                    ) {
                        EmptyView()
                    }
                    .frame(width: 20, height: 20)

                    Text(viewModel.displayTime)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(timeColor)

                    Text(caption)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(viewModel.timerState == .finished ? Palette.timesUpColor : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)
                }
                // Clicks on the text fall through to the drag area underneath.
                .allowsHitTesting(false)

                actionButton
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    @ViewBuilder
    private var actionButton: some View {
        if viewModel.timerState == .finished {
            Button {
                viewModel.startNextPhase()
            } label: {
                Label(viewModel.nextPhase == .focus ? "Focus" : "Break", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(viewModel.nextPhase.tint)
            .help("Start \(viewModel.nextPhase.title)")
        } else {
            Button(action: viewModel.toggleTimer) {
                Image(systemName: viewModel.timerState == .running ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(viewModel.timerState == .running ? "Pause" : "Start")
        }
    }

    private var tint: Color {
        viewModel.timerState == .finished ? Palette.timesUpColor : viewModel.phase.tint
    }

    private var timeColor: Color {
        switch viewModel.timerState {
        case .finished:
            return Palette.timesUpColor
        case .paused:
            return .secondary
        case .running, .stopped:
            return .primary
        }
    }

    private var caption: String {
        let task = viewModel.task.trimmingCharacters(in: .whitespaces)

        switch viewModel.timerState {
        case .finished:
            return "Time's up"
        case .paused where task.isEmpty:
            return "Paused"
        default:
            return task.isEmpty ? viewModel.phase.title : task
        }
    }
}

/// Moves the window when dragged and reports double-clicks; SwiftUI has no window drag gesture before macOS 15.
private struct WindowDragArea: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> WindowDragNSView {
        let view = WindowDragNSView()
        view.onDoubleClick = onDoubleClick
        view.toolTip = "Drag to move. Double-click for the full window."
        return view
    }

    func updateNSView(_ nsView: WindowDragNSView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }
}

private final class WindowDragNSView: NSView {
    var onDoubleClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            window?.performDrag(with: event)
        }
    }
}

// MARK: - Session dots

/// Today's finished focus sessions: one dot per session in the current round, filling up toward a long break.
private struct SessionDots: View {
    let completed: Int
    let perCycle: Int

    private var filledInCycle: Int {
        guard completed > 0 else {
            return 0
        }

        let remainder = completed % perCycle
        return remainder == 0 ? perCycle : remainder
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(0..<perCycle, id: \.self) { index in
                    Circle()
                        .fill(index < filledInCycle ? TimerPhase.focus.tint : Color.primary.opacity(0.15))
                        .frame(width: 7, height: 7)
                }
            }

            if completed > 0 {
                Text("\(completed) today")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .help("\(completed) focus session\(completed == 1 ? "" : "s") finished today. A long break comes after every \(perCycle).")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(completed) focus sessions finished today")
    }
}

private struct MouseCommandSurface<Content: View>: View {
    let onSingleClick: () -> Void
    let onTripleClick: () -> Void
    let content: Content

    init(
        onSingleClick: @escaping () -> Void,
        onTripleClick: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.onSingleClick = onSingleClick
        self.onTripleClick = onTripleClick
        self.content = content()
    }

    var body: some View {
        content
            .overlay {
                MouseClickRepresentable(
                    onSingleClick: onSingleClick,
                    onTripleClick: onTripleClick
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Timer controls")
            .accessibilityHint(
                "Click once to start, pause, or resume the timer. Triple-click to reset it."
            )
    }
}

private struct MouseClickRepresentable: NSViewRepresentable {
    let onSingleClick: () -> Void
    let onTripleClick: () -> Void

    func makeNSView(context: Context) -> MouseClickNSView {
        let view = MouseClickNSView()
        view.onSingleClick = onSingleClick
        view.onTripleClick = onTripleClick
        return view
    }

    func updateNSView(
        _ nsView: MouseClickNSView,
        context: Context
    ) {
        nsView.onSingleClick = onSingleClick
        nsView.onTripleClick = onTripleClick
    }
}

private final class MouseClickNSView: NSView {
    var onSingleClick: (() -> Void)?
    var onTripleClick: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    // The first click acts at once instead of waiting to see if more follow. A triple-click still ends in the
    // same place, because a reset after a start or pause leaves the timer stopped either way.
    override func mouseDown(with event: NSEvent) {
        switch event.clickCount {
        case 1:
            onSingleClick?()
        case 3:
            onTripleClick?()
        default:
            break
        }
    }

    override func acceptsFirstMouse(
        for event: NSEvent?
    ) -> Bool {
        true
    }
}

// MARK: - Secondary button modifier

private struct SecondaryGlassButtonModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
        } else {
            content
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView(
        viewModel: TimerViewModel(duration: 25)
    )
    .preferredColorScheme(.dark)
}
