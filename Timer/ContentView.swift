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

    private let popoverWidth: CGFloat = 360

    var body: some View {
        ZStack {
            background

            VStack(spacing: 16) {
                timerHeader

                if shouldShowSetupControls {
                    durationControl
                }

                primaryControls

                if shouldShowSetupControls {
                    presetControls
                }

                footerControls
            }
            .padding(18)
            .animation(
                .snappy(duration: 0.25),
                value: shouldShowSetupControls
            )
        }
        .frame(width: popoverWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: shouldShowSetupControls) { _, _ in
            switch presentation {
            case .popover:
                appDelegate?.animatePopoverToFitContent()
            case .window:
                appDelegate?.fitMainWindowToContent()
            }
        }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            LinearGradient(
                colors: [
                    ringTint.opacity(0.10),
                    Color.clear,
                    Color.primary.opacity(0.025)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .animation(.easeInOut(duration: 0.4), value: ringTint)
        }
        .ignoresSafeArea()
        // Clicking anywhere outside the task field takes the focus off it, so Space starts the timer again.
        .onTapGesture {
            taskFieldFocused = false
        }
    }

    // MARK: - Timer header

    private var timerHeader: some View {
        VStack(spacing: 10) {
            HStack {
                Label(viewModel.phase.title, systemImage: viewModel.phase.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(viewModel.phase.tint)

                Spacer()

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

            timerDisplay

            taskField
        }
        .padding(18)
        .modifier(
            GlassPanelModifier(
                cornerRadius: 26,
                interactive: false
            )
        )
    }

    @ViewBuilder
    private var timerDisplay: some View {
        if useMouseControls {
            MouseCommandSurface(
                onSingleClick: {
                    viewModel.toggleTimer()
                },
                onTripleClick: {
                    viewModel.resetTimer()
                }
            ) {
                timerRing
            }
        } else {
            timerRing
        }
    }

    private var timerRing: some View {
        ProgressRing(
            progress: viewModel.timerState == .finished ? 1 : viewModel.progress,
            tint: ringTint,
            // Drain smoothly between ticks while running; jump straight to the new value otherwise.
            animation: viewModel.timerState == .running
                ? .linear(duration: 1)
                : .snappy(duration: 0.3)
        ) {
            VStack(spacing: 2) {
                Text(viewModel.displayTime)
                    .font(
                        .system(
                            size: 46,
                            weight: .medium,
                            design: .rounded
                        )
                    )
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(viewModel.timerState == .finished ? .orange : .primary)

                Text(statusCaption)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(viewModel.timerState == .finished ? .orange : .secondary)
                    .monospacedDigit()
            }
        }
        .frame(width: 180, height: 180)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Remaining time")
        .accessibilityValue("\(viewModel.displayTime), \(statusCaption)")
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

    // MARK: - Duration

    private var durationControl: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Duration", systemImage: "timer")
                    .font(.system(size: 13, weight: .medium))

                Spacer()

                DurationValueEditor(
                    value: $viewModel.timerDuration,
                    range: 1...60
                )
            }

            Slider(
                value: $viewModel.timerDuration,
                in: 1...60,
                step: 1
            ) {
                Text("Timer duration")
            } minimumValueLabel: {
                Text("1")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("60")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .labelsHidden()
            .tint(viewModel.phase.tint)
            .onChange(of: viewModel.timerDuration) { _, _ in
                guard
                    viewModel.timerState == .stopped ||
                    viewModel.timerState == .paused
                else {
                    return
                }

                viewModel.updateRemainingTime()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .modifier(
            GlassPanelModifier(
                cornerRadius: 20,
                interactive: true
            )
        )
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

    // MARK: - Presets

    private var presetControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Presets", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 9) {
                ForEach(TimerPhase.allCases, id: \.self) { phase in
                    PresetButton(
                        title: phase.shortTitle,
                        minutes: presetMinutes(for: phase),
                        systemImage: phase.systemImage,
                        isSelected: viewModel.phase == phase
                    ) {
                        applyPreset(phase)
                    }
                }
            }
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
        .padding(.top, 2)
    }

    // MARK: - Derived state

    private var shouldShowSetupControls: Bool {
        !zenMode || viewModel.timerState != .running
    }

    private var ringTint: Color {
        viewModel.timerState == .finished ? .orange : viewModel.phase.tint
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
            return "\(Int(viewModel.timerDuration)) min"

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

// MARK: - Progress ring

private struct ProgressRing<Content: View>: View {
    let progress: Double
    let tint: Color
    let animation: Animation
    var lineWidth: CGFloat = 10
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.15), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(animation, value: progress)

            content
        }
        .padding(lineWidth / 2)
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
                    ProgressRing(
                        progress: viewModel.timerState == .finished ? 1 : viewModel.progress,
                        tint: tint,
                        animation: viewModel.timerState == .running ? .linear(duration: 1) : .snappy(duration: 0.3),
                        lineWidth: 3
                    ) {
                        EmptyView()
                    }
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
                        .fill(index < filledInCycle ? Color.accentColor : Color.primary.opacity(0.15))
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

private struct DurationValueEditor: View {
    @Binding var value: Double

    let range: ClosedRange<Int>

    @State private var isEditing = false
    @State private var inputText = ""
    @FocusState private var inputIsFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                HStack(spacing: 4) {
                    TextField("", text: $inputText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 46)
                        .focused($inputIsFocused)
                        .onChange(of: inputText) { _, newValue in
                            sanitizeInput(newValue)
                        }
                        .onSubmit {
                            commitInput()
                        }
                        .onExitCommand {
                            cancelInput()
                        }
                        .onChange(of: inputIsFocused) { _, focused in
                            if !focused && isEditing {
                                commitInput()
                            }
                        }

                    Text("minutes")
                }
            } else {
                Text("\(Int(value)) minutes")
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        beginEditing()
                    }
                    .help("Double-click to enter a duration")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .accessibilityLabel("Timer duration")
        .accessibilityValue("\(Int(value)) minutes")
    }

    private func beginEditing() {
        inputText = String(Int(value))
        isEditing = true

        DispatchQueue.main.async {
            inputIsFocused = true
        }
    }

    private func sanitizeInput(_ newValue: String) {
        let digits = newValue.filter { "0123456789".contains($0) }
        let maximumLength = String(range.upperBound).count
        let sanitized = String(digits.prefix(maximumLength))

        if sanitized != newValue {
            inputText = sanitized
        }
    }

    private func commitInput() {
        guard let enteredValue = Int(inputText) else {
            cancelInput()
            return
        }

        value = Double(
            min(
                range.upperBound,
                max(range.lowerBound, enteredValue)
            )
        )
        isEditing = false
        inputIsFocused = false
    }

    private func cancelInput() {
        inputText = String(Int(value))
        isEditing = false
        inputIsFocused = false
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

// MARK: - Preset button

private struct PresetButton: View {
    let title: String
    let minutes: Int
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                if isSelected {
                    Button(action: action) {
                        buttonLabel
                    }
                    .buttonStyle(GlassProminentButtonStyle())
                } else {
                    Button(action: action) {
                        buttonLabel
                    }
                    .buttonStyle(GlassButtonStyle())
                }
            } else {
                if isSelected {
                    Button(action: action) {
                        buttonLabel
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(action: action) {
                        buttonLabel
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .accessibilityLabel("\(title), \(minutes) minutes")
    }

    private var buttonLabel: some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))

            Text("\(minutes)")
                .font(
                    .system(
                        size: 17,
                        weight: .semibold,
                        design: .rounded
                    )
                )
                .monospacedDigit()

            Text(title)
                .font(.caption2)
                .foregroundStyle(
                    isSelected ? .primary : .secondary
                )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 62)
        .contentShape(
            RoundedRectangle(
                cornerRadius: 18,
                style: .continuous
            )
        )
    }
}
// MARK: - Glass panel modifier

private struct GlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if interactive {
                content
                    .glassEffect(
                        .regular.interactive(),
                        in: RoundedRectangle(
                            cornerRadius: cornerRadius,
                            style: .continuous
                        )
                    )
            } else {
                content
                    .glassEffect(
                        .regular,
                        in: RoundedRectangle(
                            cornerRadius: cornerRadius,
                            style: .continuous
                        )
                    )
            }
        } else {
            content
                .background {
                    RoundedRectangle(
                        cornerRadius: cornerRadius,
                        style: .continuous
                    )
                    .fill(.ultraThinMaterial)
                }
                .overlay {
                    RoundedRectangle(
                        cornerRadius: cornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(
                        Color.primary.opacity(0.08)
                    )
                }
        }
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
