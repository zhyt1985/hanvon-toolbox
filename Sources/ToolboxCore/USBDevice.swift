import Foundation

public actor USBDevice: DeviceConnection {
    public nonisolated let kind = ConnectionKind.usb
    private static let rootHandle: UInt32 = .max
    private static let folderFormat: UInt16 = 0x3001
    private static let maxObjectSize = UInt64(UInt32.max) - 12

    private var wire: MTPWire?
    private var deviceName = ""
    private var deviceFields: [DeviceInfo.Field] = []
    private var operations = Set<UInt16>()

    private init() {}

    public static func connect() async throws -> USBDevice {
        let device = USBDevice()
        try await device.open()
        return device
    }

    private func open() throws {
        let wire = try MTPWire(link: USBLink())
        var info = MTPData(try wire.call(0x1001).requiredData())
        let standardVersion = try info.u16()
        try info.skip(6)
        _ = try info.string()
        try info.skip(2)
        operations = try info.operations()
        for _ in 0..<4 { _ = try info.operations() }
        let manufacturer = try info.string()
        deviceName = try info.string()
        let deviceVersion = try info.string()
        let mtpSerial = try info.string()

        guard operations.contains(0x1002), operations.contains(0x1007) else {
            throw ToolboxError.unsupported("这台设备未公开所需的 MTP 文件接口。")
        }
        try wire.openSession()
        self.wire = wire

        deviceFields = [
            .init("厂商", manufacturer),
            .init("USB 产品 ID", "2207:0007"),
            .init("MTP 标准版本", String(format: "%d.%02d", standardVersion / 100, standardVersion % 100)),
            .init("MTP 设备版本", deviceVersion),
        ]
        if let serial = wire.link.serial { deviceFields.append(.init("USB 序列号", serial)) }
        if !mtpSerial.isEmpty { deviceFields.append(.init("MTP 序列号", mtpSerial)) }
        if let speed = [1: "1.5 Mb/s", 2: "12 Mb/s", 3: "480 Mb/s", 4: "5 Gb/s", 5: "10 Gb/s"][Int(wire.link.speed)] {
            deviceFields.append(.init("USB 链路速率", speed))
        }
    }

    public func info() throws -> DeviceInfo {
        let wire = try session()
        var response = MTPData(try wire.call(0x1004).requiredData())
        let volumes = try response.identifiers().map { storage in
            var data = MTPData(try wire.call(0x1005, parameters: [storage]).requiredData())
            try data.skip(6)
            let capacity = try data.u64()
            let free = try data.u64()
            try data.skip(4)
            let name = try data.string()
            return DeviceVolume(
                name: name.isEmpty ? String(format: "存储空间 %08X", storage) : name,
                root: .usb(storage: storage, parent: Self.rootHandle),
                capacity: capacity == .max ? nil : capacity,
                freeSpace: free == .max ? nil : free
            )
        }
        return DeviceInfo(
            name: deviceName.isEmpty ? "HANVON" : deviceName,
            fields: deviceFields, volumes: volumes,
            supportsAPK: operations.contains(0x100D),
            canManageFiles: [0x100B, 0x100C, 0x1019, 0x101A, 0x9804].allSatisfy(operations.contains),
            supportsRecoveryCleanup: operations.contains(0x100B),
            supportsFileOperations: [0x100B, 0x1019, 0x101A].allSatisfy(operations.contains)
        )
    }

    public func list(_ folder: DeviceFolder) throws -> [DeviceItem] {
        let wire = try session()
        let (storage, parent) = try usbFolder(folder)
        var data = MTPData(try wire.call(0x1007, parameters: [storage, 0, parent]).requiredData())
        return try data.identifiers().map { handle in
            try Task.checkCancellation()
            return try object(handle)
        }.sorted(by: listOrder)
    }

    public func download(_ item: DeviceItem, to destination: URL, progress: ProgressUpdate?) throws {
        let wire = try session()
        let (_, handle) = try usbItem(item)
        guard !item.isFolder, let size = item.size, size <= Self.maxObjectSize else {
            throw ToolboxError.unsupported("USB 首版支持下载小于 4 GiB 的单个文件。")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ToolboxError.conflict(destination.lastPathComponent)
        }
        let temp = try createTransferFile(in: destination.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: temp) }

        let file = try FileHandle(forWritingTo: temp)
        do {
            _ = try wire.call(0x1009, parameters: [handle], download: .init(file: file, size: size, progress: progress))
            try file.close()
        } catch {
            try? file.close()
            throw error
        }
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    public func upload(_ file: URL, to folder: DeviceFolder, progress: ProgressUpdate?) throws {
        let wire = try session()
        let name = file.lastPathComponent
        try validateFileName(name)
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let count = values.fileSize, count >= 0 else {
            throw ToolboxError.message("请选择本机普通文件。")
        }
        guard UInt64(count) <= Self.maxObjectSize else {
            throw ToolboxError.unsupported("USB 首版支持上传小于 4 GiB 的单个文件。")
        }

        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let handle = try addObject(named: name, size: UInt32(count), folder: folder, isFolder: false)
        do {
            _ = try wire.call(0x100D, upload: .init(file: input, size: UInt64(count), progress: progress))
        } catch {
            if wire.link.handle != nil, (try? object(handle).name) == name {
                _ = try? wire.call(0x100B, parameters: [handle, 0])
            }
            throw error
        }

        let object = try object(handle)
        guard object.name == name, object.size == UInt64(count) else {
            throw ToolboxError.invalidResponse("上传完成，但设备报告的文件名或大小不一致。")
        }
    }

    public func makeFolder(named name: String, in folder: DeviceFolder) throws -> DeviceItem {
        let handle = try addObject(named: name, size: 0, folder: folder, isFolder: true)
        return try object(handle)
    }

    public func rename(_ item: DeviceItem, in folder: DeviceFolder, to name: String) throws {
        try validateFileName(name)
        guard item.name != name else { return }
        let (_, handle) = try usbItem(item)
        if try hasName(list(folder), name, except: item.id) { throw ToolboxError.conflict(name) }
        var data = Data()
        data.appendMTPString(name)
        _ = try session().call(0x9804, parameters: [handle, 0xDC07], data: data)
    }

    public func delete(_ item: DeviceItem) throws {
        let (_, handle) = try usbItem(item)
        _ = try session().call(0x100B, parameters: [handle, 0])
    }

    public func relocate(_ item: DeviceItem, to folder: DeviceFolder, copying: Bool) throws {
        let (_, handle) = try usbItem(item)
        let (storage, parent) = try usbFolder(folder)
        guard item.folder != folder else {
            throw ToolboxError.message("不能将目录放入自身。")
        }
        if try hasName(list(folder), item.name) { throw ToolboxError.conflict(item.name) }
        _ = try session().call(copying ? 0x101A : 0x1019, parameters: [handle, storage, parent])
    }

    public func close() {
        wire?.closeSession()
        wire = nil
    }

    private func addObject(named name: String, size: UInt32, folder: DeviceFolder, isFolder: Bool) throws -> UInt32 {
        try validateFileName(name)
        let (storage, parent) = try usbFolder(folder)
        if try hasName(list(folder), name) { throw ToolboxError.conflict(name) }

        var data = Data()
        data.appendMTP(storage)
        data.appendMTP(isFolder ? Self.folderFormat : 0x3000)
        data.appendMTP(UInt16(0))
        data.appendMTP(size)
        data.append(Data(count: 26))
        data.appendMTP(parent)
        data.appendMTP(UInt16(isFolder ? 1 : 0))
        data.append(Data(count: 8))
        data.appendMTPString(name)
        data.append(contentsOf: [0, 0, 0])

        let reply = try session().call(0x100C, parameters: [storage, parent], data: data)
        // Android may report a root parent as either 0 or 0xffffffff.
        guard reply.parameters.count == 3, reply.parameters[0] == storage,
              reply.parameters[1] == parent || (parent == Self.rootHandle && reply.parameters[1] == 0),
              reply.parameters[2] != 0 else {
            throw ToolboxError.invalidResponse("设备没有返回目标项目的有效句柄。")
        }
        return reply.parameters[2]
    }

    private func object(_ handle: UInt32) throws -> DeviceItem {
        var data = MTPData(try session().call(0x1008, parameters: [handle]).requiredData())
        let storage = try data.u32()
        let format = try data.u16()
        try data.skip(2)
        let size = try data.u32()
        try data.skip(40)
        let name = try data.string()
        _ = try? data.string()
        let modifiedString = try? data.string()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        let modified = modifiedString.flatMap { formatter.date(from: String($0.prefix(15))) }
        let folder: DeviceFolder? = format == Self.folderFormat ? .usb(storage: storage, parent: handle) : nil
        return DeviceItem(
            id: .usb(storage: storage, handle: handle), name: name,
            folder: folder, size: folder == nil ? UInt64(size) : nil, modified: modified
        )
    }

    private func session() throws -> MTPWire {
        guard let wire, wire.link.handle != nil else {
            throw ToolboxError.usbLink("USB 会话已关闭，请重新连接。")
        }
        return wire
    }

    private func usbFolder(_ folder: DeviceFolder) throws -> (UInt32, UInt32) {
        guard case let .usb(storage, parent) = folder else { throw ToolboxError.message("请选择 USB 目录。") }
        return (storage, parent)
    }

    private func usbItem(_ item: DeviceItem) throws -> (UInt32, UInt32) {
        guard case let .usb(storage, handle) = item.id else { throw ToolboxError.message("请选择 USB 设备项目。") }
        return (storage, handle)
    }
}
