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
        VStack(spacing: 16) {
            phaseHeader

            dial

            sessionRow

            taskField

            primaryControls

            footerControls
        }
        .padding(18)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            ZStack {
                VisualEffectBackground()

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
    /// The switcher keeps its space either way, so the window doesn't jump.
    private var phaseHeader: some View {
        ZStack {
            Picker(
                "Phase",
                selection: Binding(
                    get: { viewModel.phase },
                    set: { applyPreset($0) }
                )
            ) {
                ForEach(TimerPhase.allCases, id: \.self) { phase in
                    Text(phase.title)
                        .tag(phase)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .opacity(shouldShowSetupControls ? 1 : 0)
            .disabled(!shouldShowSetupControls)

            if !shouldShowSetupControls {
                Label(viewModel.phase.title, systemImage: viewModel.phase.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(viewModel.phase.tint)
            }
        }
    }

    // MARK: - Dial

    @ViewBuilder
    private var dial: some View {
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
            DialTicks(major: false)
                .stroke(Color.primary.opacity(0.15), lineWidth: 1)

            DialTicks(major: true)
                .stroke(Color.primary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            DialRing(
                fraction: viewModel.dialFraction,
                tint: dialTint,
                lineWidth: 10,
                // Drain smoothly between ticks while running; follow the drag straight away otherwise.
                animation: viewModel.timerState == .running ? .linear(duration: 1) : nil
            )
            .padding(Self.ringInset)

            if canEditDuration {
                knob
            }

            // The ring is the drag handle; the middle is left free for clicking the time.
            Color.clear
                .contentShape(RingHitArea(), eoFill: true)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragDial(to: value.location)
                        }
                        .onEnded { _ in
                            lastDragMinutes = nil
                        }
                )
                .allowsHitTesting(canEditDuration && !useMouseControls)
                .help("Drag the ring to set the time")

            dialCenter
        }
        .frame(width: dialSize, height: dialSize)
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

    private var knob: some View {
        let radius = dialSize / 2 - Self.ringInset - 5
        let angle = Angle.degrees(viewModel.dialFraction * 360 - 90)

        return Circle()
            .fill(Color.white)
            .frame(width: 18, height: 18)
            .overlay {
                Circle()
                    .stroke(dialTint, lineWidth: 3)
            }
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            .offset(x: cos(angle.radians) * radius, y: sin(angle.radians) * radius)
            .allowsHitTesting(false)
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
                    .frame(width: 84)
                    .padding(.vertical, 2)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    }
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
        viewModel.setDuration(minutes: minutes)
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
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .focused($taskFieldFocused)
            .onSubmit {
                taskFieldFocused = false
            }
            .multilineTextAlignment(.center)
            .accessibilityLabel("Current task")
    }

    // MARK: - Primary controls

    @ViewBuilder
    private var primaryControls: some View {
        if !useMouseControls {
            HStack(spacing: 10) {
                Button(action: viewModel.toggleTimer) {
                    Label(primaryActionTitle, systemImage: primaryButtonIcon)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(buttonTint)
                .keyboardShortcut(.space, modifiers: [])

                Button(action: viewModel.resetTimer) {
                    Label(
                        viewModel.timerState == .finished ? "Stop" : "Reset",
                        systemImage: viewModel.timerState == .finished ? "stop.fill" : "arrow.counterclockwise"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
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

            Spacer()

            switch presentation {
            case .popover:
                Button {
                    appDelegate?.showMainWindow()
                } label: {
                    Label("Open Window", systemImage: "macwindow")
                }
                .help("Open the timer in its own window")

            case .window:
                if minimalMode != "off" {
                    Button {
                        appDelegate?.showMinimalTimer()
                    } label: {
                        Image(systemName: "capsule")
                    }
                    .help("Switch to the small floating timer")
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
            }

            Button {
                // Bring the app forward first, or Settings can open behind other apps when the Dock icon is hidden.
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Open Anchor Settings")
        }
        .buttonStyle(.bordered)
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

/// Minute marks around the outside of the dial, longer every five minutes.
private struct DialTicks: Shape {
    let major: Bool

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2 - 1
        let inner = outer - (major ? 6 : 3)
        var path = Path()

        for minute in 0..<60 where (minute % 5 == 0) == major {
            let angle = Double(minute) / 60 * 2 * .pi - .pi / 2
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

/// The frosted, see-through background used by menu bar popovers, behind the window and the popover alike.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        // Stay frosted while another app is in front, since the timer is often looked at from there.
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
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
                    DialRing(
                        fraction: viewModel.dialFraction,
                        tint: tint,
                        lineWidth: 3,
                        animation: viewModel.timerState == .running ? .linear(duration: 1) : .snappy(duration: 0.3)
                    )
                    .frame(width: 18, height: 18)

                    Text(viewModel.displayTime)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(timeColor)

                    Text(caption)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(viewModel.timerState == .finished ? .orange : .secondary)
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

// MARK: - Preview

#Preview {
    ContentView(
        viewModel: TimerViewModel(duration: 25)
    )
    .preferredColorScheme(.dark)
}
