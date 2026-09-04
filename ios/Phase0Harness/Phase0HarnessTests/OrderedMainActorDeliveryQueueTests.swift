import XCTest
#if SWIFT_PACKAGE
@testable import Phase0HarnessLogic
#else
@testable import Phase0Harness
#endif

@MainActor
final class OrderedMainActorDeliveryQueueTests: XCTestCase {
    func testDeliversQueuedSubmissionsInFIFOOrder() async {
        let queue = OrderedMainActorDeliveryQueue()
        let expected = Array(0..<128)
        var delivered: [Int] = []

        await withCheckedContinuation { continuation in
            for value in expected {
                queue.submit {
                    delivered.append(value)
                    if delivered.count == expected.count {
                        continuation.resume()
                    }
                }
            }
        }

        XCTAssertEqual(delivered, expected)
    }

    func testReentrantSubmissionRunsAfterAlreadyQueuedDeliveries() async {
        let queue = OrderedMainActorDeliveryQueue()
        var delivered: [Int] = []

        await withCheckedContinuation { continuation in
            queue.submit {
                delivered.append(1)
                queue.submit {
                    delivered.append(3)
                    continuation.resume()
                }
            }
            queue.submit {
                delivered.append(2)
            }
        }

        XCTAssertEqual(delivered, [1, 2, 3])
    }
}
