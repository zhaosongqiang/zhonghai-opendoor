import Foundation
import CommonCrypto

public enum DoorError: LocalizedError {
    case invalid(String)
    case rejected(UInt8)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message; case .rejected(let status): return "门禁拒绝开门（状态 \(status)）" }
    }
    public var rejectionConfirmed: Bool { if case .rejected = self { return true }; return false }
}
public enum Hex {
    public static func decode(_ value: String) throws -> [UInt8] {
        let chars = Array(value.utf8)
        guard chars.count % 2 == 0 else { throw DoorError.invalid("十六进制数据长度错误") }
        func digit(_ c: UInt8) throws -> UInt8 {
            switch c { case 48...57: return c - 48; case 65...70: return c - 55; case 97...102: return c - 87; default: throw DoorError.invalid("十六进制数据无效") }
        }
        return try stride(from: 0, to: chars.count, by: 2).map { try digit(chars[$0]) * 16 + digit(chars[$0 + 1]) }
    }
}
public extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
public enum AES {
    public static func block(_ input: [UInt8], key: [UInt8], decrypt: Bool) throws -> [UInt8] {
        guard input.count == 16, key.count == 16 else { throw DoorError.invalid("AES 数据长度错误") }
        var output = [UInt8](repeating: 0, count: 16), written = 0
        let status = key.withUnsafeBytes { keyPtr in input.withUnsafeBytes { inPtr in output.withUnsafeMutableBytes { outPtr in
            CCCrypt(CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), keyPtr.baseAddress, 16, nil, inPtr.baseAddress, 16, outPtr.baseAddress, 16, &written)
        } } }
        guard status == kCCSuccess, written == 16 else { throw DoorError.invalid("AES 运算失败") }
        return output
    }
}
public enum Packet {
    public static func crc(_ data: [UInt8]) -> UInt16 {
        var value: UInt16 = 0xffff
        for byte in data { value ^= UInt16(byte); for _ in 0..<8 { value = value & 1 != 0 ? (value >> 1) ^ 0xa001 : value >> 1 } }
        return value
    }
    public static func encode(command: UInt16, payload: [UInt8], key: [UInt8]) throws -> [UInt8] {
        guard payload.count == 12 else { throw DoorError.invalid("报文数据长度错误") }
        let encrypted = try AES.block([0x5d, 0x32, UInt8(command & 0xff), UInt8(command >> 8)] + payload, key: key, decrypt: false)
        let check = crc(encrypted)
        return encrypted + [UInt8(check & 0xff), UInt8(check >> 8)]
    }
    public static func decode(_ data: [UInt8], key: [UInt8], expected: UInt16) throws -> [UInt8] {
        guard data.count == 18 else { throw DoorError.invalid("门禁应答长度错误") }
        let encrypted = Array(data.prefix(16))
        guard crc(encrypted) == UInt16(data[16]) | UInt16(data[17]) << 8 else { throw DoorError.invalid("门禁应答校验失败") }
        let plain = try AES.block(encrypted, key: key, decrypt: true)
        guard plain[0] == 0x5d, plain[1] == 0x32, UInt16(plain[2]) | UInt16(plain[3]) << 8 == expected else { throw DoorError.invalid("门禁应答命令或密钥不匹配") }
        return Array(plain[4..<16])
    }
}
// One session per connection. No retries or open writes after a command has been emitted.
public final class DoorSession {
    private enum Stage { case initialized, idleSent, ready, openSent, complete }
    private var stage = Stage.initialized
    private let seed: [UInt8], initialKey: [UInt8]
    private var sessionKey: [UInt8] = []
    public init(publicKey: [UInt8], seed: [UInt8]) throws {
        self.seed = seed; initialKey = try AES.block(publicKey, key: seed, decrypt: false)
    }
    public func idle(random: [UInt8]) throws -> [UInt8] {
        guard stage == .initialized else { throw DoorError.invalid("握手状态错误") }
        let result = try Packet.encode(command: 0x0101, payload: random, key: initialKey)
        stage = .idleSent; return result
    }
    public func acceptHandshake(_ packet: [UInt8]) throws {
        guard stage == .idleSent else { throw DoorError.invalid("非预期握手应答") }
        let payload = try Packet.decode(packet, key: initialKey, expected: 0x0102)
        let challenge = Array(payload.prefix(8))
        sessionKey = try AES.block(challenge + challenge.map { ~$0 }, key: Array(seed[6..<16]) + Array(seed[0..<6]), decrypt: false)
        stage = .ready
    }
    public func open(authorization: [UInt8]) throws -> [UInt8] {
        guard stage == .ready else { throw DoorError.invalid("未完成握手或开门命令已发送") }
        let result = try Packet.encode(command: 0x0201, payload: authorization, key: sessionKey)
        stage = .openSent; return result
    }
    public func acceptOpen(_ packet: [UInt8]) throws {
        guard stage == .openSent else { throw DoorError.invalid("非预期开门应答") }
        let payload = try Packet.decode(packet, key: sessionKey, expected: 0x0202)
        stage = .complete
        // Java swaps adjacent byte pairs; its status[3] is native payload[0].
        guard payload[0] == 0 else { throw DoorError.rejected(payload[0]) }
    }
}

// The CoreBluetooth adapter must take a packet immediately before writeValue, on its serial queue.
// A queued packet is not an emitted request and cannot authorize response processing.
public struct RequestDelivery {
    public enum Kind { case idle, open }
    private var pending: (bytes: [UInt8], kind: Kind)?
    private var awaiting: Kind?
    public private(set) var awaitingWriteAcknowledgement = false
    private var bufferedResponse: [UInt8]?
    public private(set) var openWasSent = false
    public init() {}
    public mutating func queue(_ packet: [UInt8], kind: Kind) throws {
        guard pending == nil, awaiting == nil else { throw DoorError.invalid("门禁写入状态错误") }
        pending = (packet, kind)
    }
    public mutating func takeForWrite(canSend: Bool, requiresAcknowledgement: Bool = false) -> [UInt8]? {
        guard canSend, let next = pending else { return nil }
        pending = nil; awaiting = next.kind
        awaitingWriteAcknowledgement = requiresAcknowledgement
        if next.kind == .open { openWasSent = true }
        return next.bytes
    }
    public func expects(_ kind: Kind) -> Bool { awaiting == kind }
    // Indications and the ATT write acknowledgement can arrive in either order.
    // Release protocol data only when the write acknowledgement has succeeded.
    public mutating func responseIfReady(_ packet: [UInt8]) throws -> [UInt8]? {
        guard awaiting != nil else { return nil }
        if awaitingWriteAcknowledgement {
            guard bufferedResponse == nil else { throw DoorError.invalid("写入确认前收到重复门禁应答") }
            bufferedResponse = packet; return nil
        }
        return packet
    }
    public mutating func acknowledgeWrite(succeeded: Bool) throws -> [UInt8]? {
        guard awaitingWriteAcknowledgement else { return nil }
        awaitingWriteAcknowledgement = false
        guard succeeded else { cancel(); throw DoorError.invalid("门禁蓝牙写入失败") }
        let response = bufferedResponse; bufferedResponse = nil
        return response
    }
    public mutating func acceptedResponse() { awaiting = nil; bufferedResponse = nil }
    public mutating func cancel() { pending = nil; awaiting = nil; awaitingWriteAcknowledgement = false; bufferedResponse = nil }
    public func failureMessage(_ message: String, rejectionConfirmed: Bool) -> String {
        guard openWasSent, !rejectionConfirmed else { return message }
        return message + "。开门指令已发出，开门结果未知；请先查看门的状态。"
    }
}
