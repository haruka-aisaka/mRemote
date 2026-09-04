import UIKit

@MainActor
private final class HarnessInteractionGuardView: UIView {
    weak var remoteSurface: UIView?
    var onLocalTouchHit: (() -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        let isLocalPointerEvent: Bool
        switch event?.type {
        case .touches, .scroll, .hover:
            isLocalPointerEvent = true
        default:
            isLocalPointerEvent = false
        }
        guard isLocalPointerEvent, let hit, let remoteSurface else { return hit }
        if hit !== remoteSurface, !hit.isDescendant(of: remoteSurface) {
            // This runs before local touch/scroll/hover dispatch so global
            // GameController callbacks normally see a closed capture gate.
            onLocalTouchHit?()
        }
        return hit
    }
}

@MainActor
final class HarnessViewController: UIViewController {
    private let journal = EventJournal()
    private lazy var recordingSink = RecordingInputSink(journal: journal)
    private lazy var inputSink = SwitchingInputSink(recordingSink: recordingSink)
    private lazy var router = HarnessInputRouter(
        sink: inputSink,
        journal: journal,
        hardwareGateInitiallyOpen: false
    )
    private lazy var surface = RemoteSurfaceView(router: router)
    private lazy var keyboardMonitor = GCKeyboardMonitor(arbiter: router.keyboard)
    private lazy var mouseMonitor = GCMouseMonitor(arbiter: router.pointer)

    private let modeControl = UISegmentedControl(items: ["Hardware", "Host IME", "Local IME"])
    private let eisuRouteControl = UISegmentedControl(items: ["UIKit", "GC", "Off"])
    private let kanaRouteControl = UISegmentedControl(items: ["UIKit", "GC", "Off"])
    private let pointerRouteControl = UISegmentedControl(items: ["UIKit", "GCMouse"])
    private let scrollDirectionControl = UISegmentedControl(items: ["Normal", "Reversed"])
    private let fixtureControl = UISegmentedControl(
        items: DesktopFixturePreset.allCases.map(\.title)
    )
    private let hostnameField = UITextField()
    private let portField = UITextField()
    private let domainField = UITextField()
    private let usernameField = UITextField()
    private let passwordField = UITextField()
    private let connectionStatusLabel = UILabel()
    private let channelStatusLabel = UILabel()
    private lazy var connectButton = makeButton("Connect", action: #selector(connectSession))
    private lazy var disconnectButton = makeButton(
        "Disconnect",
        action: #selector(disconnectSession)
    )
    private lazy var clipboardProbeButton = makeButton(
        "Cliprdr probe",
        action: #selector(startClipboardProbe)
    )
    private lazy var displayResizeButton = makeButton(
        "Send DISP size",
        action: #selector(requestDisplayResize)
    )
    private let proxy = IMEInputProxy()
    private let markedLabel = UILabel()
    private let frameLabel = UILabel()
    private let deviceStatusLabel = UILabel()
    private let counterLabel = UILabel()
    private let environmentNotes = UITextView()
    private let logView = UITextView()
    private var observers: [NSObjectProtocol] = []
    private var keyboardStatus = "GCKeyboard: checking"
    private var mouseStatus = "GCMouse: checking"
    private var isLifecycleSuspended = false
    private var isShutdown = false
    private var didAttemptInitialCapture = false
#if PHASE0_NATIVE
    private var nativeSession: NativeRDPSession?
    private var nativeGeneration: UInt64 = 0
    private var nativeSurfaceGeneration: UInt64 = 0
    private var nativeFrameID: UInt64 = 0
    private var channelExerciseCounters: Phase0ChannelExerciseCounters?
    private var certificateAlert: UIAlertController?
    private let certificateReviewGate = CertificateReviewResponseGate()
#endif

    override func loadView() {
        view = HarnessInteractionGuardView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Phase 0 Surface/Input Harness"
        view.backgroundColor = .systemBackground
        configureCallbacks()
        configureUI()
        configureLocalInteractionGuard()
        observeLifecycle()
        keyboardMonitor.start()
        mouseMonitor.start()
        surface.loadInitialTestFrame()
        applyMode(index: 0, requestFocus: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didAttemptInitialCapture, modeControl.selectedSegmentIndex == 0 else { return }
        didAttemptInitialCapture = true
        _ = surface.becomeFirstResponder()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func shutdown(reason: String) {
        guard !isShutdown else { return }
        isShutdown = true
        passwordField.text = nil
        proxy.cancelComposition()
        _ = proxy.resignFirstResponder()
        router.beginTextGeneration(reason: reason)
        router.setHardwareGate(open: false, reason: reason)
        keyboardMonitor.stop()
        mouseMonitor.stop()
#if PHASE0_NATIVE
        resolveNativeCertificateReview(accept: false)
        nativeSession?.requestStop()
#endif
        inputSink.useRecordingSink()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        journal.append(.state, "harness shutdown reason=\(reason)")
    }

    private func configureCallbacks() {
        journal.onChange = { [weak self] in self?.refreshJournal() }
        surface.onDiagnostic = { [weak self] message in self?.journal.append(.state, message) }
        surface.onFrameStatus = { [weak self] message in self?.frameLabel.text = message }

        proxy.onMarkedText = { [weak self] text in
            self?.markedLabel.text = "Marked (local only): \(text?.debugDescription ?? "none")"
        }
        proxy.onHostASCII = { [weak self] text, generation in
            self?.router.sendHostASCII(text, generation: generation)
        }
        proxy.onCommittedText = { [weak self] text, generation in
            self?.router.sendCommittedText(text, generation: generation)
        }
        proxy.onWillResignInput = { [weak self] in
            self?.router.beginTextGeneration(reason: "IME proxy resigned")
        }
        proxy.onDiagnostic = { [weak self] message in self?.journal.append(.state, message) }

        keyboardMonitor.onStatus = { [weak self] status in
            self?.keyboardStatus = status
            self?.refreshDeviceStatus()
            self?.journal.append(.state, status)
        }
        mouseMonitor.onStatus = { [weak self] status in
            self?.mouseStatus = status
            self?.refreshDeviceStatus()
            self?.journal.append(.state, status)
        }
        mouseMonitor.onRelativeMove = { [weak self] horizontal, vertical in
            self?.surface.receiveGCMouseDelta(horizontal: horizontal, vertical: vertical)
        }
        mouseMonitor.remoteLocationProvider = { [weak self] in
            self?.surface.currentGCMouseRemotePoint()
        }
    }

    private func configureUI() {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -28),
        ])

        let titleLabel = makeLabel(
            "Phase 0 — Metal / keyboard / pointer / UITextInput",
            style: .headline
        )
        titleLabel.numberOfLines = 0
        stack.addArrangedSubview(titleLabel)

        deviceStatusLabel.font = .preferredFont(forTextStyle: .caption1)
        deviceStatusLabel.numberOfLines = 0
        stack.addArrangedSubview(deviceStatusLabel)
        refreshDeviceStatus()

        configureConnectionUI(in: stack)

        stack.addArrangedSubview(makeLabel("Input responder", style: .subheadline))
        modeControl.selectedSegmentIndex = 0
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        stack.addArrangedSubview(modeControl)

        stack.addArrangedSubview(makeLabel("Keyboard send policy — Eisu / HID 0x91", style: .subheadline))
        eisuRouteControl.selectedSegmentIndex = 0
        eisuRouteControl.addTarget(self, action: #selector(keyboardRouteChanged), for: .valueChanged)
        stack.addArrangedSubview(eisuRouteControl)

        stack.addArrangedSubview(makeLabel("Keyboard send policy — Kana / HID 0x90", style: .subheadline))
        kanaRouteControl.selectedSegmentIndex = 0
        kanaRouteControl.addTarget(self, action: #selector(keyboardRouteChanged), for: .valueChanged)
        stack.addArrangedSubview(kanaRouteControl)

        stack.addArrangedSubview(makeLabel("Pointer send policy (one API path)", style: .subheadline))
        pointerRouteControl.selectedSegmentIndex = 0
        pointerRouteControl.addTarget(self, action: #selector(pointerRouteChanged), for: .valueChanged)
        stack.addArrangedSubview(pointerRouteControl)

        stack.addArrangedSubview(makeLabel("Remote scroll direction", style: .subheadline))
        scrollDirectionControl.selectedSegmentIndex = 0
        scrollDirectionControl.addTarget(
            self,
            action: #selector(scrollDirectionChanged),
            for: .valueChanged
        )
        stack.addArrangedSubview(scrollDirectionControl)

        proxy.translatesAutoresizingMaskIntoConstraints = false
        proxy.heightAnchor.constraint(equalToConstant: 82).isActive = true
        proxy.isHidden = true
        stack.addArrangedSubview(proxy)

        markedLabel.font = .preferredFont(forTextStyle: .caption1)
        markedLabel.numberOfLines = 2
        markedLabel.text = "Marked (local only): none"
        markedLabel.isHidden = true
        stack.addArrangedSubview(markedLabel)

        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.heightAnchor.constraint(equalToConstant: 300).isActive = true

        stack.addArrangedSubview(makeLabel("Desktop fixture / upload baseline", style: .subheadline))
        fixtureControl.selectedSegmentIndex = DesktopFixturePreset.hd720.rawValue
        fixtureControl.addTarget(self, action: #selector(fixtureChanged), for: .valueChanged)
        stack.addArrangedSubview(fixtureControl)
        stack.addArrangedSubview(surface)

        frameLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        frameLabel.textColor = .secondaryLabel
        frameLabel.numberOfLines = 0
        stack.addArrangedSubview(frameLabel)

        let primaryButtons = UIStackView(arrangedSubviews: [
            makeButton("Focus / keyboard", action: #selector(focusInput)),
            makeButton("Dirty update", action: #selector(dirtyUpdate)),
            makeButton("Release all", action: #selector(releaseAll)),
        ])
        primaryButtons.axis = .horizontal
        primaryButtons.distribution = .fillEqually
        primaryButtons.spacing = 8
        stack.addArrangedSubview(primaryButtons)

        stack.addArrangedSubview(makeLabel("Baseline environment notes (included in Export)", style: .subheadline))
        environmentNotes.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        environmentNotes.backgroundColor = .secondarySystemBackground
        environmentNotes.layer.cornerRadius = 8
        environmentNotes.text = defaultEnvironmentNotes()
        environmentNotes.heightAnchor.constraint(equalToConstant: 135).isActive = true
        stack.addArrangedSubview(environmentNotes)

        counterLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(counterLabel)

        logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logView.backgroundColor = UIColor.secondarySystemBackground
        logView.textColor = .label
        logView.isEditable = false
        logView.isSelectable = true
        logView.layer.cornerRadius = 8
        logView.accessibilityLabel = "Input event trace"
        logView.heightAnchor.constraint(equalToConstant: 260).isActive = true
        stack.addArrangedSubview(logView)

        let logButtons = UIStackView(arrangedSubviews: [
            makeButton("Clear trace", action: #selector(clearTrace)),
            makeButton("Export", action: #selector(exportTrace)),
        ])
        logButtons.axis = .horizontal
        logButtons.distribution = .fillEqually
        logButtons.spacing = 8
        stack.addArrangedSubview(logButtons)
        refreshJournal()
    }

    private func configureConnectionUI(in stack: UIStackView) {
        stack.addArrangedSubview(makeLabel("Optional native RDP connection", style: .headline))

        configureConnectionField(
            hostnameField,
            placeholder: "Host name or IP address",
            identifier: "rdp.hostname"
        )
        hostnameField.textContentType = .URL
        hostnameField.keyboardType = .URL

        configureConnectionField(
            portField,
            placeholder: "Port",
            identifier: "rdp.port"
        )
        portField.text = "3389"
        portField.keyboardType = .numberPad

        configureConnectionField(
            domainField,
            placeholder: "Domain (optional)",
            identifier: "rdp.domain"
        )
        configureConnectionField(
            usernameField,
            placeholder: "User name",
            identifier: "rdp.username"
        )
        usernameField.textContentType = .username

        configureConnectionField(
            passwordField,
            placeholder: "Password (never journaled/exported)",
            identifier: "rdp.password"
        )
        passwordField.isSecureTextEntry = true
        passwordField.textContentType = .password

        let endpointRow = UIStackView(arrangedSubviews: [hostnameField, portField])
        endpointRow.axis = .horizontal
        endpointRow.spacing = 8
        hostnameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        portField.widthAnchor.constraint(equalToConstant: 105).isActive = true
        stack.addArrangedSubview(endpointRow)

        let identityRow = UIStackView(arrangedSubviews: [domainField, usernameField])
        identityRow.axis = .horizontal
        identityRow.distribution = .fillEqually
        identityRow.spacing = 8
        stack.addArrangedSubview(identityRow)
        stack.addArrangedSubview(passwordField)

        let buttons = UIStackView(arrangedSubviews: [connectButton, disconnectButton])
        buttons.axis = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 8
        disconnectButton.isEnabled = false
        stack.addArrangedSubview(buttons)

        connectionStatusLabel.font = .preferredFont(forTextStyle: .caption1)
        connectionStatusLabel.textColor = .secondaryLabel
        connectionStatusLabel.numberOfLines = 0
#if PHASE0_NATIVE
        connectionStatusLabel.text = "Native bridge ready; enter a disposable Phase 0 target."
#else
        connectionStatusLabel.text = "Fixture build: native bridge is not linked. Connect validates and redacts the form only."
#endif
        stack.addArrangedSubview(connectionStatusLabel)

        let channelButtons = UIStackView(arrangedSubviews: [
            clipboardProbeButton,
            displayResizeButton,
        ])
        channelButtons.axis = .horizontal
        channelButtons.distribution = .fillEqually
        channelButtons.spacing = 8
        clipboardProbeButton.isEnabled = false
        displayResizeButton.isEnabled = false
        stack.addArrangedSubview(channelButtons)

        channelStatusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        channelStatusLabel.textColor = .secondaryLabel
        channelStatusLabel.numberOfLines = 0
        channelStatusLabel.text = "Channel exercise: connect to a disposable target (results NOT RUN)."
        stack.addArrangedSubview(channelStatusLabel)
    }

    private func configureConnectionField(
        _ field: UITextField,
        placeholder: String,
        identifier: String
    ) {
        field.borderStyle = .roundedRect
        field.placeholder = placeholder
        field.accessibilityIdentifier = identifier
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
    }

    private func configureLocalInteractionGuard() {
        guard let guardView = view as? HarnessInteractionGuardView else { return }
        guardView.remoteSurface = surface
        guardView.onLocalTouchHit = { [weak self] in
            guard let self, self.modeControl.selectedSegmentIndex == 0 else { return }
            _ = self.surface.resignFirstResponder()
            self.router.setHardwareGate(open: false, reason: "local harness UI interaction")
        }
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suspendInput(reason: "application will resign active")
            }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suspendInput(reason: "application entered background")
            }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resumeInputAfterLifecycleTransition()
            }
        })
    }

    private func suspendInput(reason: String) {
#if PHASE0_NATIVE
        // willResignActive and didEnterBackground can both arrive. Reject on
        // every transition before the idempotence guard so no native callback
        // can remain blocked behind an alert while the app is inactive.
        resolveNativeCertificateReview(accept: false)
#endif
        guard !isLifecycleSuspended else { return }
        isLifecycleSuspended = true
        passwordField.text = nil
        proxy.cancelComposition()
        _ = proxy.resignFirstResponder()
        router.beginTextGeneration(reason: reason)
        router.setHardwareGate(open: false, reason: reason)
    }

    private func resumeInputAfterLifecycleTransition() {
        isLifecycleSuspended = false
        switch modeControl.selectedSegmentIndex {
        case 1:
            surface.allowsHardwareInput = false
            proxy.prepare(mode: .hostIME, generation: router.textGeneration)
            _ = proxy.becomeFirstResponder()
            proxy.reloadInputViews()
        case 2:
            surface.allowsHardwareInput = false
            proxy.prepare(mode: .localIME, generation: router.textGeneration)
            _ = proxy.becomeFirstResponder()
            proxy.reloadInputViews()
        default:
            surface.allowsHardwareInput = true
            if UIApplication.shared.applicationState == .active {
                _ = surface.becomeFirstResponder()
            }
        }
    }

    @objc private func modeChanged() {
        applyMode(index: modeControl.selectedSegmentIndex)
    }

    private func applyMode(index: Int, requestFocus: Bool = true) {
        proxy.cancelComposition()

        switch index {
        case 1:
            surface.allowsHardwareInput = false
            _ = surface.resignFirstResponder()
            router.setHardwareGate(open: false, reason: "host IME proxy active")
            router.beginTextGeneration(reason: "host IME selected")
            proxy.prepare(mode: .hostIME, generation: router.textGeneration)
            proxy.isHidden = false
            markedLabel.isHidden = false
            _ = proxy.becomeFirstResponder()
        case 2:
            surface.allowsHardwareInput = false
            _ = surface.resignFirstResponder()
            router.setHardwareGate(open: false, reason: "local IME proxy active")
            router.beginTextGeneration(reason: "local IME selected")
            proxy.prepare(mode: .localIME, generation: router.textGeneration)
            proxy.isHidden = false
            markedLabel.isHidden = false
            _ = proxy.becomeFirstResponder()
        default:
            surface.allowsHardwareInput = true
            _ = proxy.resignFirstResponder()
            router.releaseAll(reason: "hardware input mode selected")
            proxy.isHidden = true
            markedLabel.isHidden = true
            if requestFocus, !isLifecycleSuspended,
               UIApplication.shared.applicationState == .active {
                _ = surface.becomeFirstResponder()
            } else {
                router.setHardwareGate(open: false, reason: "hardware mode waiting for active app")
            }
        }
    }

    @objc private func keyboardRouteChanged() {
        router.keyboard.requestJapanesePolicy(
            eisu: keyboardSource(for: eisuRouteControl.selectedSegmentIndex),
            kana: keyboardSource(for: kanaRouteControl.selectedSegmentIndex)
        )
    }

    private func keyboardSource(for selectedIndex: Int) -> KeyboardEventSource? {
        switch selectedIndex {
        case 0: return .uiKit
        case 1: return .gameController
        default: return nil
        }
    }

    @objc private func pointerRouteChanged() {
        router.pointer.requestSource(
            pointerRouteControl.selectedSegmentIndex == 0 ? .uiKit : .gameController
        )
    }

    @objc private func scrollDirectionChanged() {
        router.pointer.setScrollDirection(
            scrollDirectionControl.selectedSegmentIndex == 0 ? .normal : .reversed
        )
    }

    @objc private func focusInput() {
        if modeControl.selectedSegmentIndex == 0 {
            surface.allowsHardwareInput = true
            _ = surface.becomeFirstResponder()
        } else {
            let mode: IMEInputProxy.Mode = modeControl.selectedSegmentIndex == 1
                ? .hostIME
                : .localIME
            proxy.prepare(mode: mode, generation: router.textGeneration)
            _ = proxy.becomeFirstResponder()
            proxy.reloadInputViews()
        }
    }

    @objc private func dirtyUpdate() {
        surface.applyMovingDirtyTestUpdate()
    }

    @objc private func fixtureChanged() {
        guard let preset = DesktopFixturePreset(
            rawValue: fixtureControl.selectedSegmentIndex
        ) else { return }
        surface.loadTestFrame(preset)
    }

    @objc private func releaseAll() {
        router.releaseAll(reason: "manual harness action")
    }

    @objc private func connectSession() {
        // Clear UIKit's field on every attempt, including validation failure.
        // The validated secret owns the only app-model copy passed onward.
        defer { passwordField.text = nil }
        let form = RDPConnectionForm(
            hostname: hostnameField.text ?? "",
            port: portField.text ?? "",
            domain: domainField.text ?? "",
            username: usernameField.text ?? "",
            password: passwordField.text ?? ""
        )

        do {
            let connection = try form.validated()
#if PHASE0_NATIVE
            startNativeSession(connection)
#else
            connection.password.clear()
            connectionStatusLabel.text = "Validated \(connection.descriptor); native bridge unavailable in this build."
            journal.append(.warning, "native connection unavailable \(connection.descriptor)")
#endif
        } catch {
            connectionStatusLabel.text = "Connection form error: \(error)"
            journal.append(.warning, "connection form rejected: \(error)")
        }
    }

    @objc private func disconnectSession() {
        router.releaseAll(reason: "session disconnect requested")
        inputSink.useRecordingSink()
#if PHASE0_NATIVE
        resolveNativeCertificateReview(accept: false)
        nativeSession?.requestStop()
        connectionStatusLabel.text = "Stopping native session…"
#else
        connectionStatusLabel.text = "No native session in the fixture build."
#endif
    }

    @objc private func startClipboardProbe() {
#if PHASE0_NATIVE
        guard let nativeSession else {
            journal.append(.drop, "cliprdr probe ignored without native session")
            return
        }
        nativeSession.startClipboardProbe()
#else
        journal.append(.drop, "cliprdr probe unavailable in fixture build")
#endif
    }

    @objc private func requestDisplayResize() {
#if PHASE0_NATIVE
        guard let nativeSession else {
            journal.append(.drop, "disp resize ignored without native session")
            return
        }
        let dimensions = DesktopFixturePreset(
            rawValue: fixtureControl.selectedSegmentIndex
        )?.dimensions ?? DesktopFixturePreset.fullHD1080.dimensions
        guard let width = UInt32(exactly: dimensions.width),
              let height = UInt32(exactly: dimensions.height) else {
            journal.append(.drop, "disp resize rejected invalid fixture dimensions")
            return
        }
        nativeSession.requestDisplayResize(width: width, height: height)
#else
        journal.append(.drop, "disp resize unavailable in fixture build")
#endif
    }

#if PHASE0_NATIVE
    private func startNativeSession(_ connection: ValidatedRDPConnection) {
        guard nativeSession == nil else {
            connection.password.clear()
            connectionStatusLabel.text = "Disconnect the current session before reconnecting."
            journal.append(.warning, "native connection ignored while a session is active")
            return
        }

        nativeGeneration &+= 1
        if nativeGeneration == 0 { nativeGeneration = 1 }
        nativeSurfaceGeneration = 0
        nativeFrameID = 0
        let generation = nativeGeneration
        channelExerciseCounters = Phase0ChannelExerciseCounters(generation: generation)
        refreshChannelExerciseStatus()
        let session = NativeRDPSession(
            generation: generation,
            journal: journal,
            onStatus: { [weak self] status in
                self?.receiveNativeStatus(status)
            },
            onFrame: { [weak self] frame in
                self?.receiveNativeFrame(frame)
            },
            onCertificate: { [weak self] message in
                self?.journal.append(.state, message)
            },
            onChannel: { [weak self] telemetry in
                self?.receiveNativeChannel(telemetry)
            },
            onClipboardProbe: { [weak self] telemetry in
                self?.receiveNativeClipboardProbe(telemetry)
            },
            onDisplayResize: { [weak self] telemetry in
                self?.receiveNativeDisplayResize(telemetry)
            },
            onUntrustedCertificate: { [weak self] review, response in
                guard let self else {
                    response(false)
                    return
                }
                self.reviewNativeCertificate(review, response: response)
            },
            onFinished: { [weak self] generation, runStatus, destroyStatus in
                self?.finishNativeSession(
                    generation: generation,
                    runStatus: runStatus,
                    destroyStatus: destroyStatus
                )
            }
        )
        nativeSession = session
        refreshChannelExerciseStatus()
        router.releaseAll(reason: "native session starting")
        inputSink.useSessionSink(session)
        connectButton.isEnabled = false
        disconnectButton.isEnabled = true
        connectionStatusLabel.text = "Connecting \(connection.descriptor)…"
        journal.append(.state, "native connect g=\(generation) \(connection.descriptor)")

        let dimensions = DesktopFixturePreset(
            rawValue: fixtureControl.selectedSegmentIndex
        )?.dimensions ?? DesktopFixturePreset.fullHD1080.dimensions
        session.start(
            connection,
            desktopWidth: UInt32(dimensions.width),
            desktopHeight: UInt32(dimensions.height)
        )
    }

    private func reviewNativeCertificate(
        _ review: NativeCertificateReview,
        response: @escaping @Sendable (Bool) -> Void
    ) {
        guard nativeSession?.generation == review.generation,
              UIApplication.shared.applicationState == .active,
              !isShutdown else {
            response(false)
            return
        }

        resolveNativeCertificateReview(accept: false)
        certificateReviewGate.replace(with: response)
        let bindingWarning = review.hostnameBinding.isVerified
            ? ""
            : """


            This endpoint is an IP address, so the certificate's name was NOT \
            checked. The fingerprint below is the only thing identifying this \
            server.
            """
        // The chain, its signatures and its validity period have all passed by
        // the time a review is offered, so this names the one requirement the
        // user is actually being asked to override.
        let purposeWarning = review.decidingStage == .serverPurpose
            ? """


            This certificate is not a valid iOS server certificate. Its chain \
            and validity period are sound, but it does not meet what iOS asks \
            of a TLS server certificate, so only the fingerprint identifies it.
            """
            : ""
        let alert = UIAlertController(
            title: "Untrusted RDP certificate",
            message: """
            \(review.hostname):\(review.port) was not accepted by iOS system trust.

            \(review.systemTrustSummary)\(purposeWarning)\(bindingWarning)

            Leaf SHA-256:
            \(review.leafSHA256)

            Verify this fingerprint out of band before trusting it once.
            """,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Reject", style: .cancel) { [weak self] _ in
            self?.resolveNativeCertificateReview(accept: false)
        })
        alert.addAction(UIAlertAction(title: "Trust Once", style: .destructive) { [weak self] _ in
            self?.resolveNativeCertificateReview(accept: true)
        })
        certificateAlert = alert
        journal.append(
            .warning,
            "certificate requires explicit review \(RDPDiagnosticRedaction.endpoint(port: review.port)) \(review.certificateFingerprints)"
        )
        present(alert, animated: true)
    }

    private func resolveNativeCertificateReview(accept: Bool) {
        certificateAlert?.dismiss(animated: true)
        certificateAlert = nil
        certificateReviewGate.resolve(accept: accept)
    }

    private func receiveNativeStatus(_ status: HarnessSessionStatus) {
        guard nativeSession?.generation == status.generation else {
            journal.append(.drop, "stale native status \(status)")
            return
        }
        connectionStatusLabel.text = status.description
        journal.append(status.phase == .failed ? .warning : .state, status.description)
    }

    private func receiveNativeFrame(_ frame: NativeDesktopFrameSnapshot) {
        guard nativeSession?.generation == frame.generation else {
            journal.append(.drop, "stale native frame g=\(frame.generation)")
            return
        }
        guard frame.surfaceGeneration >= nativeSurfaceGeneration else {
            journal.append(.drop, "older native surface generation")
            return
        }
        let isNewSurface = frame.surfaceGeneration != nativeSurfaceGeneration
        if !isNewSurface {
            guard frame.frameID > nativeFrameID else {
                journal.append(.drop, "duplicate/out-of-order native frame")
                return
            }
        } else {
            nativeSurfaceGeneration = frame.surfaceGeneration
            nativeFrameID = 0
        }

        do {
            let frameToApply = isNewSurface ? frame.requiringFullDamage() : frame
            try surface.apply(frameToApply.update)
            nativeFrameID = frame.frameID
        } catch {
            journal.append(
                .warning,
                "native frame rejected surface-g=\(frame.surfaceGeneration) frame=\(frame.frameID) error=\(error)"
            )
        }
    }

    private func receiveNativeChannel(_ telemetry: Phase0ChannelTelemetry) {
        guard nativeSession?.generation == telemetry.generation,
              var counters = channelExerciseCounters,
              counters.record(telemetry) else {
            journal.append(
                .drop,
                "stale/out-of-order channel telemetry g=\(telemetry.generation) seq=\(telemetry.sequence)"
            )
            return
        }
        channelExerciseCounters = counters
        journal.append(.state, telemetry.description)
        refreshChannelExerciseStatus()
    }

    private func receiveNativeClipboardProbe(
        _ telemetry: Phase0ClipboardProbeTelemetry
    ) {
        guard nativeSession?.generation == telemetry.generation,
              var counters = channelExerciseCounters,
              counters.record(telemetry) else {
            journal.append(
                .drop,
                "stale/out-of-order cliprdr telemetry g=\(telemetry.generation) seq=\(telemetry.sequence)"
            )
            return
        }
        channelExerciseCounters = counters
        journal.append(telemetry.statusCode == 0 ? .state : .warning, telemetry.description)
        refreshChannelExerciseStatus()
    }

    private func receiveNativeDisplayResize(_ telemetry: Phase0DisplayResizeTelemetry) {
        guard nativeSession?.generation == telemetry.generation,
              var counters = channelExerciseCounters,
              counters.record(telemetry) else {
            journal.append(
                .drop,
                "stale/out-of-order disp telemetry g=\(telemetry.generation) seq=\(telemetry.sequence)"
            )
            return
        }
        channelExerciseCounters = counters
        journal.append(telemetry.statusCode == 0 ? .state : .warning, telemetry.description)
        refreshChannelExerciseStatus()
    }

    private func refreshChannelExerciseStatus() {
        guard let counters = channelExerciseCounters else {
            clipboardProbeButton.isEnabled = false
            displayResizeButton.isEnabled = false
            channelStatusLabel.text = "Channel exercise: connect to a disposable target (results NOT RUN)."
            return
        }
        clipboardProbeButton.isEnabled = nativeSession != nil && counters.isConnected(.cliprdr)
        displayResizeButton.isEnabled = nativeSession != nil && counters.isConnected(.disp)
        channelStatusLabel.text = counters.summary
    }

    private func finishNativeSession(
        generation: UInt64,
        runStatus: mr_rdp_status,
        destroyStatus: mr_rdp_status?
    ) {
        guard nativeSession?.generation == generation else { return }
        resolveNativeCertificateReview(accept: false)
        router.releaseAll(reason: "native session worker finished")
        inputSink.useRecordingSink()
        nativeSession = nil
        refreshChannelExerciseStatus()
        connectButton.isEnabled = true
        disconnectButton.isEnabled = false
        let destroyed = destroyStatus.map(String.init) ?? "not-created"
        connectionStatusLabel.text = "Native session ended run=\(runStatus) destroy=\(destroyed)"
        journal.append(
            runStatus == mr_rdp_status(MR_RDP_STATUS_OK)
                && destroyStatus == mr_rdp_status(MR_RDP_STATUS_OK) ? .state : .warning,
            "native worker finished g=\(generation) run=\(runStatus) destroy=\(destroyed)"
        )
    }
#endif

    @objc private func clearTrace() {
        recordingSink.clear()
        journal.clear()
        journal.append(.state, "trace cleared")
    }

    @objc private func exportTrace(_ sender: UIButton) {
        passwordField.text = nil
        if modeControl.selectedSegmentIndex == 0 {
            _ = surface.resignFirstResponder()
        } else {
            _ = proxy.resignFirstResponder()
        }
        let text = journal.exportText(environmentNotes: environmentNotes.text)
        let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = sender
        controller.popoverPresentationController?.sourceRect = sender.bounds
        present(controller, animated: true)
    }

    private func refreshJournal() {
        let counters = journal.counters
        counterLabel.text = "observed=\(counters.observed)  sent=\(counters.sent)  dropped=\(counters.dropped)"
        logView.text = journal.displayText
        if !logView.text.isEmpty {
            logView.scrollRangeToVisible(NSRange(location: logView.text.utf16.count - 1, length: 1))
        }
    }

    private func refreshDeviceStatus() {
        deviceStatusLabel.text = "\(keyboardStatus)\n\(mouseStatus)"
    }

    private func makeLabel(_ text: String, style: UIFont.TextStyle) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.textColor = .label
        return label
    }

    private func makeButton(_ title: String, action: Selector) -> UIButton {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.buttonSize = .small
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func defaultEnvironmentNotes() -> String {
        let device = UIDevice.current
        return """
        device model/identifier: \(device.model) / [enter identifier]
        OS version/build: \(device.systemName) \(device.systemVersion) / [enter build]
        keyboard model/fw/connection: [enter]
        mouse/trackpad model/connection: [enter]
        hardware keyboard layout: [enter]
        Caps Lock/Globe/FKA/modifier remap: [enter]
        Stage Manager/Split View/orientation: [enter]
        """
    }
}
