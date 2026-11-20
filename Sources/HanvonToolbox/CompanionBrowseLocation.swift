import ToolboxCore

struct CompanionBrowseLocation: Codable, Equatable, Sendable {
    let rootIdentity: String
    let names: [String]

    static func resolve(
        _ saved: Self?, in root: DeviceVolume, list: @Sendable (DeviceFolder) async throws -> [DeviceItem]
    ) async throws -> (path: [Breadcrumb], items: [DeviceItem]) {
        var path = [Breadcrumb(name: root.name, folder: root.root)]
        var items = try await list(root.root)
        if let saved, saved.rootIdentity == root.identity {
            for name in saved.names {
                guard let folder = items.first(where: { $0.name == name && $0.isFolder })?.folder else { break }
                do {
                    items = try await list(folder)
                    path.append(.init(name: name, folder: folder))
                } catch ToolboxError.remoteItemMissing {
                    // The directory disappeared between reading the parent and opening it.
                    break
                }
            }
        }
        return (path, items)
    }
}
