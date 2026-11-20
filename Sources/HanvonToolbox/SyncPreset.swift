import Foundation
import ToolboxCore

struct SyncPreset: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let local: DirectorySync.LocalRoot
    let target: TransferDestination
    let remotePath: [String]
    let direction: DirectorySync.Direction

    init(name: String, local: DirectorySync.LocalRoot, target: TransferDestination,
         remotePath: [String], direction: DirectorySync.Direction) {
        id = UUID()
        self.name = name
        self.local = local
        self.target = target
        self.remotePath = remotePath
        self.direction = direction
    }

    func matches(_ current: TransferDestination?) -> Bool {
        target.launchID == nil && target == current
    }

    func resolve(
        in volume: DeviceVolume, list: @Sendable (DeviceFolder) async throws -> [DeviceItem]
    ) async throws -> (path: [Breadcrumb], items: [DeviceItem]) {
        guard volume.root == target.root, volume.identity == target.volumeIdentity else {
            throw ToolboxError.message("此预设的原设备存储不可用。")
        }
        var path = [Breadcrumb(name: volume.name, folder: volume.root)]
        var items = try await list(volume.root)
        for name in remotePath {
            try Task.checkCancellation()
            let matching = items.filter { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
            guard matching.count == 1, let item = matching.first, item.name == name, let child = item.folder else {
                throw ToolboxError.message("预设中的设备目录「\(name)」已移动、改名或存在同名项。")
            }
            do {
                items = try await list(child)
            } catch ToolboxError.remoteItemMissing {
                throw ToolboxError.message("预设中的设备目录「\(name)」已不可用。")
            }
            path.append(.init(name: name, folder: child))
        }
        return (path, items)
    }
}

struct SyncPresetStore {
    let defaults: UserDefaults
    private static let key = "hanvon.syncPresets"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> [SyncPreset] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return try JSONDecoder().decode([SyncPreset].self, from: data)
    }

    func save(_ presets: [SyncPreset]) throws {
        defaults.set(try JSONEncoder().encode(presets), forKey: Self.key)
    }
}
