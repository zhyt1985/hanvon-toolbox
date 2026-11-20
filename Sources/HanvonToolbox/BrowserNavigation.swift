import Foundation

struct BrowserNavigation<Value: Equatable> {
    private(set) var past: [Value] = []
    private(set) var future: [Value] = []
    private(set) var current: Value?
    mutating func visit(_ value: Value) {
        guard current != value else { return }
        if let current { past.append(current) }
        if past.count > 100 { past.removeFirst() }
        current = value; future = []
    }
    mutating func back() -> Value? {
        guard let value = past.popLast() else { return nil }
        if let current { future.append(current) }
        current = value; return value
    }
    mutating func forward() -> Value? {
        guard let value = future.popLast() else { return nil }
        if let current { past.append(current) }
        current = value; return value
    }
}

struct BrowserBookmark: Codable, Identifiable {
    let id: UUID
    let scope: Data?
    let local: URL?
    let names: [String]
    var title: String { local?.lastPathComponent ?? names.last ?? "存储根目录" }
    static func load() -> [Self] {
        guard let data = UserDefaults.standard.data(forKey: "hanvon.browserBookmarks") else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }
    static func save(_ values: [Self]) {
        if let data = try? JSONEncoder().encode(values) { UserDefaults.standard.set(data, forKey: "hanvon.browserBookmarks") }
    }
}

struct BrowserSearchHit: Identifiable {
    let id = UUID()
    let path: [String]
    let local: URL?
    let remoteParents: [Breadcrumb]?
    let name: String
}
