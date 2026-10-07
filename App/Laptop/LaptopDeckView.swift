import SwiftUI
import UIKit
import InputCore
import SessionCore

/// Connects the laptop deck to the surface it drives.
///
/// The deck and the surface are siblings in SwiftUI, and neither should own
/// the other: the surface is kept across layout changes so its texture
/// survives, while the deck comes and goes with the hinge. The surface
/// registers itself here when it is configured.
@MainActor
final class LaptopDeckChannel {
    weak var surface: RemoteDesktopView?
}

/// What the lower half holds, and in which order from the hinge down.
enum LaptopDeckArrangement: String, CaseIterable {
    case keyboardAboveTrackpad
    case trackpadAboveKeyboard
    /// The whole lower half is keyboard; the pointer is moved by touching
    /// the desktop above, which then works as the trackpad.
    case keyboardOnly

    var hasTrackpad: Bool { self != .keyboardOnly }

    static let storageKey = "laptop-deck-arrangement"
    /// Whether the pad has left and right buttons under it. Without them the
    /// pad takes their room: a tap is a left click, a two-finger tap a right
    /// click, and hold-then-move drags.
    static let trackpadButtonsStorageKey = "laptop-trackpad-buttons"
}

extension CapsLockRole {
    static let storageKey = "laptop-caps-lock-role"

    /// For the menu, in the host's words.
    var title: String {
        switch self {
        case .capsLock: return "Caps Lock"
        case .control: return "Ctrl"
        case .option: return "Option"
        case .command: return "Command"
        case .escape: return "Esc"
        case .noAction: return "何もしない"
        }
    }
}

/// The lower half of a foldable in laptop posture: a PC keyboard and a
/// trackpad with two buttons, in one view.
///
/// One view rather than a keyboard and a trackpad side by side, because the
/// two are used together - a thumb holding the left button while a finger
/// drags on the pad, a finger on Shift while another taps a letter - and
/// UIKit only gives one view every touch of a multi-touch sequence.
final class LaptopDeckView: UIView {
    private enum Region {
        case key(LaptopKey)
        case pad
        case button(PointerButton)
    }

    private let channel: LaptopDeckChannel
    private var layout: LaptopKeyboardLayout
    private var arrangement: LaptopDeckArrangement
    private var showsTrackpadButtons = true
    private var composer = LaptopKeyboardComposer()
    private var isInputEnabled = false

    private var keyViews: [String: KeyCapView] = [:]
    private var keyFrames: [(frame: CGRect, key: LaptopKey)] = []
    private let pad = UIView()
    private let leftButton = UIView()
    private let rightButton = UIView()
    private var regions: [ObjectIdentifier: Region] = [:]
    /// When each touch began, for the Windows key: tapped it opens Start,
    /// held it latches.
    private var touchStarts: [ObjectIdentifier: TimeInterval] = [:]
    private let haptics = UIImpactFeedbackGenerator(style: .light)

    private var repeatTimer: Timer?
    private let padTracker: TrackpadGestureTracker

    init(
        layout: LaptopKeyboardLayout,
        arrangement: LaptopDeckArrangement,
        channel: LaptopDeckChannel
    ) {
        self.layout = layout
        self.arrangement = arrangement
        self.channel = channel
        padTracker = TrackpadGestureTracker { [weak channel] in channel?.surface }
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.09, alpha: 1)
        isMultipleTouchEnabled = true
        accessibilityIdentifier = "laptop-deck"
        applyInputEnabledAppearance()
        buildKeys()

        pad.backgroundColor = UIColor(white: 0.15, alpha: 1)
        pad.layer.cornerRadius = 12
        pad.layer.cornerCurve = .continuous
        pad.layer.borderColor = UIColor(white: 0.28, alpha: 1).cgColor
        pad.layer.borderWidth = 1
        pad.isUserInteractionEnabled = false
        pad.isAccessibilityElement = true
        pad.accessibilityLabel = "トラックパッド"
        pad.accessibilityIdentifier = "laptop-trackpad"
        addSubview(pad)

        for (button, title, identifier) in [
            (leftButton, "左クリック", "laptop-button-left"),
            (rightButton, "右クリック", "laptop-button-right"),
        ] {
            button.backgroundColor = UIColor(white: 0.2, alpha: 1)
            button.layer.cornerRadius = 8
            button.layer.cornerCurve = .continuous
            button.isUserInteractionEnabled = false
            button.isAccessibilityElement = true
            button.accessibilityLabel = title
            button.accessibilityTraits = .button
            button.accessibilityIdentifier = identifier
            addSubview(button)
        }
        applyArrangement()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setLayout(_ newLayout: LaptopKeyboardLayout) {
        guard newLayout != layout else { return }
        releaseEverything()
        layout = newLayout
        keyViews.values.forEach { $0.removeFromSuperview() }
        keyViews = [:]
        buildKeys()
        setNeedsLayout()
    }

    func setArrangement(_ newArrangement: LaptopDeckArrangement) {
        guard newArrangement != arrangement else { return }
        releaseEverything()
        arrangement = newArrangement
        applyArrangement()
        setNeedsLayout()
    }

    func setTrackpadButtons(_ shows: Bool) {
        guard shows != showsTrackpadButtons else { return }
        releaseEverything()
        showsTrackpadButtons = shows
        applyArrangement()
        setNeedsLayout()
    }

    private var hasButtons: Bool { arrangement.hasTrackpad && showsTrackpadButtons }

    private func applyArrangement() {
        pad.isHidden = !arrangement.hasTrackpad
        leftButton.isHidden = !hasButtons
        rightButton.isHidden = !hasButtons
    }

    /// Closing the gate lets go of everything, exactly as the surface does:
    /// a key or a button held across a menu or a session switch would stay
    /// down on the host.
    func setInputEnabled(_ enabled: Bool) {
        guard enabled != isInputEnabled else { return }
        isInputEnabled = enabled
        padTracker.setEnabled(enabled)
        if !enabled { releaseEverything() }
        applyInputEnabledAppearance()
    }

    /// Dimmed while closed, from the start: the deck begins closed, and a
    /// deck that looks live but ignores every key is the worst of both.
    private func applyInputEnabledAppearance() {
        alpha = isInputEnabled ? 1 : 0.6
        accessibilityValue = isInputEnabled ? "入力可" : "入力不可"
    }

    func releaseEverything() {
        stopRepeat()
        channel.surface?.sendLaptopKeys(composer.releaseAll())
        for case .button(let button) in regions.values {
            channel.surface?.setLaptopButton(button, pressed: false)
        }
        regions = [:]
        touchStarts = [:]
        padTracker.reset()
        refreshKeys()
        refreshButtons()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { releaseEverything() }
    }

    // MARK: - Layout

    private func buildKeys() {
        for key in layout.keys {
            let view = KeyCapView(key: key) { [weak self] key in
                self?.accessibilityTap(key)
            }
            keyViews[key.id] = view
            addSubview(view)
        }
        refreshKeys()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.inset(by: safeAreaInsets).insetBy(dx: 6, dy: 6)
        guard area.width > 0, area.height > 0 else { return }

        let spacing: CGFloat = 10
        let keyboardHeight: CGFloat
        let keyboardY: CGFloat
        let lower: CGRect
        switch arrangement {
        case .keyboardOnly:
            // Keys taller than a thumb only make the reach longer, so the
            // spare height goes above and below rather than into the keys.
            keyboardHeight = min(area.height, 340)
            keyboardY = area.midY - keyboardHeight / 2
            lower = .zero
        case .keyboardAboveTrackpad:
            keyboardHeight = (area.height * 0.56).rounded()
            keyboardY = area.minY
            lower = CGRect(
                x: area.minX,
                y: keyboardY + keyboardHeight + spacing,
                width: area.width,
                height: area.height - keyboardHeight - spacing
            )
        case .trackpadAboveKeyboard:
            keyboardHeight = (area.height * 0.56).rounded()
            keyboardY = area.maxY - keyboardHeight
            lower = CGRect(
                x: area.minX,
                y: area.minY,
                width: area.width,
                height: area.height - keyboardHeight - spacing
            )
        }
        layoutKeys(in: CGRect(x: area.minX, y: keyboardY, width: area.width, height: keyboardHeight))
        if arrangement.hasTrackpad {
            layoutTrackpad(in: lower)
        }
    }

    private func layoutKeys(in keyboard: CGRect) {
        let totalRowHeight = layout.rows.reduce(0) { $0 + $1.height }
        let gap: CGFloat = 4
        let unitHeight = (keyboard.height - gap * CGFloat(layout.rows.count - 1)) / CGFloat(totalRowHeight)
        let unitWidth = keyboard.width / CGFloat(LaptopKeyboardLayout.unitsPerRow)

        keyFrames = []
        var parts: [String: [CGRect]] = [:]
        var y = keyboard.minY
        for row in layout.rows {
            let height = unitHeight * CGFloat(row.height)
            var x = keyboard.minX
            for key in row.keys {
                let width = unitWidth * CGFloat(key.width)
                let hitFrame = CGRect(x: x, y: y - gap / 2, width: width, height: height + gap)
                keyFrames.append((hitFrame, key))
                parts[key.id, default: []].append(
                    CGRect(x: x, y: y, width: width, height: height).insetBy(dx: gap / 2, dy: 0)
                )
                x += width
            }
            y += height + gap
        }
        for (id, rects) in parts {
            keyViews[id]?.setParts(rects)
        }
    }

    /// The pad with its two buttons below it, on the user's side, as on a
    /// laptop: the buttons sit under the thumbs whichever way round the
    /// keyboard is.
    private func layoutTrackpad(in lower: CGRect) {
        let padWidth = min(lower.width, max(lower.width * 0.72, 300))
        let buttonHeight = hasButtons ? min(40, lower.height * 0.22) : 0
        let padHeight = lower.height - (hasButtons ? buttonHeight + 6 : 0)
        let padFrame = CGRect(
            x: lower.midX - padWidth / 2,
            y: lower.minY,
            width: padWidth,
            height: padHeight
        )
        pad.frame = padFrame
        let buttonY = padFrame.maxY + 6
        leftButton.frame = CGRect(x: padFrame.minX, y: buttonY, width: padWidth / 2 - 3, height: buttonHeight)
        rightButton.frame = CGRect(
            x: padFrame.midX + 3,
            y: buttonY,
            width: padWidth / 2 - 3,
            height: buttonHeight
        )
    }

    private func region(at point: CGPoint) -> Region? {
        if let key = keyFrames.first(where: { $0.frame.contains(point) })?.key {
            return .key(key)
        }
        guard arrangement.hasTrackpad else { return nil }
        if hasButtons, leftButton.frame.insetBy(dx: -3, dy: -4).contains(point) { return .button(.left) }
        if hasButtons, rightButton.frame.insetBy(dx: -3, dy: -4).contains(point) { return .button(.right) }
        if pad.frame.insetBy(dx: -8, dy: -8).contains(point) { return .pad }
        return nil
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let region = region(at: touch.location(in: self)) else { continue }
            let id = ObjectIdentifier(touch)
            regions[id] = region
            touchStarts[id] = touch.timestamp
            switch region {
            case .key(let key):
                keyDown(key)
            case .button(let button):
                haptics.impactOccurred()
                channel.surface?.setLaptopButton(button, pressed: isInputEnabled)
                refreshButtons()
            case .pad:
                padTracker.began(touch, in: self)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let padTouches = touches.filter { regions[ObjectIdentifier($0)].map(Self.isPad) ?? false }
        if !padTouches.isEmpty { padTracker.moved(Array(padTouches), in: self) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            let start = touchStarts.removeValue(forKey: id) ?? touch.timestamp
            guard let region = regions.removeValue(forKey: id) else { continue }
            switch region {
            case .key(let key):
                keyUp(key, heldFor: touch.timestamp - start)
            case .button(let button):
                if !regions.values.contains(where: { Self.isButton($0, button) }) {
                    channel.surface?.setLaptopButton(button, pressed: false)
                }
                refreshButtons()
            case .pad:
                padTracker.ended(touch, cancelled: cancelled)
            }
        }
    }

    private static func isPad(_ region: Region) -> Bool {
        if case .pad = region { return true }
        return false
    }

    private static func isButton(_ region: Region, _ button: PointerButton) -> Bool {
        if case .button(let held) = region { return held == button }
        return false
    }

    // MARK: - Keyboard

    private func keyDown(_ key: LaptopKey) {
        guard isInputEnabled else { return }
        haptics.impactOccurred(intensity: 0.6)
        let events = composer.touchDown(key)
        channel.surface?.sendLaptopKeys(events)
        if key.repeats, case .key(let usage) = key.kind, !events.isEmpty {
            armRepeat(usage: usage, after: KeyRepeatSettings().initialDelay)
        }
        refreshKeys()
    }

    private func keyUp(_ key: LaptopKey, heldFor: TimeInterval) {
        // A second finger on the same key is not a second press, so the key
        // only comes up when the last finger on it lifts.
        let stillHeld = regions.values.contains { region in
            if case .key(let other) = region { return other.kind == key.kind && !key.isModifier }
            return false
        }
        if !stillHeld {
            channel.surface?.sendLaptopKeys(composer.touchUp(key, heldFor: heldFor))
        }
        refreshKeys()
    }

    /// Repeats the most recent key only, as a PC keyboard does: pressing a
    /// second key while the first is held hands the repeat over.
    private func armRepeat(usage: UInt16, after delay: TimeInterval) {
        stopRepeat()
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { [weak self] in self?.fireRepeat(usage: usage) }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func fireRepeat(usage: UInt16) {
        guard isInputEnabled, let down = composer.repeatDown(usage: usage) else {
            stopRepeat()
            return
        }
        channel.surface?.sendLaptopKeys([down])
        armRepeat(usage: usage, after: KeyRepeatSettings().interval)
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func accessibilityTap(_ key: LaptopKey) {
        guard isInputEnabled else { return }
        channel.surface?.sendLaptopKeys(composer.touchDown(key))
        channel.surface?.sendLaptopKeys(composer.touchUp(key))
        refreshKeys()
    }

    private func refreshKeys() {
        for key in layout.keys {
            guard let view = keyViews[key.id] else { continue }
            switch key.kind {
            case .modifier(let modifier):
                view.state = composer.latches.latch(modifier) == .locked ? .locked
                    : composer.isActive(modifier) ? .active : .idle
            case .key(let usage):
                view.state = composer.isDown(usage: usage) ? .pressed : .idle
            case .inert:
                view.state = .idle
            }
        }
    }

    private func refreshButtons() {
        let held = Set(regions.values.compactMap { region -> PointerButton? in
            if case .button(let button) = region { return button }
            return nil
        })
        leftButton.backgroundColor = UIColor(white: held.contains(.left) ? 0.38 : 0.2, alpha: 1)
        rightButton.backgroundColor = UIColor(white: held.contains(.right) ? 0.38 : 0.2, alpha: 1)
    }
}

/// One key cap. The deck does the touch handling; this only draws, and
/// stands in for the key to VoiceOver.
private final class KeyCapView: UIView {
    enum State {
        case idle
        case pressed
        /// A modifier held or latched for the next key.
        case active
        case locked
    }

    let key: LaptopKey
    private let onActivate: (LaptopKey) -> Void
    private let label = UILabel()
    private let shiftedLabel = UILabel()
    private let lockIndicator = UIView()
    /// The cap's outline, so a key spanning two rows draws as one shape.
    private let capLayer = CAShapeLayer()
    /// Where the labels go, in the view's own coordinates: the first part of
    /// a key that spans two rows, the whole key otherwise.
    private var labelArea: CGRect = .zero

    var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            applyState()
        }
    }

    init(key: LaptopKey, onActivate: @escaping (LaptopKey) -> Void) {
        self.key = key
        self.onActivate = onActivate
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.addSublayer(capLayer)

        label.text = key.label
        label.textColor = .white
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        addSubview(label)

        shiftedLabel.text = key.shiftedLabel
        shiftedLabel.textColor = UIColor(white: 0.7, alpha: 1)
        shiftedLabel.textAlignment = .center
        shiftedLabel.isHidden = key.shiftedLabel == nil
        addSubview(shiftedLabel)

        lockIndicator.backgroundColor = .systemGreen
        lockIndicator.layer.cornerRadius = 2
        lockIndicator.isHidden = true
        addSubview(lockIndicator)

        isAccessibilityElement = true
        accessibilityLabel = Self.spokenName(for: key)
        accessibilityTraits = .keyboardKey
        accessibilityIdentifier = "laptop-key-\(key.id)"
        if key.sendsWhenTappedAlone {
            accessibilityHint = "タップで単独で送信。長押しで次のキーと組み合わせ"
        }
        applyState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func accessibilityActivate() -> Bool {
        onActivate(key)
        return true
    }

    /// The rectangles the key occupies, in the superview's coordinates, one
    /// per row. Parts in consecutive rows are joined across the gap between
    /// them, which is what turns the JIS Enter into one inverted L.
    func setParts(_ parts: [CGRect]) {
        guard let first = parts.first else { return }
        var filled = parts
        for index in filled.indices.dropLast() {
            filled[index].size.height = filled[index + 1].minY - filled[index].minY
        }
        let union = parts.dropFirst().reduce(first) { $0.union($1) }
        frame = union
        let local = filled.map { $0.offsetBy(dx: -union.minX, dy: -union.minY) }
        var path = CGPath(roundedRect: local[0], cornerWidth: 5, cornerHeight: 5, transform: nil)
        for rect in local.dropFirst() {
            path = path.union(CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil))
        }
        capLayer.path = path
        labelArea = parts[0].offsetBy(dx: -union.minX, dy: -union.minY)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = labelArea.isEmpty ? bounds : labelArea
        let small = area.height < 30
        let size = min(area.height * (small ? 0.42 : 0.4), 17)
        label.font = .systemFont(ofSize: size, weight: key.label.count > 2 ? .regular : .medium)
        shiftedLabel.font = .systemFont(ofSize: size * 0.62)
        if shiftedLabel.isHidden {
            label.frame = area.insetBy(dx: 2, dy: 1)
        } else {
            let half = area.height / 2
            shiftedLabel.frame = CGRect(x: area.minX + 2, y: area.minY + 2, width: area.width - 4, height: half - 2)
            label.frame = CGRect(x: area.minX + 2, y: area.minY + half - 2, width: area.width - 4, height: half)
        }
        lockIndicator.frame = CGRect(x: area.maxX - 9, y: area.minY + 4, width: 5, height: 5)
    }

    private func applyState() {
        let fill: UIColor
        switch state {
        case .idle:
            fill = key.isModifier ? UIColor(white: 0.17, alpha: 1) : UIColor(white: 0.22, alpha: 1)
        case .pressed:
            fill = UIColor(white: 0.45, alpha: 1)
        case .active, .locked:
            fill = .systemBlue
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capLayer.fillColor = fill.cgColor
        CATransaction.commit()
        lockIndicator.isHidden = state != .locked
        switch state {
        case .idle: accessibilityValue = key.isModifier ? "オフ" : nil
        case .pressed: accessibilityValue = nil
        case .active: accessibilityValue = "次の1キー"
        case .locked: accessibilityValue = "固定"
        }
    }

    private static func spokenName(for key: LaptopKey) -> String {
        switch key.id {
        case "space": return "スペース"
        case "backspace": return "バックスペース"
        case "enter": return "エンター"
        case "command-left", "command-right": return "コマンド"
        case "alt-left", "alt-right": return key.label == "⌥" ? "オプション" : key.label
        case "delete": return key.label == "⌦" ? "前方削除" : key.label
        case "up": return "上"
        case "down": return "下"
        case "left": return "左"
        case "right": return "右"
        default: return key.label
        }
    }
}

/// Puts the deck in SwiftUI and keeps it told about the gate and the layout.
struct LaptopDeck: UIViewRepresentable {
    let layout: KeyboardLayoutPreference
    let arrangement: LaptopDeckArrangement
    let channel: LaptopDeckChannel
    let isInputEnabled: Bool
    var capsLockRole: CapsLockRole = .capsLock
    var showsTrackpadButtons = true
    /// Only Windows hosts exist today; a Mac host's session will pass `.mac`.
    var platform: LaptopKeyboardPlatform = .windows

    func makeUIView(context: Context) -> LaptopDeckView {
        let view = LaptopDeckView(
            layout: LaptopKeyboardLayout(layout, platform: platform, capsLockRole: capsLockRole),
            arrangement: arrangement,
            channel: channel
        )
        view.setTrackpadButtons(showsTrackpadButtons)
        view.setInputEnabled(isInputEnabled)
        return view
    }

    func updateUIView(_ view: LaptopDeckView, context: Context) {
        view.setLayout(LaptopKeyboardLayout(layout, platform: platform, capsLockRole: capsLockRole))
        view.setArrangement(arrangement)
        view.setTrackpadButtons(showsTrackpadButtons)
        view.setInputEnabled(isInputEnabled)
    }

    static func dismantleUIView(_ view: LaptopDeckView, coordinator: Coordinator) {
        view.releaseEverything()
    }
}
