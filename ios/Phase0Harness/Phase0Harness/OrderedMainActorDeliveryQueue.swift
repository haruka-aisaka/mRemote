import Foundation

/// Preserves callback submission order while hopping from a serialized worker
/// to MainActor. Independent unstructured tasks can execute out of order and
/// would make sequence-gated consumers discard valid earlier events.
final class OrderedMainActorDeliveryQueue: @unchecked Sendable {
    typealias Delivery = @MainActor @Sendable () -> Void

    private let lock = NSLock()
    private var pending: [Delivery] = []
    private var deliveryScheduled = false

    func submit(_ delivery: @escaping Delivery) {
        lock.lock()
        pending.append(delivery)
        let shouldSchedule = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()

        if shouldSchedule {
            Task { @MainActor [self] in drain() }
        }
    }

    @MainActor
    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else {
                deliveryScheduled = false
                lock.unlock()
                return
            }
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            lock.unlock()

            for delivery in batch {
                delivery()
            }
        }
    }
}
