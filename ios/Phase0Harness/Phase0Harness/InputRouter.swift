import Foundation

@MainActor
final class KeyboardEventArbiter {
    private typealias SourcePolicy = (
        defaultSource: KeyboardEventSource,
        overrides: [UInt16: KeyboardEventSource],
        unsupported: Set<UInt16>
    )
    private enum SwitchDrainPhase {
        case awaitingDown
        case draining
    }
    private struct SourceSwitchDrain {
        let targetSource: KeyboardEventSource
        var phase: SwitchDrainPhase
    }

    private weak var sink: HarnessInputSink?
    private let journal: EventJournal
    private let repeatTimer: KeyRepeatTimer?

    private var defaultSource: KeyboardEventSource = .uiKit
    private var sourceOverrides: [UInt16: KeyboardEventSource] = [:]
    private var unsupportedUsages: Set<UInt16> = []
    private var pendingPolicy: SourcePolicy?
    private var pendingPolicyTouchedUsages: Set<UInt16> = []
    private var sourceSwitchDrains: [UInt16: SourceSwitchDrain] = [:]

    private var physicallyPressed: [KeyboardEventSource: Set<UInt16>] = [
        .uiKit: [], .gameController: [],
    ]
    private var remotelyPressed: [UInt16: KeyboardEventSource] = [:]
    private var quarantined: Set<UInt16> = []

    /// Held repeat-eligible usages in press order. A physical keyboard repeats
    /// the most recent one and resumes on whatever is still held under it.
    private var repeatCandidates: [UInt16] = []
    private var repeatTarget: UInt16?
    private var repeatGeneration: UInt64 = 0
    private(set) var repeatSettings: KeyRepeatSettings

    private(set) var generation: UInt64 = 1
    var isGateOpen = true {
        didSet {
            guard !isGateOpen else { return }
            cancelRepeat()
        }
    }

    init(
        sink: HarnessInputSink,
        journal: EventJournal,
        repeatTimer: KeyRepeatTimer?,
        repeatSettings: KeyRepeatSettings = .normal
    ) {
        self.sink = sink
        self.journal = journal
        self.repeatTimer = repeatTimer
        self.repeatSettings = repeatSettings
    }

    /// Takes effect on the next press. A key held across the change keeps its
    /// remote down and simply stops repeating.
    func setRepeatSettings(_ settings: KeyRepeatSettings) {
        guard settings != repeatSettings else { return }
        repeatSettings = settings
        cancelRepeat()
        journal.append(.state, "key repeat \(settings)")
    }

    func requestUIKitPolicy() {
        requestPolicy(defaultSource: .uiKit, overrides: [:], unsupported: [])
    }

    func requestGCForJapanesePolicy() {
        requestJapanesePolicy(eisu: .gameController, kana: .gameController)
    }

    func requestJapanesePolicy(
        eisu: KeyboardEventSource?,
        kana: KeyboardEventSource?
    ) {
        var overrides: [UInt16: KeyboardEventSource] = [:]
        var unsupported: Set<UInt16> = []
        for (usage, source) in [(HIDUsage.eisu, eisu), (HIDUsage.kana, kana)] {
            if let source {
                overrides[usage] = source
            } else {
                unsupported.insert(usage)
            }
        }
        requestPolicy(
            defaultSource: .uiKit,
            overrides: overrides,
            unsupported: unsupported
        )
    }

    func receive(_ event: HardwareKeyEvent) {
        updatePhysicalState(with: event)
        if pendingPolicy != nil {
            pendingPolicyTouchedUsages.insert(event.usage)
        }
        journal.appendKeyboardEvent(
            .observation,
            usage: event.usage,
            String(
                format: "%@ %@ 0x%02X %@",
                event.source.rawValue,
                HIDUsage.name(event.usage),
                event.usage,
                event.transition.rawValue
            )
        )

        // releaseAll quarantines a usage until every observation path has
        // reported it neutral. The tail may arrive first from either source,
        // including a source that is not selected for sending.
        var quarantineReason: String?
        if quarantined.contains(event.usage) {
            releaseQuarantineIfPhysicallyNeutral(event.usage)
            quarantineReason = "release quarantine"
        }
        if var drain = sourceSwitchDrains[event.usage] {
            if event.source == drain.targetSource {
                switch (drain.phase, event.transition) {
                case (.awaitingDown, .down):
                    drain.phase = .draining
                    sourceSwitchDrains[event.usage] = drain
                case (.draining, .up), (.draining, .cancel):
                    sourceSwitchDrains.removeValue(forKey: event.usage)
                case (.awaitingDown, .up), (.awaitingDown, .cancel),
                     (.draining, .down):
                    break
                }
            }
            quarantineReason = "source-switch quarantine target=\(drain.targetSource.rawValue)"
        }
        if let quarantineReason {
            journal.appendKeyboardEvent(
                .drop,
                usage: event.usage,
                "quarantined usage \(quarantineReason)"
            )
            applyPendingPolicyIfNeutral()
            return
        }

        // A closed gate covers observations from both APIs. Otherwise a down
        // first seen on the non-selected path while inactive could escape the
        // release quarantine after the gate reopens.
        guard isGateOpen else {
            if event.transition == .down { quarantined.insert(event.usage) }
            journal.appendKeyboardEvent(.drop, usage: event.usage, "keyboard gate closed")
            applyPendingPolicyIfNeutral()
            return
        }

        guard let selectedSource = source(for: event.usage) else {
            journal.appendKeyboardEvent(
                .drop,
                usage: event.usage,
                "usage disabled by keyboard policy"
            )
            applyPendingPolicyIfNeutral()
            return
        }
        guard event.source == selectedSource else {
            journal.appendKeyboardEvent(
                .drop,
                usage: event.usage,
                "source selected=\(selectedSource.rawValue) observed=\(event.source.rawValue)"
            )
            applyPendingPolicyIfNeutral()
            return
        }

        switch event.transition {
        case .down:
            guard remotelyPressed[event.usage] == nil else {
                journal.appendKeyboardEvent(.drop, usage: event.usage, "duplicate down")
                return
            }
            remotelyPressed[event.usage] = event.source
            sink?.enqueue(
                .hardwareKey(usage: event.usage, transition: .down),
                generation: generation
            )
            noteRemoteDown(event.usage)
        case .up, .cancel:
            guard remotelyPressed.removeValue(forKey: event.usage) != nil else {
                journal.appendKeyboardEvent(
                    .drop,
                    usage: event.usage,
                    "orphan \(event.transition.rawValue)"
                )
                applyPendingPolicyIfNeutral()
                return
            }
            sink?.enqueue(
                .hardwareKey(usage: event.usage, transition: .up),
                generation: generation
            )
            noteRemoteUp(event.usage)
        }
        applyPendingPolicyIfNeutral()
    }

    func releaseAll(reason: String) {
        let heldPhysical = physicallyPressed.values.reduce(into: Set<UInt16>()) {
            $0.formUnion($1)
        }
        if pendingPolicy != nil {
            pendingPolicyTouchedUsages.formUnion(heldPhysical)
            pendingPolicyTouchedUsages.formUnion(remotelyPressed.keys)
        }
        quarantined.formUnion(heldPhysical)

        cancelRepeat()
        repeatCandidates.removeAll(keepingCapacity: true)

        let pressed = remotelyPressed.keys.sorted()
        remotelyPressed.removeAll(keepingCapacity: true)
        for usage in pressed {
            sink?.enqueue(
                .hardwareKey(usage: usage, transition: .up),
                generation: generation
            )
        }
        generation &+= 1
        journal.append(
            .state,
            "releaseAll keyboard reason=\(reason) released=\(pressed.count) quarantine=\(quarantined.count) next-g=\(generation)"
        )
        applyPendingPolicyIfNeutral()
    }

    func keyboardDisconnected() {
        releaseAll(reason: "GCKeyboard disconnected")
        physicallyPressed[.gameController] = []
        sourceSwitchDrains = sourceSwitchDrains.filter {
            $0.value.targetSource != .gameController
        }
        releasePhysicallyNeutralQuarantines()
        applyPendingPolicyIfNeutral()
    }

    private func source(for usage: UInt16) -> KeyboardEventSource? {
        guard !unsupportedUsages.contains(usage) else { return nil }
        return sourceOverrides[usage] ?? defaultSource
    }

    private func requestPolicy(
        defaultSource: KeyboardEventSource,
        overrides: [UInt16: KeyboardEventSource],
        unsupported: Set<UInt16>
    ) {
        let policy: SourcePolicy = (
            defaultSource: defaultSource,
            overrides: overrides,
            unsupported: unsupported
        )
        let activeUsages = physicallyPressed.values.reduce(into: Set<UInt16>()) {
            $0.formUnion($1)
        }.union(remotelyPressed.keys)
            .union(quarantined)
            .union(sourceSwitchDrains.keys)
        pendingPolicyTouchedUsages.formUnion(activeUsages)
        guard isPhysicallyNeutral, remotelyPressed.isEmpty else {
            pendingPolicy = policy
            journal.append(
                .state,
                "keyboard source policy pending until neutral touched=\(pendingPolicyTouchedUsages.count)"
            )
            return
        }
        install(policy)
    }

    private func install(_ policy: SourcePolicy) {
        cancelRepeat()
        repeatCandidates.removeAll(keepingCapacity: true)
        let oldRoutes = pendingPolicyTouchedUsages.map { ($0, source(for: $0)) }
        defaultSource = policy.defaultSource
        sourceOverrides = policy.overrides
        unsupportedUsages = policy.unsupported
        var switchQuarantineCount = 0
        for (usage, oldSource) in oldRoutes {
            let targetSource = source(for: usage)
            guard oldSource != targetSource else { continue }
            if let targetSource {
                sourceSwitchDrains[usage] = SourceSwitchDrain(
                    targetSource: targetSource,
                    phase: .awaitingDown
                )
                switchQuarantineCount += 1
            } else {
                sourceSwitchDrains.removeValue(forKey: usage)
            }
        }
        pendingPolicyTouchedUsages.removeAll(keepingCapacity: true)
        pendingPolicy = nil
        generation &+= 1
        journal.append(
            .state,
            "keyboard policy default=\(defaultSource.rawValue) Eisu=\(routeDescription(HIDUsage.eisu)) Kana=\(routeDescription(HIDUsage.kana)) switch-quarantine=\(switchQuarantineCount) g=\(generation)"
        )
    }

    private func routeDescription(_ usage: UInt16) -> String {
        source(for: usage)?.rawValue ?? "unsupported"
    }

    private func updatePhysicalState(with event: HardwareKeyEvent) {
        var pressed = physicallyPressed[event.source] ?? []
        switch event.transition {
        case .down: pressed.insert(event.usage)
        case .up, .cancel: pressed.remove(event.usage)
        }
        physicallyPressed[event.source] = pressed
    }

    private var isPhysicallyNeutral: Bool {
        physicallyPressed.values.allSatisfy(\.isEmpty)
    }

    private func releaseQuarantineIfPhysicallyNeutral(_ usage: UInt16) {
        guard physicallyPressed.values.allSatisfy({ !$0.contains(usage) }) else { return }
        quarantined.remove(usage)
    }

    private func releasePhysicallyNeutralQuarantines() {
        for usage in Array(quarantined) {
            releaseQuarantineIfPhysicallyNeutral(usage)
        }
    }

    private func applyPendingPolicyIfNeutral() {
        guard isPhysicallyNeutral, remotelyPressed.isEmpty, let pendingPolicy else { return }
        install(pendingPolicy)
    }

    private func noteRemoteDown(_ usage: UInt16) {
        guard KeyRepeatEligibility.repeats(usage) else { return }
        repeatCandidates.removeAll { $0 == usage }
        repeatCandidates.append(usage)
        restartRepeat()
    }

    private func noteRemoteUp(_ usage: UInt16) {
        guard repeatCandidates.contains(usage) else { return }
        let wasTarget = repeatTarget == usage
        repeatCandidates.removeAll { $0 == usage }
        guard wasTarget else { return }
        restartRepeat()
    }

    /// Arms the initial delay for the newest held candidate. Repeat carries no
    /// journal line of its own: a per-press line would flood the trace and,
    /// for a printable usage, would have to be redacted anyway. Every repeat
    /// still lands in the send counter through the sink.
    private func restartRepeat() {
        repeatTimer?.cancel()
        repeatTarget = nil
        guard repeatSettings.isEnabled, isGateOpen, let repeatTimer,
              let usage = repeatCandidates.last else { return }
        repeatTarget = usage
        repeatGeneration = generation
        repeatTimer.schedule(after: repeatSettings.initialDelay) { [weak self] in
            self?.fireRepeat()
        }
    }

    private func fireRepeat() {
        guard let usage = repeatTarget else { return }
        // Re-checked at every fire rather than trusted from arming time: the
        // gate, the quarantine and the remote press can all change underneath
        // a pending timer, and a repeat must never outlive the down it extends.
        guard repeatSettings.isEnabled,
              isGateOpen,
              generation == repeatGeneration,
              remotelyPressed[usage] != nil,
              !quarantined.contains(usage),
              sourceSwitchDrains[usage] == nil else {
            cancelRepeat()
            return
        }
        // Down only. The single up stays bound to the physical release, so the
        // remote never sees an extra transition to unwind.
        sink?.enqueue(.hardwareKey(usage: usage, transition: .down), generation: generation)
        repeatTimer?.schedule(after: repeatSettings.interval) { [weak self] in
            self?.fireRepeat()
        }
    }

    private func cancelRepeat() {
        repeatTimer?.cancel()
        repeatTarget = nil
    }
}

@MainActor
final class PointerEventArbiter {
    private enum SwitchDrainPhase {
        case awaitingDown
        case draining
    }
    private struct SourceSwitchDrain {
        let targetSource: PointerEventSource
        var phase: SwitchDrainPhase
    }

    private weak var sink: HarnessInputSink?
    private let journal: EventJournal
    private var selectedSource: PointerEventSource = .uiKit
    private var pendingSource: PointerEventSource?
    private var pendingSourceTouchedButtons: Set<PointerButton> = []
    private var sourceSwitchDrains: [PointerButton: SourceSwitchDrain] = [:]
    private var physicallyPressed: [PointerEventSource: Set<PointerButton>] = [
        .uiKit: [], .gameController: [],
    ]
    private var remotelyPressed: Set<PointerButton> = []
    private var quarantined: Set<PointerButton> = []
    private var scrollAccumulator = ScrollWheelAccumulator()
    private var generation: UInt64 = 1
    var isGateOpen = true

    init(sink: HarnessInputSink, journal: EventJournal) {
        self.sink = sink
        self.journal = journal
    }

    func requestSource(_ source: PointerEventSource) {
        let activeButtons = physicallyPressed.values.reduce(into: Set<PointerButton>()) {
            $0.formUnion($1)
        }.union(remotelyPressed)
            .union(quarantined)
            .union(sourceSwitchDrains.keys)
        pendingSourceTouchedButtons.formUnion(activeButtons)
        guard physicallyPressed.values.allSatisfy(\.isEmpty), remotelyPressed.isEmpty else {
            pendingSource = source
            journal.append(
                .state,
                "pointer source \(source.rawValue) pending until buttons neutral touched=\(pendingSourceTouchedButtons.count)"
            )
            return
        }
        install(source)
    }

    func setScrollDirection(_ direction: ScrollDirection) {
        guard scrollAccumulator.setDirection(direction) else {
            journal.append(.state, "scroll direction already \(direction.rawValue)")
            return
        }
        generation &+= 1
        journal.append(
            .state,
            "scroll direction=\(direction.rawValue) residuals reset g=\(generation)"
        )
    }

    func receive(_ event: PointerInputEvent) {
        updatePhysicalState(with: event)
        if pendingSource != nil,
           case let .button(button, _, _) = event.payload {
            pendingSourceTouchedButtons.insert(button)
        }
        journal.append(.observation, "\(event.source.rawValue) \(event.payload.diagnosticDescription)")

        var quarantineReason: String?
        if case let .button(button, transition, _) = event.payload {
            if quarantined.contains(button) {
                releaseQuarantineIfPhysicallyNeutral(button)
                quarantineReason = "release quarantine"
            }
            if var drain = sourceSwitchDrains[button] {
                if event.source == drain.targetSource {
                    switch (drain.phase, transition) {
                    case (.awaitingDown, .down):
                        drain.phase = .draining
                        sourceSwitchDrains[button] = drain
                    case (.draining, .up), (.draining, .cancel):
                        sourceSwitchDrains.removeValue(forKey: button)
                    case (.awaitingDown, .up), (.awaitingDown, .cancel),
                         (.draining, .down):
                        break
                    }
                }
                quarantineReason = "source-switch quarantine target=\(drain.targetSource.rawValue)"
            }
        } else if sourceSwitchDrains.values.contains(where: {
            $0.targetSource == event.source
        }) {
            quarantineReason = "source-switch gesture drain"
        }
        if let quarantineReason {
            journal.append(.drop, "quarantined pointer \(quarantineReason)")
            applyPendingSourceIfNeutral()
            return
        }

        guard isGateOpen else {
            if case let .button(button, .down, _) = event.payload {
                quarantined.insert(button)
            }
            journal.append(.drop, "pointer gate closed")
            applyPendingSourceIfNeutral()
            return
        }

        guard event.source == selectedSource else {
            journal.append(.drop, "pointer source selected=\(selectedSource.rawValue)")
            applyPendingSourceIfNeutral()
            return
        }

        switch event.payload {
        case let .button(button, transition, remote):
            switch transition {
            case .down:
                guard remotelyPressed.insert(button).inserted else {
                    journal.append(.drop, "duplicate pointer \(button.rawValue) down")
                    return
                }
                sink?.enqueue(
                    .pointer(.button(button, .down, remote: remote)),
                    generation: generation
                )
            case .up, .cancel:
                guard remotelyPressed.remove(button) != nil else {
                    journal.append(.drop, "orphan pointer \(button.rawValue) \(transition.rawValue)")
                    applyPendingSourceIfNeutral()
                    return
                }
                sink?.enqueue(
                    .pointer(.button(button, .up, remote: remote)),
                    generation: generation
                )
            }
        case .move:
            sink?.enqueue(.pointer(event.payload), generation: generation)
        case let .scroll(horizontal, vertical):
            let delta = scrollAccumulator.consume(
                horizontal: horizontal,
                vertical: vertical
            )
            guard !delta.isZero else { break }
            sink?.enqueue(
                .pointer(.scroll(
                    horizontal: Double(delta.horizontal),
                    vertical: Double(delta.vertical)
                )),
                generation: generation
            )
        }
        applyPendingSourceIfNeutral()
    }

    func releaseAll(reason: String) {
        scrollAccumulator.reset()
        let heldPhysical = physicallyPressed.values.reduce(into: Set<PointerButton>()) {
            $0.formUnion($1)
        }
        if pendingSource != nil {
            pendingSourceTouchedButtons.formUnion(heldPhysical)
            pendingSourceTouchedButtons.formUnion(remotelyPressed)
        }
        quarantined.formUnion(heldPhysical)
        let pressed = remotelyPressed.sorted { $0.rawValue < $1.rawValue }
        remotelyPressed.removeAll(keepingCapacity: true)
        for button in pressed {
            sink?.enqueue(
                .pointer(.button(button, .up, remote: nil)),
                generation: generation
            )
        }
        generation &+= 1
        journal.append(
            .state,
            "releaseAll pointer reason=\(reason) released=\(pressed.count) quarantine=\(quarantined.count) scroll-residuals=reset next-g=\(generation)"
        )
        applyPendingSourceIfNeutral()
    }

    func mouseDisconnected() {
        releaseAll(reason: "GCMouse disconnected")
        physicallyPressed[.gameController] = []
        sourceSwitchDrains = sourceSwitchDrains.filter {
            $0.value.targetSource != .gameController
        }
        releasePhysicallyNeutralQuarantines()
        applyPendingSourceIfNeutral()
    }

    private func updatePhysicalState(with event: PointerInputEvent) {
        guard case let .button(button, transition, _) = event.payload else { return }
        var pressed = physicallyPressed[event.source] ?? []
        switch transition {
        case .down: pressed.insert(button)
        case .up, .cancel: pressed.remove(button)
        }
        physicallyPressed[event.source] = pressed
    }

    private func install(_ source: PointerEventSource) {
        let previousSource = selectedSource
        selectedSource = source
        var switchQuarantineCount = 0
        if previousSource != source {
            scrollAccumulator.reset()
            for button in pendingSourceTouchedButtons {
                sourceSwitchDrains[button] = SourceSwitchDrain(
                    targetSource: source,
                    phase: .awaitingDown
                )
                switchQuarantineCount += 1
            }
        }
        pendingSourceTouchedButtons.removeAll(keepingCapacity: true)
        pendingSource = nil
        generation &+= 1
        journal.append(
            .state,
            "pointer policy=\(source.rawValue) switch-quarantine=\(switchQuarantineCount) scroll-residuals=\(previousSource == source ? "preserved" : "reset") g=\(generation)"
        )
    }

    private func releaseQuarantineIfPhysicallyNeutral(_ button: PointerButton) {
        guard physicallyPressed.values.allSatisfy({ !$0.contains(button) }) else { return }
        quarantined.remove(button)
    }

    private func releasePhysicallyNeutralQuarantines() {
        for button in Array(quarantined) {
            releaseQuarantineIfPhysicallyNeutral(button)
        }
    }

    private func applyPendingSourceIfNeutral() {
        guard physicallyPressed.values.allSatisfy(\.isEmpty), remotelyPressed.isEmpty,
              let pendingSource else { return }
        install(pendingSource)
    }
}

@MainActor
final class HarnessInputRouter {
    let keyboard: KeyboardEventArbiter
    let pointer: PointerEventArbiter
    private let journal: EventJournal
    private weak var sink: HarnessInputSink?
    private(set) var textGeneration: UInt64 = 1
    private(set) var isHardwareGateOpen = true

    init(
        sink: HarnessInputSink,
        journal: EventJournal,
        hardwareGateInitiallyOpen: Bool = true,
        keyRepeatTimer: KeyRepeatTimer? = RunLoopKeyRepeatTimer(),
        keyRepeatSettings: KeyRepeatSettings = .normal
    ) {
        self.sink = sink
        self.journal = journal
        keyboard = KeyboardEventArbiter(
            sink: sink,
            journal: journal,
            repeatTimer: keyRepeatTimer,
            repeatSettings: keyRepeatSettings
        )
        pointer = PointerEventArbiter(sink: sink, journal: journal)
        isHardwareGateOpen = hardwareGateInitiallyOpen
        keyboard.isGateOpen = hardwareGateInitiallyOpen
        pointer.isGateOpen = hardwareGateInitiallyOpen
    }

    func setHardwareGate(open: Bool, reason: String) {
        guard open != isHardwareGateOpen else {
            journal.append(
                .state,
                "hardware input gate already \(open ? "open" : "closed") reason=\(reason)"
            )
            return
        }
        if !open {
            keyboard.releaseAll(reason: reason)
            pointer.releaseAll(reason: reason)
        }
        isHardwareGateOpen = open
        keyboard.isGateOpen = open
        pointer.isGateOpen = open
        journal.append(.state, "hardware input gate=\(open ? "open" : "closed") reason=\(reason)")
    }

    func beginTextGeneration(reason: String) {
        textGeneration &+= 1
        journal.append(.state, "text generation=\(textGeneration) reason=\(reason)")
    }

    func sendHostASCII(_ text: String, generation: UInt64) {
        guard generation == textGeneration else {
            journal.append(.drop, "stale host text generation=\(generation)")
            return
        }
        sink?.enqueue(.hostASCII(text), generation: generation)
    }

    func sendCommittedText(_ text: String, generation: UInt64) {
        guard generation == textGeneration else {
            journal.append(.drop, "stale local text generation=\(generation)")
            return
        }
        sink?.enqueue(.committedText(text), generation: generation)
    }

    func releaseAll(reason: String) {
        keyboard.releaseAll(reason: reason)
        pointer.releaseAll(reason: reason)
        beginTextGeneration(reason: reason)
    }
}
