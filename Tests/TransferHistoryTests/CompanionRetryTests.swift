import Testing
import ToolboxCore
@testable import HanvonToolbox

struct CompanionRetryTests {
    private let device = DiscoveredCompanion(id: "N10", name: "N10", address: "https://192.0.2.2:10000")
    private let restarted = DiscoveredCompanion(id: "N10", name: "N10", address: "https://192.0.2.2:10100")

    @Test func repeatsTemporaryFailuresAndCapsTheDelay() {
        var retry = CompanionRetry()
        var now = 0.0
        for delay in [2.0, 4, 8, 16, 30, 30] {
            retry.failed(device, now: now, retryable: true)
            #expect(retry.deadline == now + delay)
            #expect(retry.waiting(for: device, now: now + delay - 1))
            now += delay
            #expect(!retry.waiting(for: device, now: now))
        }
    }

    @Test func doesNotRetryARejectedAddressUntilItChangesOrTheUserRetries() {
        var retry = CompanionRetry()
        retry.failed(device, now: 5, retryable: false)
        #expect(retry.deadline == nil)
        #expect(retry.waiting(for: device, now: 60))
        #expect(!retry.waiting(for: restarted, now: 5))
        retry.failed(restarted, now: 6, retryable: true)
        #expect(retry.deadline == 8)
        #expect(!CompanionRetry().waiting(for: device, now: 60))
    }
}
