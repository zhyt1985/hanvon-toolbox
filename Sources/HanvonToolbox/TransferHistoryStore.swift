import Foundation

actor TransferHistoryStore {
    private let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "HanvonToolbox/TransferHistory")) {
        self.directory = directory
    }

    nonisolated func load() -> (records: [TransferRecord], warning: String?) {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ([], nil)
        } catch {
            return ([], "无法读取传输记录。\(error.localizedDescription)")
        }

        let decoder = JSONDecoder()
        var records: [TransferRecord] = []
        var unreadable = 0
        for file in files where file.pathExtension == "json" {
            do {
                var record = try decoder.decode(TransferRecord.self, from: Data(contentsOf: file))
                guard file.lastPathComponent == filename(record.id) else {
                    unreadable += 1
                    continue
                }
                for index in record.rows.indices where record.rows[index].result == .running {
                    record.rows[index].result = .interrupted("工具箱退出时仍在传输，请核对目标后重试。")
                }
                records.append(record)
            } catch {
                unreadable += 1
            }
        }
        let warning = unreadable == 0 ? nil : "有 \(unreadable) 批传输记录无法读取。"
        return (records.sorted { $0.createdAt < $1.createdAt }, warning)
    }

    func save(_ record: TransferRecord) throws {
        let data = try JSONEncoder().encode(record)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: directory.appending(path: filename(record.id)), options: .atomic)
    }

    private nonisolated func filename(_ id: UUID) -> String {
        "\(id.uuidString).json"
    }
}
