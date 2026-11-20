import ToolboxCore

struct CompanionRetry {
    private(set) var target: DiscoveredCompanion?
    private var failures = 0
    private(set) var deadline: Double?

    mutating func failed(_ device: DiscoveredCompanion, now: Double, retryable: Bool) {
        if device.id != target?.id || device.address != target?.address {
            failures = 0
        }
        target = device
        guard retryable else {
            deadline = nil
            return
        }
        let delays: [Double] = [2, 4, 8, 16, 30]
        deadline = now + delays[failures]
        failures = min(failures + 1, delays.count - 1)
    }

    func waiting(for device: DiscoveredCompanion, now: Double) -> Bool {
        guard device.id == target?.id, device.address == target?.address else { return false }
        return deadline.map { now < $0 } ?? true
    }
}
