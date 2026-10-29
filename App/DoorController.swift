import Foundation
import CoreBluetooth
import Security
import SwiftUI

final class DoorController: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published private(set) var busy = false
    @Published private(set) var label = "开门"
    @Published var message: String?
    private enum Stage { case stopped, poweringOn, scanning, connecting, services, characteristics, subscribing, publicKey, idle, opening }
    private var stage = Stage.stopped
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
    private var scanStartedAt: TimeInterval?
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
        message = nil; delivery = RequestDelivery(); busy = true; label = "准备蓝牙"; stage = .poweringOn
        ranker = SignalRanker(); scanStartedAt = nil; candidates.removeAll()
        central?.delegate = nil
        central = CBCentralManager(delegate: self, queue: .main)
        armTimeout(15, "蓝牙准备超时，请确认蓝牙权限")
    }
    func cancelForBackground() {
        guard busy else { return }
        finish("操作已取消")
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central, busy else { return }
        if central.state == .poweredOn {
            guard stage == .poweringOn else { return }
            stage = .scanning; label = "寻找门禁"
            scanStartedAt = now
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
        guard let ad = DoorAdvertisement(bytes: bytes), let door = Identity.resolve(peripheral.identifier, doors: doors, bindings: bindings), (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue != false else { return }
        candidates[peripheral.identifier] = Candidate(peripheral: peripheral, door: door, advertisement: ad)
        let observedAt = now
        ranker.add(peripheral.identifier, rssi: RSSI.intValue, at: observedAt)
        if let scanStartedAt, ranker.canFinishEarly(at: observedAt, scanStartedAt: scanStartedAt) {
            chooseDoor()
        }
    }
    private func chooseDoor() {
        guard stage == .scanning else { return }
        timer?.cancel(); timer = nil
        central?.stopScan()
        guard let id = ranker.strongest(at: now), let candidate = candidates[id] else {
            finish(bindings.isEmpty ? "尚未配置经现场核实的 iPhone 蓝牙身份映射。本次仅扫描，未发送开门指令。" : "未找到附近已绑定且受支持的授权门禁"); return
        }
        selected = candidate; peripheral = candidate.peripheral; candidate.peripheral.delegate = self
        stage = .connecting; label = "连接门禁"; armTimeout(10, "门禁连接超时")
        central?.connect(candidate.peripheral, options: nil)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central, peripheral === self.peripheral, stage == .connecting else { return }
        stage = .services; armTimeout(8, "发现门禁服务超时"); peripheral.discoverServices([serviceUUID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === self.peripheral, busy else { return }
        finish("连接门禁失败")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === self.peripheral, busy else { return }
        finish("门禁连接已断开")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral, stage == .services else { return }
        guard error == nil, let services = peripheral.services, services.filter({ $0.uuid == serviceUUID }).count == 1, let service = services.first(where: { $0.uuid == serviceUUID }) else { finish("门禁服务不匹配"); return }
        stage = .characteristics; armTimeout(8, "发现门禁通道超时")
        // Read all characteristic metadata under FFF0 so missing/alternate channels are visible.
        peripheral.discoverCharacteristics(nil, for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral, stage == .characteristics, service.uuid == serviceUUID else { return }
        let chars = service.characteristics ?? []
        let metadata = chars.map { GATTCharacteristicInfo(uuid: $0.uuid.uuidString, properties: $0.properties.rawValue) }
        let maximum = peripheral.maximumWriteValueLength(for: .withoutResponse)
        let maximumWithResponse = peripheral.maximumWriteValueLength(for: .withResponse)
        let issues = GATTCheck.issues(characteristics: metadata, maxWrite: maximum, maxWriteWithResponse: maximumWithResponse, discoveryFailed: error != nil)
        guard issues.isEmpty else {
            finish("门禁蓝牙通道不兼容：\n" + issues.map(\.message).joined(separator: "\n")); return
        }
        guard let key = chars.first(where: { $0.uuid == keyUUID }),
              let write = chars.first(where: { $0.uuid == requestUUID }),
              let read = chars.first(where: { $0.uuid == responseUUID }),
              let mode = GATTCheck.writeType(properties: write.properties.rawValue, maxWithout: maximum, maxWith: maximumWithResponse) else { finish("蓝牙特征在检查后丢失"); return }
        writeType = mode
        publicKey = key; request = write; response = read; stage = .subscribing
        armTimeout(8, "订阅门禁应答超时"); peripheral.setNotifyValue(true, for: read)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === response, stage == .subscribing else { return }
        guard error == nil, characteristic.isNotifying, let key = publicKey else { finish("无法订阅门禁应答"); return }
        stage = .publicKey; armTimeout(8, "读取门禁握手数据超时"); peripheral.readValue(for: key)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, busy else { return }
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
                guard delivery.expects(stage == .idle ? .idle : .open) else { return }
                guard error == nil, let value = characteristic.value else { throw DoorError.invalid("门禁应答读取失败") }
                if let packet = try delivery.responseIfReady(Array(value)) { try processProtocolResponse(packet) }
            }
        } catch { finish(error.localizedDescription, rejectionConfirmed: (error as? DoorError)?.rejectionConfirmed ?? false) }
    }
    private func processProtocolResponse(_ packet: [UInt8]) throws {
        guard let session else { throw DoorError.invalid("门禁会话不可用") }
        if stage == .idle {
            try session.acceptHandshake(packet)
            delivery.acceptedResponse()
            guard let authorization = selected?.door.authorization else { throw DoorError.invalid("离线授权无效") }
            let request = try session.open(authorization: authorization)
            stage = .opening; label = "正在开门"; armTimeout(8, "门禁应答超时")
            try send(request, kind: .open)
        } else if stage == .opening {
            try session.acceptOpen(packet)
            finish(nil, success: true)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === request, busy,
              writeType == .withResponse, delivery.awaitingWriteAcknowledgement else { return }
        do {
            if let packet = try delivery.acknowledgeWrite(succeeded: error == nil) { try processProtocolResponse(packet) }
        } catch { finish(error.localizedDescription, rejectionConfirmed: (error as? DoorError)?.rejectionConfirmed ?? false) }
    }
    private func send(_ packet: [UInt8], kind: RequestDelivery.Kind) throws {
        guard let peripheral, request != nil, let writeType else { throw DoorError.invalid("门禁写入通道不可用") }
        guard packet.count <= peripheral.maximumWriteValueLength(for: writeType) else { throw DoorError.invalid("门禁写入长度不足") }
        try delivery.queue(packet, kind: kind)
        drainWrite()
    }
    private func drainWrite() {
        guard busy, let peripheral, let request, let writeType,
              let bytes = delivery.takeForWrite(canSend: writeType == .withResponse || peripheral.canSendWriteWithoutResponse, requiresAcknowledgement: writeType == .withResponse) else { return }
        peripheral.writeValue(Data(bytes), for: request, type: writeType)
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === self.peripheral, writeType == .withoutResponse, stage == .idle || stage == .opening else { return }
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
            self.finish(text)
        }
    }
    private func finish(_ error: String?, success: Bool = false, rejectionConfirmed: Bool = false) {
        let failure = error.map { delivery.failureMessage($0, rejectionConfirmed: rejectionConfirmed) }
        delivery.cancel()
        timer?.cancel(); timer = nil; stage = .stopped; central?.stopScan()
        if let peripheral {
            peripheral.delegate = nil; central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil; request = nil; response = nil; publicKey = nil; writeType = nil; session = nil; selected = nil
        candidates.removeAll(); ranker = SignalRanker(); scanStartedAt = nil; busy = false; label = "开门"
        message = success ? "门禁已确认开门" : (failure ?? "操作结束")
        if success { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }
}
