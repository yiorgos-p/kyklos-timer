import SwiftUI
import AppKit

struct ContentView: View {
    enum Presentation {
        case popover
        case window
    }

    @ObservedObject var viewModel: TimerViewModel
    var presentation: Presentation = .popover

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
    @FocusState private var minutesFieldFocused: Bool
    @State private var isEditingMinutes = false
    @State private var minutesText = ""
    /// The minutes the dial was last dragged to, so a drag can't wrap past 12 o'clock.
    @State private var lastDragMinutes: Int?
    @Environment(\.openSettings) private var openSettings

    private let width: CGFloat = 360
    private let dialSize: CGFloat = 220

    var body: some View {
        content
            .modifier(
                WindowToolbar(
                    isEnabled: presentation == .window,
                    principal: phaseHeader(inToolbar: true),
                    actions: toolbarActions
                )
            )
            .onChange(of: keepWindowOnTop) { _, _ in
                appDelegate?.applyWindowLevel()
            }
    }

    /// In the window the phase switcher, On Top and Settings live in the toolbar; the popover has no toolbar,
    /// so there they sit above and below the timer instead.
    private var content: some View {
        VStack(spacing: 16) {
            if presentation == .popover {
                phaseHeader(inToolbar: false)
            }

            dial

            sessionRow

            taskField

            // In mouse mode the popover's row would be empty.
            if !useMouseControls || presentation == .window {
                primaryControls
            }

            if presentation == .popover {
                footerControls
            }
        }
        .padding(18)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            ZStack {
                // The popover is glass already; the window becomes one glass surface to match it.
                if presentation == .window {
                    WindowGlass()
                }

                // Clicking anywhere outside a text field takes the focus off it, so Space starts the timer again.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        taskFieldFocused = false
                        minutesFieldFocused = false
                    }
            }
            .ignoresSafeArea()
        }
        .animation(.snappy(duration: 0.25), value: shouldShowSetupControls)
        .onChange(of: useMouseControls) { _, _ in
            // Mouse mode hides the buttons, so the window gets shorter.
            if presentation == .window {
                appDelegate?.fitMainWindowToContent()
            }
        }
        .onChange(of: viewModel.timerState) { _, state in
            if state != .stopped, isEditingMinutes {
                cancelMinutesEditing()
            }
        }
    }

    // MARK: - Phase

    /// The phase switcher, or just the phase's name while Zen Mode hides it.
    /// The switcher keeps its space either way, so nothing jumps. The toolbar is narrow, so it uses short names.
    /// Outside a toolbar it is the large size, which macOS 26 and later draw as a capsule like the other controls.
    private func phaseHeader(inToolbar: Bool) -> some View {
        ZStack {
            Group {
                // In the toolbar macOS picks the size; forcing one there brings back the old square selection.
                if inToolbar {
                    phasePicker(inToolbar: true)
                } else {
                    // The selected phase takes its own colour, like the arc and Start.
                    phasePicker(inToolbar: false)
                        .controlSize(.large)
                        .tint(viewModel.phase.tint)
                }
            }
            .opacity(shouldShowSetupControls ? 1 : 0)
            .disabled(!shouldShowSetupControls)

            if !shouldShowSetupControls {
                Label(viewModel.phase.title, systemImage: viewModel.phase.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(viewModel.phase.tint)
            }
        }
    }

    private func phasePicker(inToolbar: Bool) -> some View {
        Picker(
            "Phase",
            selection: Binding(
                get: { viewModel.phase },
                set: { applyPreset($0) }
            )
        ) {
            ForEach(TimerPhase.allCases, id: \.self) { phase in
                Text(inToolbar ? phase.shortTitle : phase.title)
                    .tag(phase)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// The pin in the window toolbar's right corner. Settings sits next to Reset instead,
    /// because a narrow toolbar would hide extra buttons behind an overflow arrow.
    private var toolbarActions: some View {
        Toggle(isOn: $keepWindowOnTop) {
            Label("On Top", systemImage: keepWindowOnTop ? "pin.fill" : "pin")
        }
        .help(keepWindowOnTop ? "Stop keeping this window above other windows" : "Keep this window above other windows")
    }

    // MARK: - Dial

    @ViewBuilder
    private var dial: some View {
        dialWithClicks
            .overlay {
                // Scrolling over the dial changes the length a minute at a time; clicks and drags pass through.
                ScrollWheelRepresentable { step in
                    guard canEditDuration else {
                        return
                    }
                    setDialMinutes(Int(viewModel.timerDuration) + step)
                }
            }
    }

    @ViewBuilder
    private var dialWithClicks: some View {
        if useMouseControls {
            // In mouse mode a click on the dial starts or pauses, so the minutes can't be typed; dragging still works.
            dialFace
                .overlay {
                    MouseClickRepresentable(
                        onSingleClick: viewModel.toggleTimer,
                        onTripleClick: viewModel.resetTimer,
                        onDrag: { location in
                            dragDial(to: location)
                        },
                        onDragEnd: {
                            lastDragMinutes = nil
                        }
                    )
                }
        } else {
            dialFace
        }
    }

    private var dialFace: some View {
        ZStack {
            DialTicks()
                .stroke(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            DialRing(
                fraction: viewModel.dialFraction,
                tint: dialTint,
                lineWidth: 10,
                // No animation: while running the arc moves a 3,600th of a turn a second, too little to see,
                // and animating it would redraw the dial every frame. Dragging should follow the hand directly.
                animation: nil
            )
            .padding(Self.ringInset)

            // The ring is the drag handle; the middle is left free for clicking the time.
            Color.clear
                .contentShape(RingHitArea(), eoFill: true)
                .gesture(dialDrag)
                .allowsHitTesting(canEditDuration && !useMouseControls)
                .help("Drag the ring to set the time")

            if canEditDuration {
                knob
            }

            dialCenter
        }
        .frame(width: dialSize, height: dialSize)
        .coordinateSpace(.named(Self.dialSpace))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timer")
        .accessibilityValue("\(viewModel.displayTime), \(statusCaption)")
        .accessibilityAdjustableAction { direction in
            let minutes = Int(viewModel.timerDuration)

            switch direction {
            case .increment:
                viewModel.setDuration(minutes: minutes + 1)
            case .decrement:
                viewModel.setDuration(minutes: minutes - 1)
            @unknown default:
                break
            }
        }
    }

    /// Space between the edge of the dial and the ring, where the minute marks sit.
    private static let ringInset: CGFloat = 16

    private static let dialSpace = "dial"

    /// Drag points are measured in the dial's own space, so the knob and the ring can share one gesture.
    private var dialDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.dialSpace))
            .onChanged { value in
                dragDial(to: value.location)
            }
            .onEnded { _ in
                lastDragMinutes = nil
            }
    }

    /// A glass handle at the end of the arc, there only while the length can be changed.
    private var knob: some View {
        let radius = dialSize / 2 - Self.ringInset - 5
        let angle = Angle.degrees(viewModel.dialFraction * 360 - 90)

        return Circle()
            .fill(Color.clear)
            .frame(width: 28, height: 28)
            .glassSurface(in: Circle(), interactive: true, fallback: Color.white)
            .contentShape(Circle())
            .gesture(dialDrag)
            .allowsHitTesting(!useMouseControls)
            .offset(x: cos(angle.radians) * radius, y: sin(angle.radians) * radius)
    }

    @ViewBuilder
    private var dialCenter: some View {
        if isEditingMinutes {
            VStack(spacing: 2) {
                TextField("", text: $minutesText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 40, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .frame(width: 70)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                    .glassSurface(in: Capsule())
                    .focused($minutesFieldFocused)
                    .onChange(of: minutesText) { _, newValue in
                        let digits = String(newValue.filter { "0123456789".contains($0) }.prefix(2))
                        if digits != newValue {
                            minutesText = digits
                        }
                    }
                    .onSubmit(commitMinutesEditing)
                    .onExitCommand(perform: cancelMinutesEditing)
                    .onChange(of: minutesFieldFocused) { _, focused in
                        if !focused, isEditingMinutes {
                            commitMinutesEditing()
                        }
                    }

                Text("minutes")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 2) {
                Text(viewModel.displayTime)
                    .font(.system(size: 42, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .foregroundStyle(viewModel.timerState == .finished ? .orange : .primary)
                    .onTapGesture {
                        if canEditDuration, !useMouseControls {
                            beginMinutesEditing()
                        }
                    }
                    .help(canEditDuration && !useMouseControls ? "Click to type the minutes" : "")

                Text(statusCaption)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(viewModel.timerState == .finished ? .orange : .secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: dialSize - 2 * Self.ringInset - 40)
        }
    }

    /// Turns a point on the dial into minutes: 12 o'clock is 60, each minute mark one minute.
    /// Once a drag reaches 60 or 1 it stays there rather than jumping across 12 o'clock.
    private func dragDial(to location: CGPoint) {
        guard canEditDuration else {
            return
        }

        var degrees = atan2(location.y - dialSize / 2, location.x - dialSize / 2) * 180 / .pi + 90
        if degrees < 0 {
            degrees += 360
        }

        var minutes = Int((degrees / 6).rounded())
        if minutes == 0 {
            minutes = 60
        }

        if let last = lastDragMinutes, abs(minutes - last) > 30 {
            minutes = last > 30 ? 60 : 1
        }

        minutes = max(1, minutes)
        lastDragMinutes = minutes
        setDialMinutes(minutes)
    }

    /// Sets the length from the dial, with a trackpad click at each minute it passes, like a detent.
    private func setDialMinutes(_ minutes: Int) {
        let before = Int(viewModel.timerDuration)
        viewModel.setDuration(minutes: minutes)

        if Int(viewModel.timerDuration) != before {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func beginMinutesEditing() {
        minutesText = String(Int(viewModel.timerDuration))
        isEditingMinutes = true

        DispatchQueue.main.async {
            minutesFieldFocused = true
        }
    }

    private func commitMinutesEditing() {
        if let minutes = Int(minutesText) {
            viewModel.setDuration(minutes: minutes)
        }

        isEditingMinutes = false
        minutesFieldFocused = false
    }

    private func cancelMinutesEditing() {
        isEditingMinutes = false
        minutesFieldFocused = false
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
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassSurface(in: Capsule())
            .accessibilityLabel("Current task")
    }

    // MARK: - Primary controls

    /// Start and Reset (not in mouse mode), plus Settings and the Minimal Mode button in the window,
    /// which has no footer.
    private var primaryControls: some View {
        GlassGroup {
            HStack(spacing: 10) {
                if !useMouseControls {
                    Button(action: viewModel.toggleTimer) {
                        Label(primaryActionTitle, systemImage: primaryButtonIcon)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .glassButtonStyle(prominent: true)
                    .tint(buttonTint)
                    .keyboardShortcut(.space, modifiers: [])

                    Button(action: viewModel.resetTimer) {
                        Label(
                            viewModel.timerState == .finished ? "Stop" : "Reset",
                            systemImage: viewModel.timerState == .finished ? "stop.fill" : "arrow.counterclockwise"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .glassButtonStyle()
                }

                if presentation == .window {
                    if minimalMode != "off" {
                        iconButton("capsule", help: "Switch to the small floating timer") {
                            appDelegate?.showMinimalTimer()
                        }
                    }

                    iconButton("gearshape", help: "Open kyklos Settings") {
                        openKyklosSettings()
                    }
                }
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Footer

    /// The popover's footer. Quit stays here because with the Dock icon hidden there's no other obvious way out.
    private var footerControls: some View {
        HStack(spacing: 8) {
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit kyklos")

            Spacer()

            Button {
                appDelegate?.showMainWindow()
            } label: {
                Label("Open Window", systemImage: "macwindow")
            }
            .help("Open the timer in its own window")

            Button {
                openKyklosSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Open kyklos Settings")
        }
        .glassButtonStyle()
        .buttonBorderShape(.capsule)
    }

    private func openKyklosSettings() {
        // Bring the app forward first, or Settings can open behind other apps when the Dock icon is hidden.
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    // MARK: - Derived state

    private var shouldShowSetupControls: Bool {
        !zenMode || viewModel.timerState != .running
    }

    /// The dial and its typing field only change the length before a timer starts.
    private var canEditDuration: Bool {
        viewModel.timerState == .stopped
    }

    private var dialTint: Color {
        switch viewModel.timerState {
        case .finished:
            return .orange
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

// MARK: - Dial parts

/// A grey track with a coloured arc from 12 o'clock, clockwise: how much of the hour is left.
private struct DialRing: View {
    let fraction: Double
    let tint: Color
    let lineWidth: CGFloat
    let animation: Animation?

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(animation, value: fraction)
        }
        .padding(lineWidth / 2)
    }
}

/// Five-minute marks around the outside of the dial.
private struct DialTicks: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2 - 1
        let inner = outer - 6
        var path = Path()

        for mark in 0..<12 {
            let angle = Double(mark) / 12 * 2 * .pi - .pi / 2
            path.move(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
        }

        return path
    }
}

/// The band around the ring that can be dragged: the whole dial minus the middle.
private struct RingHitArea: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(ellipseIn: rect)
        path.addEllipse(in: rect.insetBy(dx: rect.width * 0.25, dy: rect.height * 0.25))
        return path
    }
}

// MARK: - Minimal timer

/// The small floating pill: ring, time, task, the main button and a close button. Drag it anywhere; double-click
/// for the full window.
struct MinimalTimerView: View {
    @ObservedObject var viewModel: TimerViewModel

    @State private var isEditingMinutes = false
    @State private var minutesText = ""
    @FocusState private var minutesFieldFocused: Bool

    static let size = CGSize(width: 292, height: 44)

    var body: some View {
        ZStack {
            WindowDragArea {
                AppDelegate.shared?.showMainWindow()
            }

            HStack(spacing: 10) {
                HStack(spacing: 9) {
                    DialRing(
                        fraction: viewModel.dialFraction,
                        tint: tint,
                        lineWidth: 3,
                        // Stepped once a second while running, like the big dial; animated only for jumps.
                        animation: viewModel.timerState == .running ? nil : .snappy(duration: 0.3)
                    )
                    .frame(width: 18, height: 18)
                    // Clicks fall through to the drag area underneath.
                    .allowsHitTesting(false)

                    time

                    Text(isEditingMinutes ? "min" : caption)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(viewModel.timerState == .finished ? .orange : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .allowsHitTesting(false)

                    Spacer(minLength: 0)
                }

                HStack(spacing: 6) {
                    actionButton
                    closeButton
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onChange(of: viewModel.timerState) { _, state in
            if state != .stopped {
                isEditingMinutes = false
            }
        }
    }

    /// The time; while stopped, click it to type a new length (handy in Always mode, where the pill is all there is).
    @ViewBuilder
    private var time: some View {
        if isEditingMinutes {
            TextField("", text: $minutesText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .frame(width: 46)
                .focused($minutesFieldFocused)
                .onChange(of: minutesText) { _, newValue in
                    let digits = String(newValue.filter { "0123456789".contains($0) }.prefix(2))
                    if digits != newValue {
                        minutesText = digits
                    }
                }
                .onSubmit(commitMinutes)
                .onExitCommand {
                    isEditingMinutes = false
                }
                .onChange(of: minutesFieldFocused) { _, focused in
                    if !focused, isEditingMinutes {
                        commitMinutes()
                    }
                }
        } else {
            Text(viewModel.displayTime)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(timeColor)
                .onTapGesture {
                    beginEditingMinutes()
                }
                .allowsHitTesting(viewModel.timerState == .stopped)
                .help("Click to type the minutes")
        }
    }

    /// Hides the pill; the timer keeps running in the menu bar, and the pill comes back with the next session.
    private var closeButton: some View {
        Button {
            AppDelegate.shared?.closeMinimalTimer()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 16, height: 16)
        }
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .help("Close")
    }

    private func beginEditingMinutes() {
        minutesText = String(Int(viewModel.timerDuration))
        isEditingMinutes = true
        // The pill doesn't take the keyboard on its own, so hand it over for typing.
        AppDelegate.shared?.makeMinimalTimerKey()

        DispatchQueue.main.async {
            minutesFieldFocused = true
        }
    }

    private func commitMinutes() {
        if let minutes = Int(minutesText) {
            viewModel.setDuration(minutes: minutes)
        }

        isEditingMinutes = false
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
            .glassButtonStyle(prominent: true)
            .buttonBorderShape(.capsule)
            .tint(viewModel.nextPhase.tint)
            .help("Start \(viewModel.nextPhase.title)")
        } else {
            Button(action: viewModel.toggleTimer) {
                Image(systemName: viewModel.timerState == .running ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 16, height: 16)
            }
            .glassButtonStyle()
            .buttonBorderShape(.circle)
            .help(viewModel.timerState == .running ? "Pause" : "Start")
        }
    }

    private var tint: Color {
        viewModel.timerState == .finished ? .orange : viewModel.phase.tint
    }

    private var timeColor: Color {
        switch viewModel.timerState {
        case .finished:
            return .orange
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
                        .fill(index < filledInCycle ? Color.primary.opacity(0.55) : Color.primary.opacity(0.15))
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

// MARK: - Mouse mode

/// Mouse mode on the dial: click to start or pause, triple-click to reset, drag to set the time.
private struct MouseClickRepresentable: NSViewRepresentable {
    let onSingleClick: () -> Void
    let onTripleClick: () -> Void
    let onDrag: (CGPoint) -> Void
    let onDragEnd: () -> Void

    func makeNSView(context: Context) -> MouseClickNSView {
        let view = MouseClickNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(
        _ nsView: MouseClickNSView,
        context: Context
    ) {
        nsView.onSingleClick = onSingleClick
        nsView.onTripleClick = onTripleClick
        nsView.onDrag = onDrag
        nsView.onDragEnd = onDragEnd
    }
}

private final class MouseClickNSView: NSView {
    var onSingleClick: (() -> Void)?
    var onTripleClick: (() -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onDragEnd: (() -> Void)?

    private var mouseDownLocation: CGPoint?
    private var isDragging = false

    // Top-left origin, the same as SwiftUI, so drag points can be used as they are.
    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(
        for event: NSEvent?
    ) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        // A few points of wobble is still a click.
        if !isDragging, let start = mouseDownLocation, hypot(location.x - start.x, location.y - start.y) > 3 {
            isDragging = true
        }

        if isDragging {
            onDrag?(location)
        }
    }

    // Clicks act on release, so a drag can be told apart from them. A triple-click still ends in the same
    // place as a plain reset, because a reset after the first click's start or pause leaves the timer stopped.
    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            isDragging = false
        }

        if isDragging {
            onDragEnd?()
            return
        }

        switch event.clickCount {
        case 1:
            onSingleClick?()
        case 3:
            onTripleClick?()
        default:
            break
        }
    }
}

// MARK: - Glass

/// Real Liquid Glass on macOS 26 and later, so it follows the Liquid Glass setting in System Settings;
/// the standard bordered look before that.
private struct GlassButtonStyle: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}

private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let fallback: Color

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content.background(shape.fill(fallback))
        }
    }
}

/// The whole window as one Liquid Glass surface, so it follows the Liquid Glass setting like the popover does.
/// Plain glass this large comes out flat grey, and on Clear it lets dark windows behind darken the text's
/// background, so it is tinted halfway toward the window colour: light in Light Mode, dark in Dark Mode.
/// Before macOS 26 the window keeps the standard background.
private struct WindowGlass: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Rectangle()
                .fill(Color.clear)
                .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.5)), in: Rectangle())
        }
    }
}

/// Lets neighbouring glass buttons blend into each other the way the system's own groups do.
private struct GlassGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 10) {
                content
            }
        } else {
            content
        }
    }
}

private extension View {
    func glassButtonStyle(prominent: Bool = false) -> some View {
        modifier(GlassButtonStyle(prominent: prominent))
    }

    func glassSurface<S: Shape>(
        in shape: S,
        interactive: Bool = false,
        fallback: Color = Color.primary.opacity(0.06)
    ) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive, fallback: fallback))
    }
}

// MARK: - Window toolbar

/// The window's toolbar: the phase switcher in the middle and its buttons on the right.
/// The system draws it, so it gets the standard frosted toolbar look.
private struct WindowToolbar<Principal: View, Actions: View>: ViewModifier {
    let isEnabled: Bool
    let principal: Principal
    let actions: Actions

    func body(content: Content) -> some View {
        if isEnabled {
            content.toolbar {
                ToolbarItem(placement: .principal) {
                    principal
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    actions
                }
            }
        } else {
            content
        }
    }
}

// MARK: - Scroll to adjust

private struct ScrollWheelRepresentable: NSViewRepresentable {
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onStep = onStep
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onStep = onStep
    }
}

/// Turns scrolling into ±1 minute steps: one per notch on a mouse wheel, one per few points on a trackpad.
private final class ScrollWheelNSView: NSView {
    var onStep: ((Int) -> Void)?

    private var accumulated: CGFloat = 0
    private let pointsPerStep: CGFloat = 8

    // Only scrolling stops here; clicks and drags go through to the dial underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
    }

    override func scrollWheel(with event: NSEvent) {
        // Coasting after a trackpad flick would spin the time far past where the fingers stopped.
        guard event.momentumPhase.isEmpty else {
            return
        }

        // Moving up adds time, whichever scroll direction is set in System Settings.
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY

        guard event.hasPreciseScrollingDeltas else {
            if delta != 0 {
                onStep?(delta > 0 ? 1 : -1)
            }
            return
        }

        if event.phase == .began {
            accumulated = 0
        }

        accumulated += delta

        while abs(accumulated) >= pointsPerStep {
            let step = accumulated > 0 ? 1 : -1
            accumulated -= CGFloat(step) * pointsPerStep
            onStep?(step)
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
