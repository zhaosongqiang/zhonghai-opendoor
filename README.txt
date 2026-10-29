一键开门（iOS 16+）

当前状态
本工程已实现单按钮界面、离线凭据读取、已绑定门禁 RSSI 选择、EE05/EE06 普通密钥握手与开门报文。运行时没有业务服务器调用。
2026-10-29 更新：用户提供的三份现场广播均为 EE05，前 6 字节与后台三条授权 MAC 分别唯一且完全一致。VerifiedBindings.json 已绑定以下三台设备：
- 7630：20栋2单元1F单元门
- 17176：20-2单元后门
- 7631：20栋2单元-1F单元门（该广播名称为空，按 MAC 对照确认）
当前源码重新安装后，点击按钮会对附近已绑定设备执行连接、握手并尝试发送开门指令，不再是仅扫描版本。真实 GATT 握手、授权接受和物理开门效果尚未验证。
这三份采集时间不同，其 RSSI 不能用来判断当前应打开哪扇门；运行时仍按同一次扫描窗口内的信号选择。


通道兼容修复（2026-10-29，gatt-2）
用户提供的后门 GATT 报告确认：FFF1 read（2）、FFF2 read+write（10）、FFF3 read+indicate（34），有响应写入上限 512 字节。原代码只接受 writeWithoutResponse，导致在特征检查阶段拒绝该设备，尚未发出开门指令。
新版根据实际 FFF2 属性及对应写入长度上限选择模式：支持且容量足够时沿用 withoutResponse，否则支持 write 且容量足够时采用 withResponse。不会在写入失败后切换模式重试。FFF1 read、FFF3 indicate 与协议校验要求保持不变。
withResponse 的 ATT 写入确认和 FFF3 协议应答分别处理：确认本身不是开门成功，提前到达的协议应答会暂存，确认成功后才校验；写入失败、超时或取消均停止，不自动重发。
每次尝试结束写入 Documents/LastConnection.json（覆盖上一份），诊断版本为 gatt-2，包含 selectedWriteType、目标门禁、特征 UUID/属性、写入上限、写入确认/错误、失败阶段及 openCommandSent 标记。不保存特征值、密钥或开门报文。
请在 Xcode 选同一 iPhone，⌘R 覆盖安装后现场尝试。新报告中后门应显示 selectedWriteType=withResponse；如仍失败，请回传新报告。已完成代码修复、测试和编译，未观察到真实开门成功。

交互日志（2026-10-29，gatt-3）
用户要求记录 App 与门禁交互数据，现已增加 Documents/BLELogs/BLE-时间-UUID.jsonl，每次点击独立创建一个文件，不覆盖或自动删除旧记录。JSONL 每行一个事件，包含 sequence、UTC 毫秒时间戳 timestamp、elapsedMilliseconds、stage、event、direction、characteristic、byteCount、原始 hex 以及必要字段。每条事件即时追加写入；进程中断前已成功写入的记录可保留，硬件断电或存储故障不保证完整。
包含：22 字节厂家广播与 RSSI、选择的门禁、连接/服务/特征元数据、FFF3 订阅、FFF1 读取原始值、FFF2 已加密报文、FFF3 原始应答（包括格式错误的应答）、ATT 写入确认、应答暂存、协议校验、阶段变化、超时、取消与结果。
write_queued 仅代表加入队列；write_submitted 在 CoreBluetooth writeValue 调用返回后记录，不证明对端收到；write_acknowledgement 是 ATT 回调；只有 open_response_validated 才表示协议层开门成功确认。日志不采集蓝牙链路层包、iOS 内部重传或其他 App 的通信。
不记录明文 secret_key、解密后的授权 payload、会话密钥/派生密钥、账号令牌或 NSError.userInfo。原始报文只保存在本机文件，不上传。文件设置设备数据保护并排除系统备份。
取文件：覆盖安装后尝试一次，在“文件 → 我的 iPhone → 一键开门 → BLELogs”分享最新 .jsonl 文件。LastConnection.json 的 interactionLog 字段给出本次路径；interactionLogError 表示日志不完整或创建失败；无论开门成功或失败，弹窗都会独立报告日志与诊断文件保存状态。日志可由用户在文件 App 中自行清理。

打开与安装
1. 用 Xcode 打开 OneTapDoor.xcodeproj。
2. 选择 OneTapDoor target → Signing & Capabilities，选择自己的 Team；如标识冲突，修改 Bundle Identifier。
3. 连接自己的 iPhone，选择该设备，启用设备开发者模式后 Run。
4. 授予蓝牙权限。模拟器只能验证构建/界面，不能证明实体门禁功能。

数据
Resources/OfflineDoors.json 已嵌入本次账户返回的 11 条记录，不包含登录 token、手机号或验证码。文件已加入 .gitignore。按用户要求，开门密钥直接打包，持有安装包的人可以提取，因此只用于本人设备，勿公开发布此目录或 App 包。
其中 10 条 MAC 格式可用于普通协议；“大门5（111岗）”只有 6 字符标识，原样保留但排除候选。服务端没有返回有效 openData 证书，不支持 EE03/EE04 证书路径。本次三台型号已由用户广播确认，其余门禁型号未确认。
离线运行不会刷新、续期或扩大原有授权；门禁撤销或拒绝授权时显示失败。

身份映射与后续采集
三份采集及匹配依据保存在 ../../analysis/phone-door/field-captures-2026-10-28.json。iOS UUID 来自用户的这部 iPhone，只使用这些显式映射，不按名称、RSSI 或任意设备的广播前缀自动新增绑定。
本次三台广播的前 6 字节与后台 MAC 对应，但这不等于所有设备的广播格式都已验证，也不是防广播伪造的强认证。协议仍须完成原 SDK 的握手并由门禁校验授权。
扫描仍会保存 Documents/LastScan.json；但已绑定设备在附近时，点击按钮也会继续尝试开门。如果之后需要纯扫描采集，可先将 VerifiedBindings.json 另存备份，再改为 [] 并重新安装，采集完恢复配置。
更换 iPhone、清理系统蓝牙身份等情况可能导致 UUID 改变，需要重新采集并核实。

已绑定后的点击流程
扫描 3 秒 → 只保留有唯一验证绑定、合法凭据及 EE05/EE06 广播的可连接设备 → 按近 3 秒有效 RSSI 中位数选最强者（并列按 UUID 稳定排序）→ 连接 FFF0 → 订阅 FFF3 indications → 读 FFF1 → idle 握手 → 一次 FFF2 open → 检查 FFF3 的命令/校验/状态。
忙碌时按钮禁用；失败不换另一扇门，不自动重试。退到后台取消连接。指令发送后发生超时或断连时，可能门已动作，界面会提示结果未知；不能通过取消撤回已发送指令。

验证命令（在本目录运行）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project OneTapDoor.xcodeproj -scheme OneTapDoor -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project OneTapDoor.xcodeproj -scheme OneTapDoor -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
上述无签名编译不能直接安装到 iPhone；需使用自己的 Team 签名。

证据
../../analysis/phone-door/native-protocol/protocol-evidence.txt
../../analysis/phone-door/native-protocol/synthetic-vectors.json
../../analysis/phone-door/ble-identification/findings.md
测试使用合成值；原 ARM64 库由 Unicorn 离线执行，与 Swift 报文逐字节对照。原 SDK 的 CRC/握手不是新的强身份认证机制，本工程未声称提升原协议安全性。
