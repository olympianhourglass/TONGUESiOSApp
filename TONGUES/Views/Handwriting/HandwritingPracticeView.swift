import SwiftUI
import Combine

// The practice rectangle that appears below the flash card when handwriting
// mode is on. Drives two tiers behind one UI:
//   • strokeMatch (Chinese/Japanese) — validate each stroke against bundled
//     medians, in order; animate the correct stroke as a hint after failures.
//   • template   (Korean/Arabic, and any CJK word outside the bundled subset)
//     — trace a faint rendered guide; score by ink-coverage overlap.
//
// Styling mirrors the flash card: white surface, 4pt corners, soft shadow.
struct HandwritingPracticeView: View {
    let word: String
    let script: HandwritingScript
    // Fired once when the whole word has been written successfully, so the
    // session can count it toward the summary + bonus XP.
    var onCompleted: (() -> Void)? = nil

    @StateObject private var model: HandwritingPracticeModel
    @StateObject private var canvas = HandwritingCanvasController()

    // Template-mode sweep progress (0→1), and strokeMatch stroke-order
    // demo state: which stroke is currently being drawn and how far along.
    @State private var hintProgress: CGFloat = 0
    @State private var demoStroke: Int = -1
    @State private var demoProgress: CGFloat = 0
    @State private var demoTask: Task<Void, Never>?
    @State private var drawSide: CGFloat = 0

    private let accent = Color(red: 0.20, green: 0.48, blue: 0.92)
    private let goodColor = Color(red: 0.16, green: 0.55, blue: 0.36)
    private let badColor = Color(red: 0.80, green: 0.28, blue: 0.28)

    init(word: String, script: HandwritingScript, onCompleted: (() -> Void)? = nil) {
        self.word = word
        self.script = script
        self.onCompleted = onCompleted
        _model = StateObject(wrappedValue: HandwritingPracticeModel(word: word, script: script))
    }

    var body: some View {
        VStack(spacing: 10) {
            headerRow
            if model.mode == .strokeMatch, model.characters.count > 1 {
                characterStepper
            }
            drawingArea
            controlsRow
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 4)
        .onAppear {
            model.attach(canvas: canvas)
            model.loadStrokesIfNeeded()
        }
        .onChange(of: model.hintToken) { _, _ in replayHint() }
        .onChange(of: model.status) { _, newValue in
            if newValue == .complete { onCompleted?() }
        }
        .onDisappear { stopStrokeDemo() }
    }

    // MARK: Character stepper (multi-character words)

    // A row of the word's characters. The current one is filled; finished
    // ones get a green ring; tap any to jump straight to it. Makes the 2nd
    // and 3rd characters obviously reachable instead of only auto-advancing.
    private var characterStepper: some View {
        HStack(spacing: 8) {
            ForEach(Array(model.characters.enumerated()), id: \.offset) { index, character in
                let isCurrent = index == model.currentCharIndex
                let done = model.completedCharIndices.contains(index)
                Button {
                    Haptics.light()
                    stopStrokeDemo()
                    model.selectCharacter(index)
                } label: {
                    Text(String(character))
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(isCurrent ? .white : .black)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(isCurrent ? Color.black : Color(white: 0.93)))
                        .overlay(Circle().stroke(done ? goodColor : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header — target + progress

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black)
                Text(model.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(model.feedbackColorHint(good: goodColor, bad: badColor) ?? .secondary)
            }
            Spacer()
            if model.mode == .strokeMatch {
                Text("\(model.completedStrokes)/\(model.totalStrokes)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(Int(model.lastRecall * 100))%")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(model.lastRecall > 0.001 ? .black : .secondary)
            }
        }
    }

    // MARK: Drawing square

    private var drawingArea: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, 210)
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(white: 0.975))

                GuideGridShape()
                    .stroke(Color(white: 0.86), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .allowsHitTesting(false)

                // Tier-specific faint guide.
                if model.mode == .strokeMatch, let layout = model.currentLayout {
                    // Whole-character skeleton (very faint) + already-done
                    // strokes slightly darker so progress reads at a glance.
                    PolylineShape(strokes: layout.viewStrokes)
                        .stroke(Color(white: 0.82),
                                style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                        .allowsHitTesting(false)
                    PolylineShape(strokes: Array(layout.viewStrokes.prefix(model.completedStrokes)))
                        .stroke(Color(white: 0.72),
                                style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                        .allowsHitTesting(false)
                } else if let img = model.templateImage {
                    Image(uiImage: img)
                        .resizable()
                        .frame(width: side, height: side)
                        .opacity(model.templateOpacity)
                        .allowsHitTesting(false)
                }

                // The ink surface.
                HandwritingCanvasView(
                    controller: canvas,
                    strokeColor: UIColor(white: 0.05, alpha: 1),
                    onStrokeEnd: { last, all in
                        model.handleStroke(last: last, all: all)
                    }
                )

                // Level-1 hint: a dot marking where the next stroke starts.
                if model.mode == .strokeMatch, model.hintLevel == 1, demoStroke < 0,
                   let hint = model.hintStrokePoints, let start = hint.first {
                    Circle()
                        .fill(accent.opacity(0.9))
                        .frame(width: 12, height: 12)
                        .position(start)
                        .allowsHitTesting(false)
                }
                // Level-2 hint: play the character's full stroke order, one
                // stroke at a time. Strokes already demonstrated stay drawn
                // (faint); the current stroke animates on with a start dot.
                if model.mode == .strokeMatch, demoStroke >= 0,
                   let strokes = model.currentLayout?.viewStrokes {
                    PolylineShape(strokes: Array(strokes.prefix(demoStroke)))
                        .stroke(accent.opacity(0.4),
                                style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                        .allowsHitTesting(false)
                    if strokes.indices.contains(demoStroke) {
                        PolylineShape(strokes: [strokes[demoStroke]])
                            .trim(from: 0, to: demoProgress)
                            .stroke(accent.opacity(0.9),
                                    style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                            .allowsHitTesting(false)
                        if let start = strokes[demoStroke].first {
                            Circle()
                                .fill(accent)
                                .frame(width: 12, height: 12)
                                .position(start)
                                .allowsHitTesting(false)
                        }
                    }
                }

                // Template direction sweep hint.
                if model.mode == .template, model.hintLevel >= 2, let img = model.templateImage {
                    Image(uiImage: img)
                        .resizable()
                        .frame(width: side, height: side)
                        .opacity(0.9)
                        .mask(
                            Rectangle()
                                .frame(width: side * 0.28)
                                .position(x: sweepX(side: side), y: side / 2)
                        )
                        .allowsHitTesting(false)
                }

                // Success flourish.
                if model.status == .complete {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(goodColor.opacity(0.7), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity)
            .onAppear { updateRect(side) }
            .onChange(of: side) { _, s in updateRect(s) }
        }
        .frame(height: 210)
    }

    // MARK: Controls

    private var controlsRow: some View {
        HStack(spacing: 10) {
            practiceButton(title: model.status == .complete ? "Again" : "Clear", filled: false) {
                Haptics.light()
                model.clearCurrent()
                hintProgress = 0
                stopStrokeDemo()
            }
            practiceButton(title: "Hint", filled: false) {
                Haptics.light()
                model.requestHint()
            }
            if model.mode == .template && model.status != .complete {
                practiceButton(title: "Check", filled: true) {
                    Haptics.medium()
                    model.check()
                }
            }
        }
    }

    private func practiceButton(title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(filled ? .white : .black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(filled ? Color.black : Color(white: 0.93),
                            in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    // MARK: Helpers

    private func updateRect(_ side: CGFloat) {
        guard side > 1 else { return }
        drawSide = side
        model.setRect(CGRect(x: 0, y: 0, width: side, height: side))
    }

    private func replayHint() {
        if model.mode == .template {
            hintProgress = 0
            withAnimation(.easeInOut(duration: 1.15)) { hintProgress = 1 }
        } else {
            playStrokeDemo()
        }
    }

    // Animates the current character stroke-by-stroke, in the correct
    // order and direction, from the bundled/loaded median data.
    private func playStrokeDemo() {
        demoTask?.cancel()
        guard let strokes = model.currentLayout?.viewStrokes, !strokes.isEmpty else { return }
        demoTask = Task { @MainActor in
            for i in strokes.indices {
                if Task.isCancelled { return }
                demoStroke = i
                demoProgress = 0
                withAnimation(.easeInOut(duration: 0.5)) { demoProgress = 1 }
                try? await Task.sleep(for: .milliseconds(650))
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(300))
            demoStroke = -1
        }
    }

    private func stopStrokeDemo() {
        demoTask?.cancel()
        demoTask = nil
        demoStroke = -1
    }

    // Left→right for LTR scripts, right→left for Arabic.
    private func sweepX(side: CGFloat) -> CGFloat {
        let t = hintProgress
        return script.isRightToLeft ? side * (1 - t) : side * t
    }
}

// MARK: - Model

final class HandwritingPracticeModel: ObservableObject {
    enum Mode { case strokeMatch, template }
    enum Status { case inProgress, complete }

    let word: String
    let script: HandwritingScript
    // Starts as template when no stroke data is on hand; upgrades to
    // strokeMatch if the CDN fetch fills in coverage (see loadStrokesIfNeeded).
    @Published private(set) var mode: Mode

    // strokeMatch state
    private var chars: [Character] = []
    @Published private(set) var currentCharIndex = 0
    @Published private(set) var expectedStrokeIndex = 0
    @Published private(set) var completedStrokes = 0
    @Published private(set) var currentLayout: CharacterLayout?
    // Which characters of the word have been written successfully, so the
    // stepper can mark them and the word finishes once all are done.
    @Published private(set) var completedCharIndices: Set<Int> = []

    /// The word's practicable characters, for the navigation stepper.
    var characters: [Character] { chars }

    // template state
    @Published private(set) var templateImage: UIImage?
    @Published private(set) var templateOpacity: Double = 0.14
    @Published private(set) var lastRecall: Double = 0
    private var glyph: TemplateGlyph?

    // shared
    @Published private(set) var status: Status = .inProgress
    @Published private(set) var hintLevel = 0
    @Published private(set) var hintStrokePoints: [CGPoint]?
    @Published private(set) var hintToken = 0
    @Published private(set) var feedback: Feedback = .none

    private var attempts = 0
    private var rect: CGRect = .zero
    private weak var canvas: HandwritingCanvasController?

    enum Feedback: Equatable {
        case none, good, charDone, allDone
        case bad(String)
        case tracing
    }

    init(word: String, script: HandwritingScript) {
        self.word = word
        self.script = script
        let store = StrokeDataStore.shared
        if script.tier == .strokeMatch, store.hasFullCoverage(for: word, script: script) {
            self.mode = .strokeMatch
            self.chars = Array(word.filter { !$0.isWhitespace })
        } else {
            self.mode = .template
        }
    }

    func attach(canvas: HandwritingCanvasController) {
        self.canvas = canvas
    }

    // If this word landed in template mode only because we didn't have
    // stroke data on hand, try to fetch it (Chinese/Japanese). When the
    // whole word becomes covered, upgrade to true stroke-order practice.
    func loadStrokesIfNeeded() {
        guard script.tier == .strokeMatch, mode == .template else { return }
        let word = self.word
        let script = self.script
        Task { @MainActor [weak self] in
            let covered = await StrokeDataStore.shared.ensureCoverage(for: word, script: script)
            guard let self, covered, self.mode == .template else { return }
            self.upgradeToStrokeMatch()
        }
    }

    private func upgradeToStrokeMatch() {
        mode = .strokeMatch
        chars = Array(word.filter { !$0.isWhitespace })
        currentCharIndex = 0
        expectedStrokeIndex = 0
        completedStrokes = 0
        completedCharIndices = []
        attempts = 0
        setHintLevel(0)
        feedback = .none
        canvas?.clear()
        if rect.width > 1 { rebuildLayout() }
    }

    // Jump to any character in the word so multi-character words are freely
    // navigable — the user can move ahead or go back and redraw one.
    func selectCharacter(_ index: Int) {
        guard mode == .strokeMatch, chars.indices.contains(index) else { return }
        currentCharIndex = index
        expectedStrokeIndex = 0
        completedStrokes = 0
        attempts = 0
        setHintLevel(0)
        feedback = .none
        if status == .complete { status = .inProgress }
        canvas?.clear()
        rebuildLayout()
    }

    func setRect(_ rect: CGRect) {
        let changed = rect != self.rect
        self.rect = rect
        guard changed, rect.width > 1 else { return }
        switch mode {
        case .strokeMatch: rebuildLayout()
        case .template: renderTemplate()
        }
    }

    // MARK: Titles

    var title: String {
        switch mode {
        case .strokeMatch:
            return chars.count > 1
                ? "Write \(String(chars[safe: currentCharIndex] ?? " ")) · \(currentCharIndex + 1)/\(chars.count)"
                : "Write the character"
        case .template:
            return script == .arabic ? "Trace the word (right → left)" : "Trace the character"
        }
    }

    var subtitle: String {
        switch feedback {
        case .none:
            if mode == .strokeMatch { return "Follow the stroke order" }
            return script == .korean ? Hangul.breakdown(word).isEmpty ? "Cover the whole shape" : Hangul.breakdown(word)
                                     : "Cover the whole shape"
        case .good: return "Good"
        case .charDone: return "Character complete"
        case .allDone: return "Nicely written!"
        case .tracing: return "Keep going…"
        case .bad(let reason): return reason
        }
    }

    var totalStrokes: Int { currentLayout?.strokes.count ?? 0 }

    func feedbackColorHint(good: Color, bad: Color) -> Color? {
        switch feedback {
        case .good, .charDone, .allDone: return good
        case .bad: return bad
        default: return nil
        }
    }

    // MARK: strokeMatch

    private func rebuildLayout() {
        guard mode == .strokeMatch, chars.indices.contains(currentCharIndex),
              let strokes = StrokeDataStore.shared.strokes(for: chars[currentCharIndex], script: script) else {
            currentLayout = nil
            return
        }
        currentLayout = CharacterLayout(strokes: strokes, in: rect)
        refreshHintStroke()
    }

    func handleStroke(last: [CGPoint], all: [[CGPoint]]) {
        switch mode {
        case .strokeMatch: handleStrokeMatch(last)
        case .template: handleTemplateStroke(all)
        }
    }

    private func handleStrokeMatch(_ user: [CGPoint]) {
        guard status == .inProgress, let layout = currentLayout else {
            canvas?.acceptCurrent(); return
        }
        let target = layout.viewStroke(expectedStrokeIndex)
        let charSize = min(rect.width, rect.height)
        let result = StrokeMatcher.match(user: user, median: target, charSize: charSize)

        if result.accepted {
            canvas?.acceptCurrent()
            expectedStrokeIndex += 1
            completedStrokes = expectedStrokeIndex
            attempts = 0
            setHintLevel(0)
            Haptics.light()
            if expectedStrokeIndex >= layout.strokes.count {
                finishCharacter()
            } else {
                feedback = .good
                refreshHintStroke()
            }
        } else {
            canvas?.removeLastStroke()
            attempts += 1
            feedback = .bad(Self.reasonText(result.reason))
            Haptics.error()
            escalateHint()
        }
    }

    private func finishCharacter() {
        Haptics.success()
        completedCharIndices.insert(currentCharIndex)
        // Move to the next character that still needs writing (wrapping so
        // out-of-order practice via the stepper still finds the remainder).
        if let next = nextIncompleteIndex() {
            feedback = .charDone
            currentCharIndex = next
            expectedStrokeIndex = 0
            completedStrokes = 0
            attempts = 0
            setHintLevel(0)
            canvas?.clear()
            rebuildLayout()
        } else {
            feedback = .allDone
            status = .complete
        }
    }

    private func nextIncompleteIndex() -> Int? {
        guard !chars.isEmpty else { return nil }
        for offset in 1...chars.count {
            let i = (currentCharIndex + offset) % chars.count
            if !completedCharIndices.contains(i) { return i }
        }
        return nil
    }

    private func refreshHintStroke() {
        guard let layout = currentLayout, expectedStrokeIndex < layout.strokes.count else {
            hintStrokePoints = nil; return
        }
        hintStrokePoints = layout.viewStroke(expectedStrokeIndex)
    }

    // MARK: template

    private func renderTemplate() {
        glyph = TemplateGlyph.render(text: word, script: script, in: rect.size)
        templateImage = glyph?.displayImage
    }

    private func handleTemplateStroke(_ all: [[CGPoint]]) {
        guard status == .inProgress else { canvas?.acceptCurrent(); return }
        canvas?.acceptCurrent()
        // Don't grade mid-draw. The learner decides when the tracing is
        // finished and taps Check — grading every stroke made the card
        // "pass" the instant enough ink landed, before they were done.
        feedback = .tracing
    }

    func check() {
        guard mode == .template, status == .inProgress, let glyph else { return }
        let all = canvas?.allStrokePoints() ?? []
        let cov = glyph.evaluate(userStrokes: all, rect: rect)
        lastRecall = cov.recall
        if cov.passed {
            complete()
            return
        }
        attempts += 1
        feedback = .bad(cov.recall < 0.25 ? "Trace over the guide" : "Almost — cover more of the shape")
        Haptics.error()
        escalateHint()

        // Best-effort OCR upgrade for a borderline trace; never rejects.
        if cov.recall >= 0.35 {
            let rectCopy = rect
            Task { [weak self] in
                guard let self else { return }
                let hits = await HandwritingOCR.recognize(strokes: all, rect: rectCopy, script: self.script)
                if hits.contains(where: { $0.contains(self.word) }) {
                    await MainActor.run { if self.status == .inProgress { self.complete() } }
                }
            }
        }
    }

    private func complete() {
        Haptics.success()
        feedback = .allDone
        status = .complete
    }

    // MARK: hints

    func requestHint() {
        setHintLevel(min(hintLevel + 1, 3))
        if hintLevel >= 2 { replay() }
        else if mode == .template { bumpTemplateOpacity() }
    }

    private func escalateHint() {
        let level = attempts >= 4 ? 3 : attempts >= 3 ? 2 : attempts >= 2 ? 1 : 0
        if level != hintLevel {
            setHintLevel(level)
            if level >= 2 { replay() }
        }
    }

    private func setHintLevel(_ level: Int) {
        hintLevel = level
        if mode == .template {
            templateOpacity = level >= 3 ? 0.42 : level >= 1 ? 0.28 : 0.14
        }
    }

    private func bumpTemplateOpacity() {
        templateOpacity = min(0.45, templateOpacity + 0.1)
    }

    private func replay() {
        refreshHintStroke()
        hintToken += 1
    }

    // MARK: clear / reset

    func clearCurrent() {
        canvas?.clear()
        feedback = .none
        if status == .complete {
            // Restart the whole word.
            status = .inProgress
            currentCharIndex = 0
            expectedStrokeIndex = 0
            completedStrokes = 0
            completedCharIndices = []
            lastRecall = 0
            attempts = 0
            setHintLevel(0)
            if mode == .strokeMatch { rebuildLayout() }
        } else if mode == .strokeMatch {
            expectedStrokeIndex = 0
            completedStrokes = 0
            refreshHintStroke()
        } else {
            lastRecall = 0
        }
    }

    static func reasonText(_ reason: String) -> String {
        switch reason {
        case "wrong-direction": return "Wrong direction — follow the arrow"
        case "wrong-start":     return "Start in the right spot"
        case "wrong-end":       return "Ends in the wrong place"
        case "too-short":       return "Draw the full stroke"
        default:                return "Not quite — try again"
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Shapes

// Classic CJK practice grid: border, centre cross, and diagonals.
struct GuideGridShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRect(rect)
        p.move(to: CGPoint(x: rect.midX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.move(to: CGPoint(x: rect.minX, y: rect.midY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.move(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return p
    }
}

// Draws a set of polylines (already in view coordinates).
struct PolylineShape: Shape {
    var strokes: [[CGPoint]]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for stroke in strokes where stroke.count > 1 {
            p.move(to: stroke[0])
            for pt in stroke.dropFirst() { p.addLine(to: pt) }
        }
        return p
    }
}
