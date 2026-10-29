import Foundation
import CoreBluetooth
import Security
import SwiftUI

final class DoorController: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published private(set) var busy = false
    @Published private(set) var label = "开门"
    @Published var message: String?
    private enum Stage { case stopped, poweringOn, scanning, connecting, services, characteristics, subscribing, publicKey, idle, opening }
    private var stage = Stage.stopped {
        didSet { logEvent("stage_changed", fields: ["from": String(describing: oldValue), "to": String(describing: stage)]) }
    }
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var timer: DispatchWorkItem?
    private var request: CBCharacteristic?, response: CBCharacteristic?, publicKey: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType?
    private var delivery = RequestDelivery()
    private var session: DoorSession?
    private var doors: [Door] = [], bindings: [DoorBinding] = []
    private var loadError: String?
    private var selected: Candidate?
    private struct Candidate { let peripheral: CBPeripheral; let door: Door; let advertisement: DoorAdvertisement }
    private var candidates: [UUID: Candidate] = [:]
    private var ranker = SignalRanker()
    private var diagnostics: [String: [String: String]] = [:]
    private var connectionReport: [String: Any] = [:]
    private var interactionLog: BLEInteractionLog?
    private let serviceUUID = CBUUID(string: "FFF0")
    private let keyUUID = CBUUID(string: "FFF1"), requestUUID = CBUUID(string: "FFF2"), responseUUID = CBUUID(string: "FFF3")
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    override init() {
        super.init()
        do {
            guard let keysURL = Bundle.main.url(forResource: "OfflineDoors", withExtension: "json"), let bindingURL = Bundle.main.url(forResource: "VerifiedBindings", withExtension: "json") else { throw DoorError.invalid("缺少离线授权文件") }
            doors = try JSONDecoder().decode([Door].self, from: Data(contentsOf: keysURL))
            bindings = try JSONDecoder().decode([DoorBinding].self, from: Data(contentsOf: bindingURL))
        } catch { loadError = "离线授权配置读取失败" }
    }
    func tap() {
        guard !busy else { return }
        guard loadError == nil else { message = loadError; return }
        interactionLog?.close(); interactionLog = nil
        connectionReport = ["diagnosticVersion": "gatt-3", "startedAt": ISO8601DateFormatter().string(from: Date())]
        do {
            guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { throw DoorError.invalid("日志目录不可用") }
            interactionLog = try BLEInteractionLog(directory: directory.appendingPathComponent("BLELogs", isDirectory: true))
            connectionReport["interactionLog"] = "BLELogs/" + (interactionLog?.fileURL.lastPathComponent ?? "")
        } catch { connectionReport["interactionLogError"] = "无法创建交互日志" }
        logEvent("attempt_started", fields: ["diagnosticVersion": "gatt-3"])
        message = nil; delivery = RequestDelivery(); busy = true; label = "准备蓝牙"; stage = .poweringOn
        ranker = SignalRanker(); candidates.removeAll(); diagnostics.removeAll()
        central?.delegate = nil
        central = CBCentralManager(delegate: self, queue: .main)
        armTimeout(15, "蓝牙准备超时，请确认蓝牙权限")
    }
    func cancelForBackground() {
        guard busy else { return }
        logEvent("cancelled", fields: ["reason": "app_backgrounded"])
        finish("操作已取消")
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central, busy else { return }
        logEvent("central_state", fields: ["rawValue": String(central.state.rawValue)])
        if central.state == .poweredOn {
            guard stage == .poweringOn else { return }
            stage = .scanning; label = "寻找门禁"
            logEvent("scan_started", fields: ["durationSeconds": "3"])
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            schedule(3) { [weak self] in self?.chooseDoor() }
        } else if central.state != .unknown && central.state != .resetting {
            finish(central.state == .unauthorized ? "请在系统设置中允许此 App 使用蓝牙" : "蓝牙不可用，请打开蓝牙后重试")
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central, stage == .scanning else { return }
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        let bytes = Array(data)
        if bytes.count == 22 {
            logEvent("advertisement", direction: "rx", bytes: bytes, fields: ["peripheralID": peripheral.identifier.uuidString, "name": advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "", "rssi": RSSI.stringValue])
            diagnostics[peripheral.identifier.uuidString] = ["peripheralID": peripheral.identifier.uuidString, "name": advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "", "rssi": RSSI.stringValue, "manufacturerData": bytes.hex]
        }
        guard let ad = DoorAdvertisement(bytes: bytes), let door = Identity.resolve(peripheral.identifier, doors: doors, bindings: bindings), (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue != false else { return }
        candidates[peripheral.identifier] = Candidate(peripheral: peripheral, door: door, advertisement: ad)
        ranker.add(peripheral.identifier, rssi: RSSI.intValue, at: now)
    }
    private func chooseDoor() {
        guard stage == .scanning else { return }
        central?.stopScan(); saveDiagnostics()
        logEvent("scan_stopped", fields: ["candidateCount": String(candidates.count)])
        guard let id = ranker.strongest(at: now), let candidate = candidates[id] else {
            finish(bindings.isEmpty ? "尚未配置经现场核实的 iPhone 蓝牙身份映射。本次仅扫描，未发送开门指令。扫描结果已保存到 App 文件。" : "未找到附近已绑定且受支持的授权门禁"); return
        }
        selected = candidate; peripheral = candidate.peripheral; candidate.peripheral.delegate = self
        connectionReport["doorID"] = candidate.door.id
        connectionReport["doorName"] = candidate.door.name
        connectionReport["peripheralID"] = candidate.peripheral.identifier.uuidString
        connectionReport["model"] = candidate.advertisement.model
        logEvent("door_selected", fields: ["doorID": candidate.door.id, "doorName": candidate.door.name, "peripheralID": candidate.peripheral.identifier.uuidString, "model": candidate.advertisement.model])
        stage = .connecting; label = "连接门禁"; armTimeout(10, "门禁连接超时")
        logEvent("connect_requested")
        central?.connect(candidate.peripheral, options: nil)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central, peripheral === self.peripheral, stage == .connecting else { return }
        logEvent("connected")
        stage = .services; armTimeout(8, "发现门禁服务超时"); peripheral.discoverServices([serviceUUID])
        logEvent("services_requested", fields: ["service": serviceUUID.uuidString])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === self.peripheral, busy else { return }
        logEvent("connect_failed", error: error); finish("连接门禁失败")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === self.peripheral, busy else { return }
        logEvent("disconnected", error: error)
        finish("门禁连接已断开")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral, stage == .services else { return }
        connectionReport["services"] = (peripheral.services ?? []).map { $0.uuid.uuidString }
        logEvent("services_discovered", fields: ["services": (peripheral.services ?? []).map { $0.uuid.uuidString }.joined(separator: ",")], error: error)
        recordDiscoveryError(error, operation: "discoverServices")
        guard error == nil, let services = peripheral.services, services.filter({ $0.uuid == serviceUUID }).count == 1, let service = services.first(where: { $0.uuid == serviceUUID }) else { finish("门禁服务不匹配"); return }
        stage = .characteristics; armTimeout(8, "发现门禁通道超时")
        // Read all characteristic metadata under FFF0 so missing/alternate channels are visible.
        peripheral.discoverCharacteristics(nil, for: service)
        logEvent("characteristics_requested", fields: ["service": service.uuid.uuidString])
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral, stage == .characteristics, service.uuid == serviceUUID else { return }
        let chars = service.characteristics ?? []
        let metadata = chars.map { GATTCharacteristicInfo(uuid: $0.uuid.uuidString, properties: $0.properties.rawValue) }
        logEvent("characteristics_discovered", fields: ["count": String(chars.count)], error: error)
        for characteristic in metadata {
            logEvent("characteristic_metadata", characteristic: characteristic.uuid, fields: ["propertiesRaw": String(characteristic.properties), "properties": characteristic.propertyNames.joined(separator: ",")])
        }
        let maximum = peripheral.maximumWriteValueLength(for: .withoutResponse)
        let maximumWithResponse = peripheral.maximumWriteValueLength(for: .withResponse)
        let issues = GATTCheck.issues(characteristics: metadata, maxWrite: maximum, maxWriteWithResponse: maximumWithResponse, discoveryFailed: error != nil)
        connectionReport["service"] = service.uuid.uuidString
        connectionReport["characteristics"] = metadata.map { ["uuid": $0.uuid, "propertiesRaw": $0.properties, "propertyNames": $0.propertyNames] as [String: Any] }
        connectionReport["maximumWriteWithoutResponse"] = maximum
        connectionReport["maximumWriteWithResponse"] = maximumWithResponse
        connectionReport["issues"] = issues.map(\.message)
        recordDiscoveryError(error, operation: "discoverCharacteristics")
        logEvent("gatt_checked", fields: ["maximumWriteWithoutResponse": String(maximum), "maximumWriteWithResponse": String(maximumWithResponse), "issues": issues.map(\.message).joined(separator: "; ")])
        guard issues.isEmpty else {
            finish("门禁蓝牙通道不兼容：\n" + issues.map(\.message).joined(separator: "\n")); return
        }
        guard let key = chars.first(where: { $0.uuid == keyUUID }),
              let write = chars.first(where: { $0.uuid == requestUUID }),
              let read = chars.first(where: { $0.uuid == responseUUID }),
              let mode = GATTCheck.writeType(properties: write.properties.rawValue, maxWithout: maximum, maxWith: maximumWithResponse) else { finish("蓝牙特征在检查后丢失"); return }
        writeType = mode
        connectionReport["selectedWriteType"] = mode == .withResponse ? "withResponse" : "withoutResponse"
        logEvent("write_type_selected", fields: ["writeType": mode == .withResponse ? "withResponse" : "withoutResponse"])
        publicKey = key; request = write; response = read; stage = .subscribing
        armTimeout(8, "订阅门禁应答超时"); peripheral.setNotifyValue(true, for: read)
        logEvent("subscribe_requested", characteristic: read.uuid.uuidString)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === response, stage == .subscribing else { return }
        logEvent("notification_state", characteristic: characteristic.uuid.uuidString, fields: ["isNotifying": String(characteristic.isNotifying)], error: error)
        guard error == nil, characteristic.isNotifying, let key = publicKey else { finish("无法订阅门禁应答"); return }
        stage = .publicKey; armTimeout(8, "读取门禁握手数据超时"); peripheral.readValue(for: key)
        logEvent("read_requested", direction: "tx", characteristic: key.uuid.uuidString)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, busy else { return }
        // Record raw bytes before parsing so malformed replies can be investigated.
        logEvent("value_received", direction: "rx", characteristic: characteristic.uuid.uuidString,
                 bytes: error == nil ? characteristic.value.map { Array($0) } : nil, error: error)
        do {
            if characteristic === publicKey && stage == .publicKey {
                guard error == nil, let value = characteristic.value, let selected, let mac = selected.door.macBytes else { throw DoorError.invalid("读取门禁握手数据失败") }
                let s = try DoorSession(publicKey: Array(value), seed: mac + selected.advertisement.communitySign)
                session = s
                var random = [UInt8](repeating: 0, count: 12)
                guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw DoorError.invalid("随机数生成失败") }
                let packet = try s.idle(random: random)
                stage = .idle; label = "验证门禁"; armTimeout(8, "门禁握手超时"); try send(packet, kind: .idle)
            } else if characteristic === response && (stage == .idle || stage == .opening) {
                guard delivery.expects(stage == .idle ? .idle : .open) else { logEvent("response_ignored", fields: ["reason": "no_emitted_request"]); return }
                guard error == nil, let value = characteristic.value else { throw DoorError.invalid("门禁应答读取失败") }
                if let packet = try delivery.responseIfReady(Array(value)) { try processProtocolResponse(packet) }
                else { logEvent("response_buffered", fields: ["reason": "awaiting_write_acknowledgement"]) }
            }
        } catch { finish(error.localizedDescription, rejectionConfirmed: (error as? DoorError)?.rejectionConfirmed ?? false) }
    }
    private func processProtocolResponse(_ packet: [UInt8]) throws {
        guard let session else { throw DoorError.invalid("门禁会话不可用") }
        if stage == .idle {
            try session.acceptHandshake(packet)
            logEvent("handshake_validated")
            delivery.acceptedResponse()
            guard let authorization = selected?.door.authorization else { throw DoorError.invalid("离线授权无效") }
            let request = try session.open(authorization: authorization)
            stage = .opening; label = "正在开门"; armTimeout(8, "门禁应答超时")
            try send(request, kind: .open)
        } else if stage == .opening {
            try session.acceptOpen(packet)
            logEvent("open_response_validated", fields: ["status": "success"])
            finish(nil, success: true)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === request, busy,
              writeType == .withResponse, delivery.awaitingWriteAcknowledgement else { return }
        connectionReport["lastWriteAcknowledgement"] = ["stage": String(describing: stage), "succeeded": error == nil]
        logEvent("write_acknowledgement", direction: "rx", characteristic: characteristic.uuid.uuidString, fields: ["succeeded": String(error == nil)], error: error)
        if let error {
            let nsError = error as NSError
            connectionReport["writeError"] = ["domain": nsError.domain, "code": nsError.code]
        }
        do {
            if let packet = try delivery.acknowledgeWrite(succeeded: error == nil) { try processProtocolResponse(packet) }
        } catch { finish(error.localizedDescription, rejectionConfirmed: (error as? DoorError)?.rejectionConfirmed ?? false) }
    }
    private func send(_ packet: [UInt8], kind: RequestDelivery.Kind) throws {
        guard let peripheral, request != nil, let writeType else { throw DoorError.invalid("门禁写入通道不可用") }
        guard packet.count <= peripheral.maximumWriteValueLength(for: writeType) else { throw DoorError.invalid("门禁写入长度不足") }
        try delivery.queue(packet, kind: kind)
        logEvent("write_queued", characteristic: request?.uuid.uuidString, fields: ["command": kind == .idle ? "idle" : "open", "byteCount": String(packet.count)])
        drainWrite()
    }
    private func drainWrite() {
        guard busy, let peripheral, let request, let writeType,
              let bytes = delivery.takeForWrite(canSend: writeType == .withResponse || peripheral.canSendWriteWithoutResponse, requiresAcknowledgement: writeType == .withResponse) else { return }
        peripheral.writeValue(Data(bytes), for: request, type: writeType)
        logEvent("write_submitted", direction: "tx", characteristic: request.uuid.uuidString, bytes: bytes, fields: ["writeType": writeType == .withResponse ? "withResponse" : "withoutResponse", "command": stage == .idle ? "idle" : "open"])
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === self.peripheral, writeType == .withoutResponse, stage == .idle || stage == .opening else { return }
        logEvent("write_without_response_ready")
        drainWrite()
    }
    private func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) {
        timer?.cancel()
        let work = DispatchWorkItem(block: action); timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func armTimeout(_ seconds: TimeInterval, _ text: String) {
        schedule(seconds) { [weak self] in
            guard let self, self.busy else { return }
            self.logEvent("timeout", fields: ["reason": text, "seconds": String(seconds)])
            self.finish(text)
        }
    }
    private func finish(_ error: String?, success: Bool = false, rejectionConfirmed: Bool = false) {
        let failure = error.map { delivery.failureMessage($0, rejectionConfirmed: rejectionConfirmed) }
        connectionReport["lastStage"] = String(describing: stage)
        connectionReport["openCommandSent"] = delivery.openWasSent
        connectionReport["result"] = success ? "confirmedOpen" : "failed"
        connectionReport["failure"] = failure
        logEvent("attempt_finished", fields: ["result": success ? "confirmedOpen" : "failed", "reason": failure ?? "", "openCommandSubmitted": String(delivery.openWasSent)])
        delivery.cancel()
        timer?.cancel(); timer = nil; stage = .stopped; central?.stopScan()
        if let peripheral {
            logEvent("disconnect_requested")
            peripheral.delegate = nil; central?.cancelPeripheralConnection(peripheral)
        }
        interactionLog?.close()
        if let failure = interactionLog?.lastFailure { connectionReport["interactionLogError"] = failure }
        interactionLog = nil
        let reportSaved = saveConnectionReport()
        peripheral = nil; request = nil; response = nil; publicKey = nil; writeType = nil; session = nil; selected = nil
        candidates.removeAll(); ranker = SignalRanker(); busy = false; label = "开门"
        message = InteractionLogNotice.message(result: success ? "门禁已确认开门" : (failure ?? "操作结束"),
                                               reportSaved: reportSaved,
                                               hasLog: connectionReport["interactionLog"] != nil,
                                               logFailure: connectionReport["interactionLogError"] as? String)
        if success { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }
    private func logEvent(_ event: String, direction: String? = nil, characteristic: String? = nil,
                          bytes: [UInt8]? = nil, fields: [String: String] = [:], error: Error? = nil) {
        interactionLog?.record(event: event, stage: String(describing: stage), direction: direction,
                               characteristic: characteristic, bytes: bytes, fields: fields, error: error)
    }
    private func recordDiscoveryError(_ error: Error?, operation: String) {
        guard let error else { return }
        let nsError = error as NSError
        connectionReport["discoveryError"] = ["operation": operation, "domain": nsError.domain, "code": nsError.code]
    }
    private func saveConnectionReport() -> Bool {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        connectionReport["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        do {
            let data = try JSONSerialization.data(withJSONObject: connectionReport, options: [.prettyPrinted, .sortedKeys])
            var url = directory.appendingPathComponent("LastConnection.json")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
            return true
        } catch { return false }
    }
    private func saveDiagnostics() {
        // Local discovery only, no authorization keys, account data, or business network calls.
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let report: [String: Any] = ["capturedAt": ISO8601DateFormatter().string(from: Date()), "devices": Array(diagnostics.values)]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            var url = directory.appendingPathComponent("LastScan.json")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
        } catch { /* Diagnostics are optional; never log credential-bearing state. */ }
    }
}
