import XCTest
import CoreBluetooth
@testable import DoorCore

final class DoorCoreTests: XCTestCase {
    func testSuccessfulDoorResultStillShowsLogAndSummaryStorageFailures() {
        let message = InteractionLogNotice.message(result: "门禁已确认开门", reportSaved: false, hasLog: true, logFailure: "日志同步失败")
        XCTAssertTrue(message.hasPrefix("门禁已确认开门"))
        XCTAssertTrue(message.contains("诊断文件保存失败"))
        XCTAssertTrue(message.contains("交互日志未完整保存"))
        XCTAssertTrue(message.contains("日志同步失败"))
        let absent = InteractionLogNotice.message(result: "门禁已确认开门", reportSaved: true, hasLog: false, logFailure: nil)
        XCTAssertTrue(absent.contains("未能创建交互日志"))
        let complete = InteractionLogNotice.message(result: "门禁已确认开门", reportSaved: true, hasLog: true, logFailure: nil)
        XCTAssertTrue(complete.contains("BLELogs"))
        XCTAssertFalse(complete.contains("失败"))
    }
    func testInteractionLogPersistsOrderedRawPacketsBeforeClose() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = try BLEInteractionLog(directory: directory)
        XCTAssertTrue(log.record(event: "write_submitted", stage: "opening", direction: "tx", characteristic: "FFF2", bytes: [0x00, 0x0a, 0xff], fields: ["writeType": "withResponse"]))
        XCTAssertTrue(log.record(event: "value_received", stage: "opening", direction: "rx", characteristic: "FFF3", bytes: [0x01, 0x02], fields: ["doorName": "后门\n测试"]))
        let lines = try String(contentsOf: log.fileURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(first["sequence"] as? Int, 1)
        XCTAssertEqual(second["sequence"] as? Int, 2)
        XCTAssertEqual(first["hex"] as? String, "000aff")
        XCTAssertEqual(first["byteCount"] as? Int, 3)
        XCTAssertEqual(first["characteristic"] as? String, "FFF2")
        XCTAssertNotNil(first["timestamp"] as? String)
        XCTAssertNotNil(first["elapsedMilliseconds"] as? Int)
        XCTAssertEqual((second["fields"] as? [String: String])?["doorName"], "后门\n测试")
        log.close()
    }
    func testInteractionLogsDoNotOverwritePreviousAttemptAndIgnoreWritesAfterClose() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try BLEInteractionLog(directory: directory)
        XCTAssertTrue(first.record(event: "cancelled", stage: "idle"))
        first.close()
        XCTAssertFalse(first.record(event: "late_callback", stage: "idle"))
        let second = try BLEInteractionLog(directory: directory)
        defer { second.close() }
        XCTAssertNotEqual(first.fileURL, second.fileURL)
        XCTAssertEqual(try String(contentsOf: first.fileURL, encoding: .utf8).split(separator: "\n").count, 1)
    }
    func testInteractionLogSerializesErrorCodeWithoutErrorUserInfo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = try BLEInteractionLog(directory: directory)
        defer { log.close() }
        let error = NSError(domain: "CBATTErrorDomain", code: 3, userInfo: ["secret_key": "do-not-log-this"])
        XCTAssertTrue(log.record(event: "write_ack", stage: "idle", error: error))
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(row["errorDomain"] as? String, "CBATTErrorDomain")
        XCTAssertEqual(row["errorCode"] as? Int, 3)
        XCTAssertFalse(text.contains("do-not-log-this"))
    }
    func testWriteModeUsesSupportedPropertyAndItsOwnLengthLimit() {
        XCTAssertEqual(GATTCheck.writeType(properties: 10, maxWithout: 20, maxWith: 512), .withResponse)
        XCTAssertNil(GATTCheck.writeType(properties: 10, maxWithout: 512, maxWith: 17))
        XCTAssertEqual(GATTCheck.writeType(properties: 6, maxWithout: 20, maxWith: 512), .withoutResponse)
        XCTAssertNil(GATTCheck.writeType(properties: 6, maxWithout: 17, maxWith: 512))
        XCTAssertEqual(GATTCheck.writeType(properties: 14, maxWithout: 20, maxWith: 512), .withoutResponse)
        XCTAssertEqual(GATTCheck.writeType(properties: 14, maxWithout: 17, maxWith: 512), .withResponse)
        XCTAssertNil(GATTCheck.writeType(properties: 2, maxWithout: 512, maxWith: 512))
        let report = [GATTCharacteristicInfo(uuid: "FFF1", properties: 2), GATTCharacteristicInfo(uuid: "FFF2", properties: 10), GATTCharacteristicInfo(uuid: "FFF3", properties: 34)]
        XCTAssertEqual(GATTCheck.issues(characteristics: report, maxWrite: 512, maxWriteWithResponse: 17, discoveryFailed: false), [.writeLength(17)])
    }
    func testIndicationBeforeWriteACKIsBufferedUntilACKAndCannotSendAgain() throws {
        var delivery = RequestDelivery()
        try delivery.queue([1], kind: .idle)
        XCTAssertEqual(delivery.takeForWrite(canSend: true, requiresAcknowledgement: true), [1])
        XCTAssertNil(try delivery.responseIfReady([2]))
        XCTAssertThrowsError(try delivery.queue([3], kind: .open))
        XCTAssertEqual(try delivery.acknowledgeWrite(succeeded: true), [2])
        XCTAssertNil(try delivery.acknowledgeWrite(succeeded: true))
        delivery.acceptedResponse()
        try delivery.queue([3], kind: .open)
        XCTAssertEqual(delivery.takeForWrite(canSend: true, requiresAcknowledgement: true), [3])
        XCTAssertNil(delivery.takeForWrite(canSend: true, requiresAcknowledgement: true))
    }
    func testWriteACKAloneDoesNotCompleteProtocolAndLaterIndicationIsDelivered() throws {
        var delivery = RequestDelivery()
        try delivery.queue([1], kind: .open)
        _ = delivery.takeForWrite(canSend: true, requiresAcknowledgement: true)
        XCTAssertNil(try delivery.acknowledgeWrite(succeeded: true))
        XCTAssertTrue(delivery.expects(.open))
        XCTAssertThrowsError(try delivery.queue([2], kind: .open))
        XCTAssertEqual(try delivery.responseIfReady([3]), [3])
    }
    func testWriteFailureAndCancellationDiscardBufferedIndications() throws {
        var delivery = RequestDelivery()
        try delivery.queue([1], kind: .open)
        _ = delivery.takeForWrite(canSend: true, requiresAcknowledgement: true)
        XCTAssertNil(try delivery.responseIfReady([2]))
        XCTAssertThrowsError(try delivery.acknowledgeWrite(succeeded: false))
        XCTAssertFalse(delivery.expects(.open))
        XCTAssertNil(try delivery.responseIfReady([3]))
        XCTAssertTrue(delivery.failureMessage("写入失败", rejectionConfirmed: false).contains("结果未知"))
        var cancelled = RequestDelivery()
        try cancelled.queue([1], kind: .idle)
        _ = cancelled.takeForWrite(canSend: true, requiresAcknowledgement: true)
        XCTAssertNil(try cancelled.responseIfReady([2]))
        cancelled.cancel()
        XCTAssertNil(try cancelled.acknowledgeWrite(succeeded: true))
        XCTAssertNil(try cancelled.responseIfReady([3]))
        XCTAssertNil(cancelled.takeForWrite(canSend: true, requiresAcknowledgement: true))
    }
    func testWithoutResponsePathDoesNotWaitForWriteACK() throws {
        var delivery = RequestDelivery()
        try delivery.queue([1], kind: .idle)
        XCTAssertNil(try delivery.responseIfReady([2]))
        _ = delivery.takeForWrite(canSend: true)
        XCTAssertEqual(try delivery.responseIfReady([2]), [2])
    }
    func testReportedRearDoorWritePropertyIsAValidTransport() {
        let report = [
            GATTCharacteristicInfo(uuid: "FFF1", properties: 2),
            GATTCharacteristicInfo(uuid: "FFF2", properties: 10),
            GATTCharacteristicInfo(uuid: "FFF3", properties: 34)
        ]
        XCTAssertTrue(GATTCheck.issues(characteristics: report, maxWrite: 20, maxWriteWithResponse: 512, discoveryFailed: false).isEmpty)
    }
    func testGATTDiagnosticsAcceptsOriginalProfileAndFullUUIDs() {
        let characteristics = [
            GATTCharacteristicInfo(uuid: "0000FFF1-0000-1000-8000-00805F9B34FB", properties: CBCharacteristicProperties.read.rawValue),
            GATTCharacteristicInfo(uuid: "FFF2", properties: CBCharacteristicProperties.writeWithoutResponse.rawValue),
            GATTCharacteristicInfo(uuid: "FFF3", properties: CBCharacteristicProperties.indicate.rawValue)
        ]
        XCTAssertTrue(GATTCheck.issues(characteristics: characteristics, maxWrite: 18, discoveryFailed: false).isEmpty)
    }
    func testGATTDiagnosticsDistinguishesNotifyOnlyWithoutChangingAcceptance() {
        let characteristics = [
            GATTCharacteristicInfo(uuid: "FFF1", properties: CBCharacteristicProperties.read.rawValue),
            GATTCharacteristicInfo(uuid: "FFF2", properties: CBCharacteristicProperties.writeWithoutResponse.rawValue),
            GATTCharacteristicInfo(uuid: "FFF3", properties: CBCharacteristicProperties.notify.rawValue)
        ]
        XCTAssertEqual(GATTCheck.issues(characteristics: characteristics, maxWrite: 20, discoveryFailed: false), [.propertyMismatch("FFF3", "indicate", CBCharacteristicProperties.notify.rawValue)])
        XCTAssertEqual(characteristics[2].propertyNames, ["notify"])
    }
    func testGATTDiagnosticsReportsAllMissingDuplicatePropertyLengthAndDiscoveryFailures() {
        let characteristics = [
            GATTCharacteristicInfo(uuid: "FFF1", properties: 0),
            GATTCharacteristicInfo(uuid: "FFF1", properties: CBCharacteristicProperties.read.rawValue),
            GATTCharacteristicInfo(uuid: "FFF2", properties: 0)
        ]
        XCTAssertEqual(GATTCheck.issues(characteristics: characteristics, maxWrite: 17, discoveryFailed: true), [
            .discoveryFailed, .duplicate("FFF1", 2), .propertyMismatch("FFF2", "write 或 writeWithoutResponse", 0), .missing("FFF3")
        ])
        XCTAssertEqual(GATTCheck.issues(characteristics: [GATTCharacteristicInfo(uuid: "FFF1", properties: 0)], maxWrite: 20, discoveryFailed: false).first, .propertyMismatch("FFF1", "read", 0))
    }
    func testFieldCapturesResolveToTheAuthorizedDoorWhoseMACMatchesThePrefix() throws {
        // Public scan identifiers only; authorization values below are synthetic.
        let fixtures = [
            ("EA926316-23D3-AF59-4A41-183CD4F2A17B", "7630", "40:06:A0:87:2C:A1", "4006a0872ca100000000000000000000000d010205ee", "00000000000000000000"),
            ("C41EE691-E633-2925-8B4E-D9106394F287", "17176", "34:03:DE:3A:82:7F", "3403de3a827fffffffffffffffffffff000d010205ee", "ffffffffffffffffffff"),
            ("6E68BB59-1B69-F351-2F64-09BE6E57C7D0", "7631", "40:06:A0:87:2E:94", "4006a0872e9400000000000000000000000d010205ee", "00000000000000000000")
        ]
        let resource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/VerifiedBindings.json")
        let bindings = try JSONDecoder().decode([DoorBinding].self, from: Data(contentsOf: resource))
        let doors = fixtures.map { Door(id: $0.1, name: "fixture", mac: $0.2, secret: "a0a1a2a3a4a5a6a7a8a9aaab", manufacturer: "2") }
        for (uuid, doorID, _, raw, sign) in fixtures {
            let packet = bytes(raw)
            let ad = try XCTUnwrap(DoorAdvertisement(bytes: packet))
            let door = try XCTUnwrap(Identity.resolve(try XCTUnwrap(UUID(uuidString: uuid)), doors: doors, bindings: bindings))
            XCTAssertEqual(door.id, doorID)
            XCTAssertEqual(door.macBytes, Array(packet.prefix(6)))
            XCTAssertEqual(ad.model, "EE05")
            XCTAssertEqual(ad.communitySign, bytes(sign))
        }
        // Matching an advertisement prefix alone still cannot enroll a new UUID.
        XCTAssertNil(Identity.resolve(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, doors: doors, bindings: bindings))
    }
    func testOriginalNativeHandshakeAndOpenVector() throws {
        let session = try DoorSession(publicKey: bytes("000102030405060708090a0b0c0d0e0f"), seed: bytes("101112131415161718191a1b1c1d1e1f"))
        XCTAssertThrowsError(try session.open(authorization: bytes("a0a1a2a3a4a5a6a7a8a9aaab")))
        XCTAssertEqual(try session.idle(random: bytes("000102030405060708090a0b")).hex, "3ba313e7eae0cbdc821f18bb65dec868b005")
        try session.acceptHandshake(bytes("26e8d41c43ad72ad4c38b7c5fcaf98f408a9"))
        XCTAssertEqual(try session.open(authorization: bytes("a0a1a2a3a4a5a6a7a8a9aaab")).hex, "966be9777794b561d20e443f5b5d5221cfd6")
        XCTAssertThrowsError(try session.open(authorization: bytes("a0a1a2a3a4a5a6a7a8a9aaab")))
        try session.acceptOpen(bytes("34c7d2019214d022e002fc026ac1b20c786d"))
        XCTAssertThrowsError(try session.acceptOpen(bytes("34c7d2019214d022e002fc026ac1b20c786d")))
    }
    func testCRCAndAESStandardVectors() throws {
        XCTAssertEqual(Packet.crc(Array("123456789".utf8)), 0x4b37)
        XCTAssertEqual(try AES.block(bytes("00112233445566778899aabbccddeeff"), key: bytes("000102030405060708090a0b0c0d0e0f"), decrypt: false).hex, "69c4e0d86a7b0430d8cdb78070b4c55a")
    }
    func testMalformedAndWrongCommandDoNotAdvanceHandshake() throws {
        let s = try DoorSession(publicKey: bytes("000102030405060708090a0b0c0d0e0f"), seed: bytes("101112131415161718191a1b1c1d1e1f"))
        _ = try s.idle(random: Array(repeating: 0, count: 12))
        XCTAssertThrowsError(try s.acceptHandshake([0]))
        var corrupt = bytes("26e8d41c43ad72ad4c38b7c5fcaf98f408a9"); corrupt[0] ^= 1
        XCTAssertThrowsError(try s.acceptHandshake(corrupt))
        let wrong = try Packet.encode(command: 0x0202, payload: Array(repeating: 0, count: 12), key: bytes("9c54d571702cfa0f03f36215676bab78"))
        XCTAssertThrowsError(try s.acceptHandshake(wrong))
        XCTAssertThrowsError(try s.open(authorization: Array(repeating: 0, count: 12)))
    }
    func testOpenFailureAndUnrelatedResponsesAreNotSuccess() throws {
        for command: UInt16 in [0x0202, 0x0302] {
            let s = try readySession()
            _ = try s.open(authorization: Array(repeating: 0, count: 12))
            var payload = Array(repeating: UInt8(0), count: 12); payload[0] = 1
            let response = try Packet.encode(command: command, payload: payload, key: bytes("ba66f1690a4bc25e3bd945dd79aca05e"))
            XCTAssertThrowsError(try s.acceptOpen(response))
        }
    }
    func testUnknownPrefixIsNeverUsedAsMACAndBindingIsRequired() throws {
        let ad = try XCTUnwrap(DoorAdvertisement(bytes: bytes("101112131415161718191a1b1c1d1e1f0403020105ee")))
        XCTAssertEqual(ad.communitySign, bytes("161718191a1b1c1d1e1f"))
        XCTAssertEqual(ad.model, "EE05")
        let door = Door(id: "1", name: "fixture", mac: "10:11:12:13:14:15", secret: "a0a1a2a3a4a5a6a7a8a9aaab", manufacturer: "2")
        let id = UUID()
        XCTAssertNil(Identity.resolve(id, doors: [door], bindings: []))
        XCTAssertNotNil(Identity.resolve(id, doors: [door], bindings: [DoorBinding(peripheralID: id, doorID: "1", verification: "physical verification fixture")]))
        XCTAssertNil(Identity.resolve(id, doors: [door], bindings: [DoorBinding(peripheralID: id, doorID: "1", verification: "")]))
        XCTAssertNil(DoorAdvertisement(bytes: Array(repeating: 0, count: 4)))
    }
    func testInvalidCredentialAndAmbiguousBindingExcluded() {
        let id = UUID()
        let invalid = Door(id: "1", name: "fixture", mac: "123456", secret: String(repeating: "00", count: 12), manufacturer: "2")
        let bind = DoorBinding(peripheralID: id, doorID: "1", verification: "verified")
        XCTAssertNil(Identity.resolve(id, doors: [invalid], bindings: [bind]))
        let valid = Door(id: "1", name: "fixture", mac: "10:11:12:13:14:15", secret: String(repeating: "00", count: 12), manufacturer: "2")
        XCTAssertNil(Identity.resolve(id, doors: [valid], bindings: [bind, bind]))
    }
    func testStrongestSelectionIgnoresInvalidRSSIAndOldSamples() {
        var rank = SignalRanker()
        let weak = UUID(), strong = UUID(), invalid = UUID()
        rank.add(weak, rssi: -80, at: 1); rank.add(weak, rssi: -20, at: 1.1); rank.add(weak, rssi: -78, at: 1.2)
        rank.add(strong, rssi: -50, at: 1.4); rank.add(invalid, rssi: 127, at: 1.5)
        XCTAssertEqual(rank.strongest(at: 2), strong)
        XCTAssertNil(rank.strongest(at: 10))
    }
    func testQueuedWriteCannotAcceptEarlyResponseAndEmitsOnlyOnce() throws {
        var delivery = RequestDelivery()
        try delivery.queue([1, 2], kind: .idle)
        XCTAssertNil(delivery.takeForWrite(canSend: false))
        XCTAssertFalse(delivery.expects(.idle))
        XCTAssertEqual(delivery.takeForWrite(canSend: true), [1, 2])
        XCTAssertTrue(delivery.expects(.idle))
        XCTAssertNil(delivery.takeForWrite(canSend: true))
        XCTAssertThrowsError(try delivery.queue([3], kind: .open))
        delivery.acceptedResponse()
        try delivery.queue([3], kind: .open)
        XCTAssertFalse(delivery.openWasSent)
        XCTAssertFalse(delivery.expects(.open))
        XCTAssertEqual(delivery.takeForWrite(canSend: true), [3])
        XCTAssertTrue(delivery.openWasSent)
        XCTAssertTrue(delivery.expects(.open))
    }
    func testCancellationDropsPendingWriteAndLateReadinessCannotSend() throws {
        var delivery = RequestDelivery()
        try delivery.queue([1], kind: .open)
        delivery.cancel()
        XCTAssertNil(delivery.takeForWrite(canSend: true))
        XCTAssertFalse(delivery.expects(.open))
        XCTAssertFalse(delivery.openWasSent)
    }
    func testEveryUnvalidatedFailureAfterOpenReportsUnknownOutcome() throws {
        var delivery = RequestDelivery()
        XCTAssertEqual(delivery.failureMessage("CRC 错误", rejectionConfirmed: false), "CRC 错误")
        try delivery.queue([1], kind: .open)
        _ = delivery.takeForWrite(canSend: true)
        for cause in ["CRC 错误", "蓝牙已关闭", "操作已取消", "读取失败"] {
            XCTAssertTrue(delivery.failureMessage(cause, rejectionConfirmed: false).contains("开门结果未知"))
        }
        XCTAssertEqual(delivery.failureMessage("门禁拒绝", rejectionConfirmed: true), "门禁拒绝")
    }
    private func readySession() throws -> DoorSession {
        let s = try DoorSession(publicKey: bytes("000102030405060708090a0b0c0d0e0f"), seed: bytes("101112131415161718191a1b1c1d1e1f"))
        _ = try s.idle(random: Array(repeating: 0, count: 12))
        try s.acceptHandshake(bytes("26e8d41c43ad72ad4c38b7c5fcaf98f408a9")); return s
    }
    private func bytes(_ hex: String) -> [UInt8] { try! Hex.decode(hex) }
}
