一键开门（iOS 16+）

当前版本
界面为中央蓝色圆形按钮，点击后打开当前扫描中信号最强的一扇已绑定授权门禁。离线凭据已内置，运行时不调用业务服务器。
按用户最新要求，已彻底移除文件日志及诊断写入：不创建 BLELogs，不写 LastConnection.json、LastScan.json，也不把报文输出到控制台或其他日志文件。界面继续显示开门成功、失败或结果未知的提示。
旧版本在手机上生成的日志、用户提供到本目录的历史日志不会被自动删除；需要时可在“文件”App 中手动清理。文件共享设置保留，方便处理旧文件。

安装更新
1. 用 Xcode 打开 OneTapDoor.xcodeproj。
2. 保留现有 Signing & Capabilities 中的 Team 和 Bundle Identifier。
3. 选择此前采集 UUID 的同一 iPhone，按 ⌘R 覆盖安装。
4. 授予蓝牙权限。模拟器无法验证实际门禁功能。

授权与设备
Resources/OfflineDoors.json 内置账户返回的 11 条记录，无登录 token、手机号或验证码。按用户要求，授权密钥直接打包；该私有资源已加入 .gitignore。
Resources/VerifiedBindings.json 绑定三台已对照广播和后台 MAC 的门禁：
- 7630：20栋2单元1F单元门
- 17176：20-2单元后门
- 7631：20栋2单元-1F单元门
用户已确认开门成功，历史四次日志覆盖这三台 EE05 门禁并均收到协议成功应答。
iOS UUID 绑定针对采集时的 iPhone，换设备或 UUID 改变后需要重新核实。其余门禁不自动加入候选；6 字符 MAC 记录及缺少证书的 EE03/EE04 路径不支持。

扫描与开门
采用 1～3 秒自适应扫描，按有效 RSSI 中位数排序。同一设备不足 80ms 的重复回调不重复计入权重。
提前结束要求至少扫描 1 秒，所有已观察到的授权候选都有至少 3 个独立有效样本、跨度 >=0.4 秒、最新样本 <=0.35 秒、首样本已观察 >=0.6 秒。领先目标中位数 >=-80dBm，多门时领先第二名 >=8dB。条件不足仍扫描到 3 秒。
提前停止可能错过更晚才广播的设备，不保证等同于完整 3 秒的设备集合。不缓存上次目标、不复用握手密钥。
流程：扫描选择 → 连接 FFF0 → 订阅 FFF3 → 读 FFF1 → idle 握手 → 发送一次 FFF2 open → 验证 FFF3 协议成功应答。
FFF2 按实际属性和长度上限选择 withoutResponse 或 withResponse。有响应写入时，ATT 确认与门禁协议应答分别处理；确认本身不代表开门成功。写入失败不切换模式重试。
忙碌时按钮禁用，失败不换门、不自动重发，退到后台取消。已经提交的开门指令不可撤回；结果不确定时界面会提示先检查门状态。

性能证据
旧版四次实测总耗时 4.167–4.327 秒，其中扫描 3.145–3.163 秒、实际连接 0.141–0.262 秒。
新选择逻辑回放旧广播，扫描可在 1.001–1.147 秒结束且仍选择同一扇门。按后续耗时不变估算总耗时 2.065–2.215 秒；这是回放估算，优化版实际耗时需现场验证。移除日志后不再自动采集耗时文件。
回放资料：../../analysis/phone-door/scan-replay/README.txt
协议证据：../../analysis/phone-door/native-protocol/protocol-evidence.txt

验证命令（本目录）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project OneTapDoor.xcodeproj -scheme OneTapDoor -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
无签名编译只验证构建；安装到 iPhone 需通过 Xcode 使用自己的 Team 签名。
