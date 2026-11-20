import CHanvonUSB
import Foundation

private let transferChunk = 64 * 1024
private let headerSize = 12

struct MTPData {
    private let bytes: [UInt8]
    private(set) var offset = 0
    var remaining: Int { bytes.count - offset }

    init(_ data: Data) {
        bytes = Array(data)
    }

    mutating func u8() throws -> UInt8 {
        guard remaining > 0 else { throw invalidData }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws -> UInt16 {
        try UInt16(u8()) | (UInt16(u8()) << 8)
    }

    mutating func u32() throws -> UInt32 {
        try UInt32(u16()) | (UInt32(u16()) << 16)
    }

    mutating func u64() throws -> UInt64 {
        try UInt64(u32()) | (UInt64(u32()) << 32)
    }

    mutating func skip(_ count: Int) throws {
        guard remaining >= count else { throw invalidData }
        offset += count
    }

    mutating func string() throws -> String {
        let count = Int(try u8())
        guard count > 0 else { return "" }
        guard remaining >= count * 2 else { throw invalidData }
        let units = try (0..<count).map { _ in try u16() }
        guard units.last == 0 else { throw invalidData }
        return String(decoding: units.dropLast(), as: UTF16.self)
    }

    mutating func operations() throws -> Set<UInt16> {
        let count = Int(try u32())
        guard count <= remaining / 2 else { throw invalidData }
        return Set(try (0..<count).map { _ in try u16() })
    }

    mutating func identifiers() throws -> [UInt32] {
        let count = Int(try u32())
        guard remaining == count * 4 else { throw invalidData }
        return try (0..<count).map { _ in try u32() }
    }

    private var invalidData: ToolboxError { .invalidResponse("MTP 数据不完整。") }
}

extension Data {
    mutating func appendMTP<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendMTPString(_ value: String) {
        if value.isEmpty {
            append(0)
            return
        }
        append(UInt8(value.utf16.count + 1))
        for unit in value.utf16 {
            appendMTP(unit)
        }
        appendMTP(UInt16(0))
    }
}

final class USBLink {
    private(set) var handle: OpaquePointer?
    let serial: String?
    let speed: Int32
    let outPacketSize: Int

    init() throws {
        var opened: OpaquePointer?
        let code = hanvon_usb_open(&opened)
        guard code == 0, let opened else {
            switch Int(code) {
            case HANVON_USB_NO_DEVICE:
                throw ToolboxError.message("没有找到已连接的汉王 N10。请连接数据线并在设备上启用文件传输。")
            case HANVON_USB_MULTIPLE_DEVICES:
                throw ToolboxError.message("检测到多台相同 USB 型号的设备。请暂时仅保留要操作的一台。")
            case HANVON_USB_NO_MTP:
                throw ToolboxError.message("设备当前未提供 MTP 接口。请在电纸书上选择文件传输。")
            default:
                throw ToolboxError.usbLink("无法打开 USB MTP 接口（\(USBLink.errorName(code))）。请关闭其他 MTP 应用后重试。")
            }
        }
        handle = opened
        var buffer = [CChar](repeating: 0, count: 256)
        let capacity = buffer.count
        let length = hanvon_usb_serial(opened, &buffer, capacity)
        serial = length > 0 ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        speed = hanvon_usb_speed(opened)
        outPacketSize = Int(hanvon_usb_out_packet_size(opened))
    }

    deinit { close() }

    func close() {
        if let handle { hanvon_usb_close(handle) }
        handle = nil
    }

    func read() throws -> Data {
        guard let handle else { throw ToolboxError.usbLink("USB 会话已关闭，请重新连接。") }
        var bytes = Data(count: transferChunk)
        var transferred: Int32 = 0
        let code = bytes.withUnsafeMutableBytes { buffer in
            hanvon_usb_read(handle, buffer.bindMemory(to: UInt8.self).baseAddress, Int32(transferChunk), &transferred)
        }
        try check(code)
        return Data(bytes.prefix(Int(transferred)))
    }

    func write(_ bytes: Data) throws {
        guard let handle else { throw ToolboxError.usbLink("USB 会话已关闭，请重新连接。") }
        var transferred: Int32 = 0
        let code = bytes.withUnsafeBytes { buffer in
            hanvon_usb_write(handle, buffer.bindMemory(to: UInt8.self).baseAddress, Int32(bytes.count), &transferred)
        }
        try check(code)
        guard transferred == bytes.count else {
            throw ToolboxError.usbLink("USB 写入中断，请重新连接。")
        }
    }

    private func check(_ code: Int32) throws {
        guard code == 0 else {
            throw ToolboxError.usbLink("USB 传输中断（\(Self.errorName(code))），请重新连接。")
        }
    }

    private static func errorName(_ code: Int32) -> String {
        String(cString: hanvon_usb_error(code))
    }
}

final class MTPWire {
    struct Upload {
        let file: FileHandle
        let size: UInt64
        let progress: ProgressUpdate?
    }

    struct Download {
        let file: FileHandle
        let size: UInt64
        let progress: ProgressUpdate?
    }

    struct Reply {
        let data: Data?
        let parameters: [UInt32]

        func requiredData() throws -> Data {
            guard let data else { throw ToolboxError.invalidResponse("MTP 没有返回数据。") }
            return data
        }
    }

    let link: USBLink
    private var transaction: UInt32 = 0
    private var pending = Data()

    init(link: USBLink) {
        self.link = link
    }

    func openSession() throws {
        transaction = 0
        do {
            _ = try call(0x1002, parameters: [1])
        } catch ToolboxError.mtp(0x1002, 0x201E) {
            _ = try call(0x1003)
            transaction = 0
            _ = try call(0x1002, parameters: [1])
        }
    }

    func closeSession() {
        if link.handle != nil {
            _ = try? call(0x1003)
        }
        link.close()
    }

    func call(
        _ operation: UInt16, parameters: [UInt32] = [], data: Data? = nil,
        upload: Upload? = nil, download: Download? = nil
    ) throws -> Reply {
        try Task.checkCancellation()
        let current = transaction
        transaction &+= 1
        var command = header(length: UInt32(headerSize + parameters.count * 4), kind: 1, code: operation, transaction: current)
        parameters.forEach { command.appendMTP($0) }
        do {
            try link.write(command)
            if let data {
                var packet = header(length: UInt32(headerSize + data.count), kind: 2, code: operation, transaction: current)
                packet.append(data)
                try link.write(packet)
                try finishOutput(length: packet.count)
            }
            if let upload {
                try send(upload, operation: operation, transaction: current)
            }
            return try receive(operation: operation, transaction: current, download: download)
        } catch let error as ToolboxError {
            if case .mtp = error { throw error }
            link.close()
            if error.needsReconnect { throw error }
            throw ToolboxError.usbLink("\(error.localizedDescription) 请重新连接 USB。")
        } catch {
            link.close()
            throw ToolboxError.usbLink("\(error.localizedDescription) 请重新连接 USB。")
        }
    }

    private func send(_ upload: Upload, operation: UInt16, transaction: UInt32) throws {
        let total = Int(upload.size) + headerSize
        var packet = header(length: UInt32(total), kind: 2, code: operation, transaction: transaction)
        var sent: UInt64 = 0
        repeat {
            try Task.checkCancellation()
            let count = min(transferChunk - packet.count, Int(upload.size - sent))
            if count > 0 {
                guard let bytes = try upload.file.read(upToCount: count), bytes.count == count else {
                    throw ToolboxError.message("传输期间源文件被截短。")
                }
                packet.append(bytes)
                sent += UInt64(count)
            }
            try link.write(packet)
            packet.removeAll(keepingCapacity: true)
            upload.progress?(TransferProgress(completed: sent, total: upload.size))
        } while sent < upload.size
        try finishOutput(length: total)
    }

    private func finishOutput(length: Int) throws {
        if length % link.outPacketSize == 0 {
            try link.write(Data())
        }
    }

    private func receive(operation: UInt16, transaction: UInt32, download: Download?) throws -> Reply {
        var data: Data?
        var receivedData = false
        while true {
            var input = MTPData(try take(headerSize))
            let length = Int(try input.u32()) - headerSize
            let kind = try input.u16()
            let code = try input.u16()
            let receivedTransaction = try input.u32()
            guard length >= 0, receivedTransaction == transaction else {
                throw ToolboxError.invalidResponse("MTP 容器长度或事务编号不匹配。")
            }
            switch kind {
            case 2 where code == operation && !receivedData:
                receivedData = true
                if let download {
                    guard UInt64(length) == download.size else {
                        throw ToolboxError.invalidResponse("设备返回的文件大小与目录记录不一致。")
                    }
                    var remaining = length
                    while remaining > 0 {
                        let bytes = try take(min(transferChunk, remaining))
                        try download.file.write(contentsOf: bytes)
                        remaining -= bytes.count
                        download.progress?(TransferProgress(completed: UInt64(length - remaining), total: download.size))
                    }
                } else {
                    guard length <= 16 * 1024 * 1024 else {
                        throw ToolboxError.invalidResponse("MTP 元数据超出处理范围。")
                    }
                    data = try take(length)
                }
            case 3:
                guard length <= 20, length % 4 == 0 else {
                    throw ToolboxError.invalidResponse("MTP 回复参数长度无效。")
                }
                var parameters = MTPData(try take(length))
                let values = try (0..<(length / 4)).map { _ in try parameters.u32() }
                guard code == 0x2001 else { throw ToolboxError.mtp(operation, code) }
                guard download == nil || receivedData else {
                    throw ToolboxError.invalidResponse("设备未返回文件内容。")
                }
                return Reply(data: data, parameters: values)
            default:
                throw ToolboxError.invalidResponse("设备返回了意外的 MTP 容器。")
            }
        }
    }

    private func take(_ count: Int) throws -> Data {
        var emptyReads = 0
        while pending.count < count {
            try Task.checkCancellation()
            let bytes = try link.read()
            emptyReads = bytes.isEmpty ? emptyReads + 1 : 0
            guard emptyReads < 8 else { throw ToolboxError.invalidResponse("USB 连续返回空数据。") }
            pending.append(bytes)
        }
        let result = Data(pending.prefix(count))
        pending.removeFirst(count)
        return result
    }

    private func header(length: UInt32, kind: UInt16, code: UInt16, transaction: UInt32) -> Data {
        var packet = Data()
        packet.appendMTP(length)
        packet.appendMTP(kind)
        packet.appendMTP(code)
        packet.appendMTP(transaction)
        return packet
    }
}
