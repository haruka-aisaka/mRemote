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
    private var composer = LaptopKeyboardComposer()
    private var isInputEnabled = false

    private var keyViews: [String: KeyCapView] = [:]
    private var keyFrames: [(frame: CGRect, key: LaptopKey)] = []
    private let pad = UIView()
    private let leftButton = UIView()
    private let rightButton = UIView()
    private var regions: [ObjectIdentifier: Region] = [:]
    private let haptics = UIImpactFeedbackGenerator(style: .light)

    private var repeatTimer: Timer?
    private var padTracking = PadTracking()

    /// One touch sequence on the pad. Tapping is told apart from moving by
    /// how far and how long, as on a laptop trackpad.
    private struct PadTracking {
        var touches: [ObjectIdentifier: CGPoint] = [:]
        var maximumTouches = 0
        var travel: CGFloat = 0
        var startTime: TimeInterval = 0
        var lastTime: TimeInterval = 0
    }

    private static let tapTravel: CGFloat = 8
    private static let tapDuration: TimeInterval = 0.3

    init(layout: LaptopKeyboardLayout, channel: LaptopDeckChannel) {
        self.layout = layout
        self.channel = channel
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.09, alpha: 1)
        isMultipleTouchEnabled = true
        accessibilityIdentifier = "laptop-deck"
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

    /// Closing the gate lets go of everything, exactly as the surface does:
    /// a key or a button held across a menu or a session switch would stay
    /// down on the host.
    func setInputEnabled(_ enabled: Bool) {
        guard enabled != isInputEnabled else { return }
        isInputEnabled = enabled
        if !enabled { releaseEverything() }
        alpha = enabled ? 1 : 0.6
    }

    func releaseEverything() {
        stopRepeat()
        channel.surface?.sendLaptopKeys(composer.releaseAll())
        for case .button(let button) in regions.values {
            channel.surface?.setLaptopButton(button, pressed: false)
        }
        regions = [:]
        padTracking = PadTracking()
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

        let keyboardHeight = (area.height * 0.56).rounded()
        let totalRowHeight = layout.rows.reduce(0) { $0 + $1.height }
        let gap: CGFloat = 4
        let unitHeight = (keyboardHeight - gap * CGFloat(layout.rows.count - 1)) / CGFloat(totalRowHeight)
        let unitWidth = area.width / CGFloat(LaptopKeyboardLayout.unitsPerRow)

        keyFrames = []
        var y = area.minY
        for row in layout.rows {
            let height = unitHeight * CGFloat(row.height)
            var x = area.minX
            for key in row.keys {
                let width = unitWidth * CGFloat(key.width)
                let hitFrame = CGRect(x: x, y: y - gap / 2, width: width, height: height + gap)
                keyFrames.append((hitFrame, key))
                keyViews[key.id]?.frame = CGRect(x: x, y: y, width: width, height: height)
                    .insetBy(dx: gap / 2, dy: 0)
                x += width
            }
            y += height + gap
        }

        let lower = CGRect(
            x: area.minX,
            y: area.minY + keyboardHeight + 10,
            width: area.width,
            height: area.height - keyboardHeight - 10
        )
        let padWidth = min(area.width, max(area.width * 0.72, 300))
        let buttonHeight = min(40, lower.height * 0.22)
        let padFrame = CGRect(
            x: lower.midX - padWidth / 2,
            y: lower.minY,
            width: padWidth,
            height: lower.height - buttonHeight - 6
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
        if leftButton.frame.insetBy(dx: -3, dy: -4).contains(point) { return .button(.left) }
        if rightButton.frame.insetBy(dx: -3, dy: -4).contains(point) { return .button(.right) }
        if pad.frame.insetBy(dx: -8, dy: -8).contains(point) { return .pad }
        return nil
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let region = region(at: touch.location(in: self)) else { continue }
            let id = ObjectIdentifier(touch)
            regions[id] = region
            switch region {
            case .key(let key):
                keyDown(key)
            case .button(let button):
                haptics.impactOccurred()
                channel.surface?.setLaptopButton(button, pressed: isInputEnabled)
                refreshButtons()
            case .pad:
                padBegan(touch, id: id)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let padTouches = touches.filter { regions[ObjectIdentifier($0)].map(Self.isPad) ?? false }
        if !padTouches.isEmpty { padMoved(padTouches) }
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
            guard let region = regions.removeValue(forKey: id) else { continue }
            switch region {
            case .key(let key):
                keyUp(key)
            case .button(let button):
                if !regions.values.contains(where: { Self.isButton($0, button) }) {
                    channel.surface?.setLaptopButton(button, pressed: false)
                }
                refreshButtons()
            case .pad:
                padEnded(id: id, cancelled: cancelled, at: touch.timestamp)
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

    private func keyUp(_ key: LaptopKey) {
        // A second finger on the same key is not a second press, so the key
        // only comes up when the last finger on it lifts.
        let stillHeld = regions.values.contains { region in
            if case .key(let other) = region { return other.kind == key.kind && !key.isModifier }
            return false
        }
        if !stillHeld {
            channel.surface?.sendLaptopKeys(composer.touchUp(key))
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

    // MARK: - Trackpad

    private func padBegan(_ touch: UITouch, id: ObjectIdentifier) {
        if padTracking.touches.isEmpty {
            padTracking = PadTracking(startTime: touch.timestamp, lastTime: touch.timestamp)
        }
        padTracking.touches[id] = touch.location(in: self)
        padTracking.maximumTouches = max(padTracking.maximumTouches, padTracking.touches.count)
    }

    private func padMoved(_ touches: Set<UITouch>) {
        var sum = CGPoint.zero
        var timestamp = padTracking.lastTime
        for touch in touches {
            let id = ObjectIdentifier(touch)
            guard let previous = padTracking.touches[id] else { continue }
            let location = touch.location(in: self)
            sum.x += location.x - previous.x
            sum.y += location.y - previous.y
            padTracking.touches[id] = location
            timestamp = max(timestamp, touch.timestamp)
        }
        let count = CGFloat(max(touches.count, 1))
        let delta = CGPoint(x: sum.x / count, y: sum.y / count)
        padTracking.travel += hypot(delta.x, delta.y)
        let elapsed = max(timestamp - padTracking.lastTime, 1.0 / 240)
        padTracking.lastTime = timestamp

        guard isInputEnabled else { return }
        if padTracking.touches.count >= 2 {
            // Two fingers scroll, as on every trackpad. The deltas are the
            // fingers' own, which `ScrollWheelAccumulator` already expects.
            channel.surface?.scrollRemote(dx: Double(delta.x), dy: Double(delta.y))
        } else {
            let speed = Double(hypot(delta.x, delta.y)) / elapsed
            channel.surface?.moveRemotePointer(dx: Double(delta.x), dy: Double(delta.y), speed: speed)
        }
    }

    private func padEnded(id: ObjectIdentifier, cancelled: Bool, at timestamp: TimeInterval) {
        padTracking.touches[id] = nil
        guard padTracking.touches.isEmpty else { return }
        let wasTap = !cancelled
            && padTracking.travel < Self.tapTravel
            && timestamp - padTracking.startTime < Self.tapDuration
        if wasTap, isInputEnabled {
            haptics.impactOccurred()
            // One finger is a left click, two a right click.
            channel.surface?.clickRemote(padTracking.maximumTouches >= 2 ? .right : .left)
        }
        padTracking = PadTracking()
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
        layer.cornerRadius = 5
        layer.cornerCurve = .continuous

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
        applyState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func accessibilityActivate() -> Bool {
        onActivate(key)
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let small = bounds.height < 30
        let size = min(bounds.height * (small ? 0.42 : 0.4), 17)
        label.font = .systemFont(ofSize: size, weight: key.label.count > 2 ? .regular : .medium)
        shiftedLabel.font = .systemFont(ofSize: size * 0.62)
        if shiftedLabel.isHidden {
            label.frame = bounds.insetBy(dx: 2, dy: 1)
        } else {
            let half = bounds.height / 2
            shiftedLabel.frame = CGRect(x: 2, y: 2, width: bounds.width - 4, height: half - 2)
            label.frame = CGRect(x: 2, y: half - 2, width: bounds.width - 4, height: half)
        }
        lockIndicator.frame = CGRect(x: bounds.width - 9, y: 4, width: 5, height: 5)
    }

    private func applyState() {
        switch state {
        case .idle:
            backgroundColor = key.isModifier ? UIColor(white: 0.17, alpha: 1) : UIColor(white: 0.22, alpha: 1)
        case .pressed:
            backgroundColor = UIColor(white: 0.45, alpha: 1)
        case .active, .locked:
            backgroundColor = .systemBlue
        }
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
        case "enter", "enter-upper": return "エンター"
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
    let channel: LaptopDeckChannel
    let isInputEnabled: Bool

    func makeUIView(context: Context) -> LaptopDeckView {
        let view = LaptopDeckView(layout: LaptopKeyboardLayout(layout), channel: channel)
        view.setInputEnabled(isInputEnabled)
        return view
    }

    func updateUIView(_ view: LaptopDeckView, context: Context) {
        view.setLayout(LaptopKeyboardLayout(layout))
        view.setInputEnabled(isInputEnabled)
    }

    static func dismantleUIView(_ view: LaptopDeckView, coordinator: Coordinator) {
        view.releaseEverything()
    }
}
