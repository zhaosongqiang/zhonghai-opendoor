import Foundation

// Used from the controller's serial main queue. Only explicit transport metadata is accepted;
// never pass Door/Session objects, authorization payloads, or derived encryption keys here.
public final class BLEInteractionLog {
    public let fileURL: URL
    public private(set) var lastFailure: String?
    private let sessionID = UUID().uuidString
    private let started = ProcessInfo.processInfo.systemUptime
    private let formatter: ISO8601DateFormatter
    private let encoder = JSONEncoder()
    private var handle: FileHandle?
    private var sequence = 0

    private struct Entry: Encodable {
        let schemaVersion: Int
        let sessionID: String
        let sequence: Int
        let timestamp: String
        let elapsedMilliseconds: Int
        let event: String
        let stage: String
        let direction: String?
        let characteristic: String?
        let byteCount: Int?
        let hex: String?
        let fields: [String: String]
        let errorDomain: String?
        let errorCode: Int?
    }
    public init(directory: URL) throws {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        fileURL = directory.appendingPathComponent("BLE-\(timestamp)-\(sessionID).jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.withoutOverwriting]
        #if os(iOS)
        options.insert(.completeFileProtection)
        #endif
        try Data().write(to: fileURL, options: options)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            var url = fileURL
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            handle = try FileHandle(forWritingTo: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }
    @discardableResult
    public func record(event: String, stage: String, direction: String? = nil,
                       characteristic: String? = nil, bytes: [UInt8]? = nil,
                       fields: [String: String] = [:], error: Error? = nil) -> Bool {
        guard let handle, lastFailure == nil else { return false }
        sequence += 1
        let nsError = error.map { $0 as NSError }
        let entry = Entry(schemaVersion: 1, sessionID: sessionID, sequence: sequence,
                          timestamp: formatter.string(from: Date()),
                          elapsedMilliseconds: Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
                          event: event, stage: stage, direction: direction, characteristic: characteristic,
                          byteCount: bytes?.count, hex: bytes?.hex, fields: fields,
                          errorDomain: nsError?.domain, errorCode: nsError?.code)
        do {
            var data = try encoder.encode(entry); data.append(0x0a)
            try handle.write(contentsOf: data)
            return true
        } catch {
            let nsError = error as NSError
            lastFailure = "日志写入失败（\(nsError.domain)/\(nsError.code)）"
            return false
        }
    }
    public func close() {
        guard let file = handle else { return }
        handle = nil
        do { try file.synchronize() } catch { lastFailure = lastFailure ?? "日志同步失败" }
        do { try file.close() } catch { lastFailure = lastFailure ?? "日志关闭失败" }
    }
    deinit { try? handle?.close() }
}

public enum InteractionLogNotice {
    public static func message(result: String, reportSaved: Bool, hasLog: Bool, logFailure: String?) -> String {
        let report = reportSaved ? "诊断已保存：LastConnection.json" : "诊断文件保存失败，请保留此完整提示。"
        let trace: String
        if let logFailure { trace = "交互日志未完整保存：" + logFailure }
        else if !hasLog { trace = "未能创建交互日志。" }
        else { trace = "交互日志已保存到 BLELogs 文件夹。" }
        return result + "\n\n" + report + "\n" + trace
    }
}
