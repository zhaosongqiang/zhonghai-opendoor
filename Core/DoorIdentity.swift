import Foundation
import CoreBluetooth

public struct Door: Codable {
    public let id: String, name: String, mac: String, secret: String, manufacturer: String
    public init(id: String, name: String, mac: String, secret: String, manufacturer: String) { self.id = id; self.name = name; self.mac = mac; self.secret = secret; self.manufacturer = manufacturer }
    public var macBytes: [UInt8]? {
        let pieces = mac.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 6, pieces.allSatisfy({ $0.count == 2 }) else { return nil }
        return try? Hex.decode(pieces.joined())
    }
    public var authorization: [UInt8]? { guard let b = try? Hex.decode(secret), b.count == 12 else { return nil }; return b }
    public var supported: Bool { manufacturer == "2" && macBytes?.count == 6 && authorization != nil }
}
public struct DoorBinding: Codable {
    public let peripheralID: UUID, doorID: String, verification: String
    public init(peripheralID: UUID, doorID: String, verification: String) { self.peripheralID = peripheralID; self.doorID = doorID; self.verification = verification }
}
public enum Identity {
    public static func resolve(_ peripheral: UUID, doors: [Door], bindings: [DoorBinding]) -> Door? {
        let matched = bindings.filter { $0.peripheralID == peripheral }
        guard matched.count == 1, let binding = matched.first, !binding.verification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let records = doors.filter { $0.id == binding.doorID }
        guard records.count == 1, let door = records.first, door.supported else { return nil }
        return door
    }
}
public struct DoorAdvertisement {
    public let communitySign: [UInt8], model: String
    public init?(bytes: [UInt8]) {
        // As delivered by CoreBluetooth, including the manufacturer prefix. Never interpret that prefix as a MAC.
        guard bytes.count == 22 else { return nil }
        let model = Array(bytes[20..<22].reversed()).hex.uppercased()
        guard model == "EE05" || model == "EE06" else { return nil }
        self.model = model; communitySign = Array(bytes[6..<16])
    }
}
public struct SignalRanker {
    private struct Sample { let rssi: Int; let time: TimeInterval }
    private var samples: [UUID: [Sample]] = [:]
    public init() {}
    public mutating func add(_ id: UUID, rssi: Int, at time: TimeInterval) {
        guard (-126 ... -1).contains(rssi) else { return }
        var values = (samples[id] ?? []).filter { time - $0.time <= 3 }
        values.append(Sample(rssi: rssi, time: time)); samples[id] = Array(values.suffix(30))
    }
    public func strongest(at time: TimeInterval) -> UUID? {
        samples.compactMap { id, samples -> (UUID, Int)? in
            let values = samples.filter { time - $0.time <= 3 && time >= $0.time }.map(\.rssi).sorted()
            guard !values.isEmpty else { return nil }
            return (id, values[values.count / 2])
        }.sorted { $0.1 == $1.1 ? $0.0.uuidString < $1.0.uuidString : $0.1 > $1.1 }.first?.0
    }
}

// Select only a write type advertised by FFF2; retain the original read/indicate requirements.
// UUID/property metadata only; this diagnostic model never holds characteristic values or keys.
public struct GATTCharacteristicInfo: Codable {
    public let uuid: String, properties: UInt
    public init(uuid: String, properties: UInt) { self.uuid = uuid; self.properties = properties }
    public var propertyNames: [String] {
        let flags = CBCharacteristicProperties(rawValue: properties)
        let names: [(CBCharacteristicProperties, String)] = [
            (.broadcast, "broadcast"), (.read, "read"), (.writeWithoutResponse, "writeWithoutResponse"),
            (.write, "write"), (.notify, "notify"), (.indicate, "indicate"),
            (.authenticatedSignedWrites, "authenticatedSignedWrites"), (.extendedProperties, "extendedProperties"),
            (.notifyEncryptionRequired, "notifyEncryptionRequired"), (.indicateEncryptionRequired, "indicateEncryptionRequired")
        ]
        return names.compactMap { flags.contains($0.0) ? $0.1 : nil }
    }
}
public enum GATTIssue: Equatable {
    case discoveryFailed
    case missing(String)
    case duplicate(String, Int)
    case propertyMismatch(String, String, UInt)
    case writeLength(Int)
    public var message: String {
        switch self {
        case .discoveryFailed: return "蓝牙特征发现回调报错"
        case .missing(let uuid): return "缺少 \(uuid) 特征"
        case .duplicate(let uuid, let count): return "\(uuid) 特征重复（\(count) 个）"
        case .propertyMismatch(let uuid, let required, let actual):
            let names = GATTCharacteristicInfo(uuid: uuid, properties: actual).propertyNames.joined(separator: ", ")
            return "\(uuid) 缺少 \(required) 属性；实际：\(names.isEmpty ? "无" : names)（0x\(String(actual, radix: 16))）"
        case .writeLength(let maximum): return "可用写入方式最多 \(maximum) 字节，需要至少 18 字节"
        }
    }
}
public enum GATTCheck {
    public static func writeType(properties: UInt, maxWithout: Int, maxWith: Int) -> CBCharacteristicWriteType? {
        let flags = CBCharacteristicProperties(rawValue: properties)
        if flags.contains(.writeWithoutResponse), maxWithout >= 18 { return .withoutResponse }
        if flags.contains(.write), maxWith >= 18 { return .withResponse }
        return nil
    }
    public static func issues(characteristics: [GATTCharacteristicInfo], maxWrite: Int, maxWriteWithResponse: Int = 0, discoveryFailed: Bool) -> [GATTIssue] {
        var result: [GATTIssue] = discoveryFailed ? [.discoveryFailed] : []
        let expected: [(String, CBCharacteristicProperties, String)] = [
            ("FFF1", .read, "read"), ("FFF2", .writeWithoutResponse, "write 或 writeWithoutResponse"), ("FFF3", .indicate, "indicate")
        ]
        for (uuid, flag, name) in expected {
            let matches = characteristics.filter { CBUUID(string: $0.uuid) == CBUUID(string: uuid) }
            if matches.isEmpty { result.append(.missing(uuid)) }
            else if matches.count != 1 { result.append(.duplicate(uuid, matches.count)) }
            else {
                let raw = matches[0].properties
                let flags = CBCharacteristicProperties(rawValue: raw)
                if uuid == "FFF2" {
                    if !flags.contains(.write), !flags.contains(.writeWithoutResponse) {
                        result.append(.propertyMismatch(uuid, name, raw))
                    } else if writeType(properties: raw, maxWithout: maxWrite, maxWith: maxWriteWithResponse) == nil {
                        let maximum = max(flags.contains(.writeWithoutResponse) ? maxWrite : 0, flags.contains(.write) ? maxWriteWithResponse : 0)
                        result.append(.writeLength(maximum))
                    }
                } else if !flags.contains(flag) { result.append(.propertyMismatch(uuid, name, raw)) }
            }
        }
        return result
    }
}
