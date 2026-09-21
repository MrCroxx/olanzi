# 09 · 原生 macOS App

> 🌐 [English](09-native-macos.md)

> 📚 文档集：[README](../README.zh.md) · [01 职责边界](01-ulanzi-studio-scope.zh.md) · [02 协议](02-vibekey-protocol.zh.md) · [03 工具手册](03-tool-manual.zh.md) · [04 方法论](04-methodology.zh.md) · [05 验证记录](05-verification-log.zh.md) · [06 旧原型](06-local-workspace.zh.md) · [07 心跳](07-heartbeat-investigation.zh.md) · [08 Mac Fn](08-mac-fn.zh.md) · **09 原生 macOS** · [10 输入运行时](10-input-runtime.zh.md)

## 1. 当前产品入口

Olanzi 的主应用是原生 macOS 菜单栏 App。键位配置使用完整 SwiftUI 界面，菜单栏生命周期由 AppKit 管理，设备通信通过 Swift 直接调用 IOKit 与 CoreGraphics。运行 App 不需要 Python 进程、浏览器页面或本地 HTTP 服务。

产品仍定位为可扩展设备模块的轻量 Studio 替代客户端。首期范围是 AU05 的三个按键和三个旋钮动作、后台心跳，以及按已确认设备映射执行的普通键与 Fn 主机转发。其他固件功能需要独立验证协议；逆向命令表里存在命令，并不意味着可以安全开放。

| 组件 | 职责 |
|---|---|
| `native/Package.swift` | Swift 包；最低 macOS 14、Swift 6 工具链、Swift 5 语言模式 |
| `native/Sources/OlanziCore/` | TEA 帧处理、IOKit 传输、设备状态、CoreGraphics Fn 事件、专用后台线程 |
| `native/Sources/OlanziApp/` | SwiftUI 键位窗口、应用状态、AppKit 菜单栏 |
| `native/Tests/` | 原生核心回归测试 |
| `tools/build-macos.sh` | 构建打包 `build/Olanzi.app`，默认 debug |
| 旧 Python 与 `web/` 源码 | 保留的原型与研究工具，不是原生 App 的运行时 |

## 2. 构建与启动

使用 macOS 14 或更新版本，以及 Swift 6 工具链。从仓库根目录运行：

```bash
make dev
```

`make dev` 编译并打开 `build/Olanzi.app` 下的 Debug 应用包。打开应用包即可使用原生窗口与菜单栏；这条启动路径不包含 Python daemon 命令或浏览器 URL。

其他入口：`make build` 只编译 Debug，`make release` 编译、签名 Release 并打包 DMG，不启动应用，`make test` 运行 Swift 测试，`make check-docs` 校验双语文档。两种构建共用 `build/Olanzi.app` 输出路径。若 Olanzi 已在运行，先从菜单栏退出再执行 `make dev`，确保启动新编译的版本；`open` 不会重启已有进程。

构建默认使用 Keychain 中唯一有效的代码签名身份。有多个时需显式选择；没有时会警告并退回临时签名。Debug 和 Release 应沿用同一身份，让重新编译后的签名要求保持稳定。本地自签名证书适合本地开发，不等于 Apple Developer 分发证书或公证。

```bash
make dev OLANZI_SIGNING_IDENTITY="Digger Local Signing"
```

变量也支持证书 SHA-1 指纹，或使用 `-` 显式选择临时签名。签名直接使用 Keychain 中的私钥，不导出私钥。macOS 可能要求允许 `codesign` 访问该密钥。

一步生成已签名的 Release 应用和可安装磁盘映像：

```bash
make release
# Equivalent alias
make dmg
# Explicit signing identity
make release OLANZI_SIGNING_IDENTITY="Digger Local Signing"
```

产物为 `build/Olanzi.app` 和 `build/Olanzi-<version>-<arch>.dmg`（目前 Apple Silicon 上为 `Olanzi-0.1.0-arm64.dmg`）。架构从编译后的可执行文件获取，不会自动生成通用二进制。DMG 内含应用与 Applications 快捷入口。打开后，将 Olanzi 拖入 Applications，再启动安装后的副本。替换前请退出正在运行的副本。

`tools/package-dmg.sh` 打包已有应用；通常应使用 `make release`，保证先重新构建。打包会用 App 的证书签名 DMG，校验映像校验和、只读挂载并检查包内应用签名与文件内容、检查 Applications 链接，卸载后才输出最终产物。临时文件自动清理；若卸载失败，则保留供恢复使用。不导出私钥。本地证书签名不等于 Apple 公证。

不接触真实硬件的隔离 UI 开发可使用：

```bash
swift run --package-path native Olanzi --demo
```

演示模式必须与真实设备会话在界面中明确区分。它模拟设备行为，不打开真实 HID 接口，也不注入系统 Fn 事件。演示预览成功不能证明真实设备写入或系统动作成功。

连接真实硬件前，退出官方 Studio，并停止仍在占用设备的旧工具。原生 App 不会替你杀死这些进程。插入接收器、打开 Vibe Key，再检查 App 的连接状态；接收器存在和设备本体在线是两种不同观察。

## 3. 窗口与菜单栏生命周期

红色关闭按钮和 `Cmd-W` 只隐藏配置窗口，保留草稿；Olanzi 仍留在菜单栏，已显示的 Dock 图标也保留。设备可用时，后台设备线程继续维护连接、调度心跳和按已确认设备映射转发普通键与 Fn。需要修改键位时，可从菜单栏或 Dock 重新打开配置窗口。接收器连接期间，后台线程持有防止 App Nap 的活动声明，使心跳和输入处理不因窗口隐藏而被降低调度；断开或退出时释放，演示模式不申请。该声明允许 Mac 正常睡眠。

从应用菜单选择退出，才会停止 App 与设备线程。退出时会尝试释放合成 Fn 按住状态，并关闭设备接口。因此，关闭窗口与退出 App 是不同操作。电脑进入睡眠后，无论窗口是否打开，都无法持续发送心跳。

当前不安装登录项、`launchd` 服务或开机自启。需要时手动启动 App 即可；菜单栏常驻提供后台生命周期，无需另开 Python daemon。

## 4. 本机动作与心跳

1. 首次连接时读取六个设备键位；仅在本机配置文件不存在时用它们初始化本机映射。
2. 在设备预览或右侧列表选择控件，编辑主要、双击或长按动作；旋转仅提供每格动作。
3. 检查草稿标签。可选手势可以分别关闭，全部关闭时保留主要按键立即响应。
4. 应用到本机。工作线程校验并原子保存整份配置，成功后才激活；此操作不写入设备键码。

Olanzi 运行时，本机映射负责全部六个控件，包括普通键与 Fn。初始化后可离线编辑，设备刷新与重连不会覆盖它。保存和导出的配置保留手势与时间参数，旧原生六键配置迁移为主要动作。职责、时序和迁移细节见 [10 · Daemon 输入运行时](10-input-runtime.zh.md)。

设备键位表保留为独立回退。协议工具的显式硬件写入仍需 ACK 与回读，并可能部分成功；原生本机动作编辑器不再调用该操作。草稿、本机已保存映射与硬件快照三者相互独立。

心跳使用从 Studio 恢复的明文前缀 `06 01 23 00 01`，后补零。它既保活也选择厂商事件转发方式；发送成功本身不能证明无线送达或长时间不休眠。见 [07 · 心跳调查](07-heartbeat-investigation.zh.md)。

## 5. 厂商按键转发、Fn 与权限

[CONFIRMED] 2026-09-21 现场对照发现：Olanzi 每秒发送 Studio 心跳时，普通键不再标准 HID 直出，Fn 标准输入回调也无报文。仅关闭 Fn 输入接口无效；仅停心跳、保留厂商连接和只读查询后，Enter 恢复。此时按键从厂商通道以 `8b 10` 上报，详见 [07 §4](07-heartbeat-investigation.zh.md)。因此普通键和 Fn 都需要应用侧转发及相应权限。

`GestureRouter` 按物理控件索引与已保存本机映射识别手势，`VendorKeyBridge` 执行选定动作并发送普通键或 Fn。`frame[2]` 的逻辑动作号不是 HID 键码，不能直接注入；AU05 的物理 index 来自 `frame[4]`。未应用草稿不参与转发，未知或多媒体映射须明确报错，不猜测注入。六个物理控件的 index 与旋转方向已现场确认；旋转 index 4/5 仅上报按下，由主机补松开形成脉冲。前一版厂商转发通过 68 项自动化测试与签名 Release 构建，本机运行时检查见 [10](10-input-runtime.zh.md)；Enter 和顶部 Fn 的物理效果已确认，其他控件的全部系统动作仍待验证。

Fn 仍是修饰键类别里的普通键名，选择并应用即可，没有独立功能开关或 `macFnEnabled` 设置。设备键码 `0x01` 在主机映射中表示 Fn，出厂顶部键也使用它。厂商事件包含物理控件 index，因此旧标准 HID 原型“同码物理键不可区分”的限制不能直接套用到新路径。移除全部 Fn 映射只是不再生成 Fn，普通键转发仍需运行与授权。

在“系统设置 → 隐私与安全性”里，给 **Olanzi App** 同时授予输入监控与辅助功能权限。这是原生应用包的权限，不是旧终端进程的授权步骤。缺少权限时，页底只提示缺少的项目，并提供“打开输入监控设置”或“打开辅助功能设置”按钮。设备页也保留同一入口，设备休眠或未连接时仍可操作。点击先在应用主线程直接请求所选权限，再打开对应系统设置；请求不再等待设备线程或连接。输入监控先使用 HID 请求接口，仍未获准时再调用事件监听请求作为后备。一次请求一项权限，不增加单独的 Fn 功能面板。系统策略和已有拒绝记录仍可能阻止再次弹框；打开设置页本身不能证明应用已加入列表。返回 Olanzi 时会无弹框复查权限；若已允许但系统仍报告未授权，则退出并重新打开 Olanzi。普通键和 Fn 的转发均受此权限状态约束；有设备映射不代表权限已就绪或转发已成功运行。

设置列表没有 Olanzi 时，点击 + 添加。设备页的“显示 App 位置”按钮会在 Finder 中选中当前运行的应用包。请给这个副本授权，并保持路径固定，例如仓库的 `build/Olanzi.app` 或 `~/Applications/Olanzi.app`。后续构建沿用同一签名证书和应用标识。从临时签名切换为证书签名会改变签名要求，因此原有权限可能需要移除后重新授予一次。稳定签名不会自动授予权限。

权限轮询先调用 `CGPreflightPostEventAccess()`，获准后才调用 `AXIsProcessTrusted()`；未获准时跳过身份检查。在实测 Mac 上，先做身份检查会留下辅助功能拒绝状态，进而挡住输入监控请求。回归测试覆盖首次未授权及后续授予、撤销状态。[CONFIRMED] 修改检查顺序并清理 Olanzi 旧权限记录后，点击已安装应用的权限按钮，输入监控列表自动出现 Olanzi，开关为关闭。加入列表和用户授权是两个步骤。

从旧临时签名版本迁移后，如残留拒绝记录，先退出 Olanzi，再只重置它受影响的权限，重新启动已安装副本并点击权限按钮。这会移除这些项目的已有授权，需要重新允许。应用不会自动执行这些重置命令。

```bash
tccutil reset Accessibility com.mrcroxx.olanzi
tccutil reset PostEvent com.mrcroxx.olanzi
tccutil reset ListenEvent com.mrcroxx.olanzi
open /Applications/Olanzi.app
```


新转发路径消费已有厂商连接的按键事件，不依赖没有报文的 Fn 标准输入回调。所有按键转发都需要 App 持续运行、设备在线、有效设备映射和相应权限。关闭窗口后仍继续，退出 App 则停止。实现须按物理控件跟踪按住状态，避免重复按下，并在松开、断连或退出时尝试释放；Enter 和顶部 Fn 的按下/松开已有现场验证，不能据此推定所有控件与异常释放场景都已物理验证。

Fn 转换不是固件原生 Fn 命令；协议或模拟事件测试均不能证明它与 Apple 硬件 Fn/地球键等效。听写、输入源切换、Studio 专用 Fn 路径和应用特定动作仍需物理测试。触发码原理与旧原型实现见 [08 · Mac Fn](08-mac-fn.zh.md)，其中的 Python 命令和 HTTP 设置不适用于原生 App。

原生转换通过 `cghidEventTap` 投递 Fn，保留私有事件源和成对的 `flagsChanged` 事件。[CONFIRMED] 检查运行中的豆包输入法发现其监听器位于 HID 层，Studio 的通用键盘事件发送路径也向这一层投递。此前会话层注入绕过了位于更早阶段的监听器。改为 HID 层投递修正了这一位置差异；本轮用户已确认顶部 Fn 能唤起豆包，日志也记录了松开后的 Fn 位清除；这一结果限于下述现场测试。这只解释了投递层级差异；新的心跳对照进一步确认，普通键失效还涉及从标准 HID 切换到厂商事件，不能仅靠改 Fn 的投递层级解决。新普通键与 Fn 转发共同采用 CoreGraphics 私有事件源和 HID tap。

本机诊断使用 `com.mrcroxx.olanzi` 日志子系统的 `device-input` 类别。排查时先区分厂商帧、解码后的物理控件按下/松开、已保存本机动作和主机事件发送；没有标准输入回调本身不能再当作设备没有按键的证据。六控件事件及 Enter / Fn 的验证摘录见[厂商按键路由记录](evidence/2026-09-21-vendor-key-routing.log)。六控件采集确认索引与按下/松开形状；只有 Enter 与顶部 Fn 另获当前现场系统效果确认。“待应用”草稿不是生效配置，测试前须保存到本机并等待激活。

## 6. 旧工具与迁移边界

Python 文件、浏览器界面和 daemon 管理器作为旧原型保留，说明见 [06 · 旧本地工作台](06-local-workspace.zh.md)。单文件 `vibekey.py` 仍是逆向与终端检查工具，文档见 [03 · 工具手册](03-tool-manual.zh.md)。只有明确运行这些工具时，才需要遵循相应权限与运行说明。

原生 App 不要求旧 HTTP 服务运行。应避免二者同时使用同一接收器，因为接口占用可能导致连接失败。启动 App 不会自动停止或迁移原来运行的旧服务。原生本机设置、旧 JSON 设置和浏览器本地配置是三套独立存储，旧 Fn 开关不影响原生 App，原生 Fn 行为由已确认的设备映射决定。

## 7. 验证与待观察项

在仓库根目录运行原生测试与文档检查：

```bash
swift test --package-path native
python3 tools/check_docs.py
git diff --check
```

文档校验命令里的 Python 是仓库维护工具，不是原生运行时要求。原生自动化测试使用受控输入验证协议和状态行为；构建或演示成功，均不能证明真实 Fn 动作或空闲防休眠。

前一版厂商转发通过 68 项自动化测试和签名 Release 构建，本机运行时检查见 [10](10-input-runtime.zh.md)。此前演示模式的界面验证覆盖旋钮旁箭头选择控件、Fn 分配、应用与回读、配置保存、重新打开窗口和正常退出；这些演示检查没有打开真实设备。

[CONFIRMED] 用户在修复版现场确认 Enter 换行及顶部 Fn 唤起豆包“好用！！”。日志记录 Enter 虚拟键码 36 按下/松开，以及一对 Fn 虚拟键码 63 的事件：17:31:24.285 按下 flags 545259520，17:31:25.616 松开 flags 536870912，Fn 位已清除。见[验证摘录](evidence/2026-09-21-vendor-key-routing.log)。这不表示两轮 Fn 测试，也不表示全部六个控件的系统动作已验证。

硬件验证时，应把设备实际回读与系统可见动作分别记录。特别是 Fn：按住一秒后松开、间隔两秒，确认没有重复按下，再在目标应用中检查预期动作；区分 App 的事件状态与 macOS 行为。长时间空闲心跳测试必须在 App 持续运行时覆盖相应时长。没有直接证据前，不要把这些观察标成已确认。
