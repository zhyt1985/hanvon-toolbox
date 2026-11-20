import Foundation

public extension DirectorySync {
    struct PlanRow: Identifiable, Sendable {
        public enum Action: String, CaseIterable, Sendable {
            case addToDevice = "新增到电纸书"
            case addToMac = "新增到 Mac"
            case updateDevice = "更新电纸书"
            case updateMac = "更新 Mac"
            case review = "需处理"
            case identical = "已一致"
            case ignored = "已忽略"
        }

        public let id: UUID
        public let path: String
        public let action: Action
        public let detail: String?
        public let step: TransferStep?
        public let macFingerprint: Fingerprint?
        public let deviceFingerprint: Fingerprint?

        public var canResolve: Bool {
            action == .review && macFingerprint != nil && deviceFingerprint != nil
        }

        /// Resolves only a verified regular-file conflict. The executor revalidates
        /// both fingerprints before backing up and publishing the chosen version.
        public func resolving(_ direction: Direction?) -> PlanRow {
            guard canResolve, let direction, let mac = macFingerprint, let reader = deviceFingerprint else {
                return self
            }
            let update = SyncUpdate(path: path.components(separatedBy: "/"), direction: direction,
                                    source: direction == .toDevice ? mac : reader,
                                    destination: direction == .toDevice ? reader : mac)
            return PlanRow(id: id, path: path, action: direction == .toDevice ? .updateDevice : .updateMac,
                           detail: direction == .toDevice ? "手动选择 Mac 版本 · 更新前备份电纸书版本"
                               : "手动选择电纸书版本 · 更新前备份 Mac 版本",
                           step: .init(name: path, action: .syncUpdate(update)),
                           macFingerprint: mac, deviceFingerprint: reader)
        }

        public var direction: Direction? {
            switch action {
            case .addToDevice, .updateDevice: .toDevice
            case .addToMac, .updateMac: .toMac
            case .review, .identical, .ignored: nil
            }
        }
    }

    struct BidirectionalPlan: Sendable {
        public let rows: [PlanRow]
        public let verifiedFiles: [Row]
    }

    static func planBidirectional(
        local: LocalRoot, remote: DeviceFolder, on device: any DeviceConnection,
        baseline: [String: Fingerprint]
    ) async throws -> BidirectionalPlan {
        let forward = try await compare(.toDevice, local: local, remote: remote, on: device,
                                        verifyContents: true, baseline: baseline, captureFingerprints: true)
        let reverse = try await compare(.toMac, local: local, remote: remote, on: device, baseline: baseline)
        try Task.checkCancellation()
        try local.validate()

        let forwardPaths = Set(forward.filter { $0.kind != .keepDestination }.map { nameKey($0.path) })
        let blocked = forward.filter { $0.kind == .conflict || $0.kind == .excluded }.map { nameKey($0.path) }
        var rows = forward.filter { $0.kind != .keepDestination }.map {
            planRow($0, copying: .toDevice)
        }
        for row in reverse where !forwardPaths.contains(nameKey(row.path)) && row.kind != .keepDestination {
            let underBlocked = blocked.contains { nameKey(row.path).hasPrefix($0 + "/") }
            if !underBlocked {
                rows.append(planRow(row, copying: .toMac))
            }
        }
        rows.sort {
            let comparison = $0.path.localizedStandardCompare($1.path)
            return comparison == .orderedSame ? $0.path < $1.path : comparison == .orderedAscending
        }
        return BidirectionalPlan(rows: rows, verifiedFiles: forward)
    }

    private static func planRow(_ row: Row, copying direction: Direction) -> PlanRow {
        let action: PlanRow.Action
        switch row.kind {
        case .copyFile, .createFolder:
            action = direction == .toDevice ? .addToDevice : .addToMac
        case .identical:
            action = .identical
        case .excluded:
            action = .ignored
        case .keepDestination:
            action = .review
        case .conflict:
            switch row.baselineChange {
            case .macModified: action = .updateDevice
            case .deviceModified: action = .updateMac
            case .bothModified, .missingOnMac, .missingOnDevice, nil: action = .review
            }
        }
        let detail = [row.baselineChange?.rawValue, row.detail].compactMap { $0 }.joined(separator: " · ")
        var step = row.step
        if action == .updateDevice || action == .updateMac,
           let mac = row.macFingerprint, let reader = row.deviceFingerprint {
            let direction: Direction = action == .updateDevice ? .toDevice : .toMac
            let update = SyncUpdate(path: row.path.components(separatedBy: "/"), direction: direction,
                                    source: direction == .toDevice ? mac : reader,
                                    destination: direction == .toDevice ? reader : mac)
            step = .init(name: row.path, action: .syncUpdate(update))
        }
        return PlanRow(id: UUID(), path: row.path, action: action, detail: detail.isEmpty ? nil : detail, step: step,
                       macFingerprint: row.macFingerprint, deviceFingerprint: row.deviceFingerprint)
    }
}
