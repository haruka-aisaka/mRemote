import Foundation
import GameController

@MainActor
final class GCKeyboardMonitor {
    var onStatus: ((String) -> Void)?

    private let arbiter: KeyboardEventArbiter
    private var observers: [NSObjectProtocol] = []
    private weak var attachedKeyboard: GCKeyboard?

    init(arbiter: KeyboardEventArbiter) {
        self.arbiter = arbiter
    }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCKeyboardDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.attach(notification.object as? GCKeyboard ?? GCKeyboard.coalesced)
            }
        })
        observers.append(center.addObserver(
            forName: .GCKeyboardDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            MainActor.assumeIsolated {
                let keyboard = notification.object as? GCKeyboard
                self.onStatus?("GCKeyboard disconnected: \(keyboard?.vendorName ?? "unknown")")
                if keyboard === self.attachedKeyboard {
                    self.detach()
                    self.arbiter.keyboardDisconnected()
                }
            }
        })
        attach(GCKeyboard.coalesced)
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        detach()
    }

    private func attach(_ keyboard: GCKeyboard?) {
        detach()
        guard let keyboard, let input = keyboard.keyboardInput else {
            onStatus?("GCKeyboard: not connected")
            return
        }
        attachedKeyboard = keyboard
        keyboard.handlerQueue = .main
        input.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.arbiter.receive(HardwareKeyEvent(
                    usage: UInt16(truncatingIfNeeded: keyCode.rawValue),
                    transition: pressed ? .down : .up,
                    source: .gameController,
                    uptime: ProcessInfo.processInfo.systemUptime
                ))
            }
        }
        onStatus?("GCKeyboard: \(keyboard.vendorName ?? "unknown")")
    }

    private func detach() {
        attachedKeyboard?.keyboardInput?.keyChangedHandler = nil
        attachedKeyboard = nil
    }
}

@MainActor
final class GCMouseMonitor {
    var onStatus: ((String) -> Void)?
    var onRelativeMove: ((Double, Double) -> Void)?
    var remoteLocationProvider: (() -> CGPoint?)?

    private let arbiter: PointerEventArbiter
    private var observers: [NSObjectProtocol] = []
    private weak var attachedMouse: GCMouse?

    init(arbiter: PointerEventArbiter) {
        self.arbiter = arbiter
    }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCMouseDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.attach(notification.object as? GCMouse ?? GCMouse.current ?? GCMouse.mice().first)
            }
        })
        observers.append(center.addObserver(
            forName: .GCMouseDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            MainActor.assumeIsolated {
                let mouse = notification.object as? GCMouse
                self.onStatus?("GCMouse disconnected: \(mouse?.vendorName ?? "unknown")")
                if mouse === self.attachedMouse {
                    self.detach()
                    self.arbiter.mouseDisconnected()
                }
            }
        })
        attach(GCMouse.current ?? GCMouse.mice().first)
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        detach()
    }

    private func attach(_ mouse: GCMouse?) {
        detach()
        guard let mouse, let input = mouse.mouseInput else {
            onStatus?("GCMouse: not connected")
            return
        }
        attachedMouse = mouse
        mouse.handlerQueue = .main
        input.mouseMovedHandler = { [weak self] _, deltaX, deltaY in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.onRelativeMove?(Double(deltaX), Double(deltaY))
            }
        }
        installButton(input.leftButton, as: .left)
        if let rightButton = input.rightButton { installButton(rightButton, as: .right) }
        if let middleButton = input.middleButton { installButton(middleButton, as: .middle) }
        input.scroll.valueChangedHandler = { [weak self] _, horizontal, vertical in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.arbiter.receive(PointerInputEvent(
                    payload: .scroll(horizontal: Double(horizontal), vertical: Double(vertical)),
                    source: .gameController,
                    uptime: ProcessInfo.processInfo.systemUptime
                ))
            }
        }
        onStatus?("GCMouse: \(mouse.vendorName ?? "unknown")")
    }

    private func installButton(_ input: GCControllerButtonInput, as button: PointerButton) {
        input.pressedChangedHandler = { [weak self] _, _, pressed in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.arbiter.receive(PointerInputEvent(
                    payload: .button(
                        button,
                        pressed ? .down : .up,
                        remote: self.remoteLocationProvider?()
                    ),
                    source: .gameController,
                    uptime: ProcessInfo.processInfo.systemUptime
                ))
            }
        }
    }

    private func detach() {
        guard let input = attachedMouse?.mouseInput else {
            attachedMouse = nil
            return
        }
        input.mouseMovedHandler = nil
        input.leftButton.pressedChangedHandler = nil
        input.rightButton?.pressedChangedHandler = nil
        input.middleButton?.pressedChangedHandler = nil
        input.scroll.valueChangedHandler = nil
        attachedMouse = nil
    }
}
