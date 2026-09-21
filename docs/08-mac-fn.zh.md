# 08 · Mac Fn 本机转换

> 🌐 [English](08-mac-fn.md)

> 📚 文档集：[README](../README.zh.md) · [01 职责边界](01-ulanzi-studio-scope.zh.md) · [02 协议](02-vibekey-protocol.zh.md) · [03 工具手册](03-tool-manual.zh.md) · [04 方法论](04-methodology.zh.md) · [05 验证记录](05-verification-log.zh.md) · [06 工作台](06-local-workspace.zh.md) · [07 心跳](07-heartbeat-investigation.zh.md) · **08 Mac Fn** · [09 原生 macOS](09-native-macos.zh.md) · [10 输入运行时](10-input-runtime.zh.md)

> 本文保留旧 Python 原型基于标准输入报文的 Fn 实现记录。2026-09-21 新实测表明，Studio 心跳运行时标准按键直出会停止，原生修复改从厂商事件的物理控件 index 查已保存的本机动作，再转发普通键及 Fn；见 [07 §4](07-heartbeat-investigation.zh.md) 和 **[09 · 原生 macOS App](09-native-macos.zh.md)**。下文“无法区分同码控件”、独立 Fn 开关、Python / HTTP / JSON 文件及终端授权均描述旧标准 HID 原型，不能用于推断新厂商事件路径。

## 1. 功能含义

旧原型的可选本机转换把 AU05 标准输入报文转换为当前 macOS 会话里的 Fn 修饰键事件。在 Olanzi 的修饰键类别选择 Mac Fn 并应用映射后，再开启本机 Fn 设置。这是两件独立的事：设备存储键码 `0x01`，运行中的主机服务把对应输入报文解释为 Fn。

出厂顶部按键已经使用 `0x01`（ErrorRollOver），macOS 原本会忽略它。开启转换后，原有映射就成为 Fn 触发码，不必写入另一个设备端键码。关闭转换后，它仍是被系统忽略的键码。这不代表已经找到设备固件的原生 Fn 命令。

所有配置为该键码的控件共享相同解释。标准键盘报文包含键码，不含物理控件索引，因此转换无法区分两个发送相同键码的控件，也无法分别计算多个同码控件的持续按住状态。建议只设一个专用 Fn 控件，不要期待瞬时旋钮转动表现得像持续按住。

## 2. 旧原型的启用与授权

1. 手动运行 `python3 olanzi.py`（或启动后台服务），连接接收器并打开 Vibe Key，等待自动连接。
2. 选择目标控件，在修饰键类别选择 Mac Fn 并应用映射。出厂顶部按键可以保留原映射。
3. 在界面开启本机 Mac Fn 转换。
4. 若缺少权限，点击显式的权限请求按钮。在“系统设置 → 隐私与安全性”里，为运行 Olanzi 的终端同时开启“输入监控”和“辅助功能”。
5. 若 macOS 要求重启才能生效，请自行停止服务、完全退出并重新打开终端，再次运行 `python3 olanzi.py` 并连接设备。等转换状态显示已运行后再测试。

首次启动时该功能默认关闭。启用开关不会悄悄请求系统授权。后台重试只查询权限状态，不弹窗；只有权限请求按钮会发起授权请求。权限缺失或输入接口不可用会明确显示，转换重试不会替换或关闭原有厂商通道的改键与心跳连接。

服务和设备连接必须保持运行。关闭浏览器不会停止前台或后台服务。通过 `python3 olanzi.py daemon start` 手动启动后台后，关闭终端也能继续运行；`python3 olanzi.py daemon status` 查看进程状态，`python3 olanzi.py daemon stop` 停止后台。后台方式不安装开机自启，操作和日志见 [06 · 工作台](06-local-workspace.zh.md)。断开连接、关闭转换或停止服务都会结束转换，并尝试释放可能存在的合成 Fn 按住状态。演示模式不打开真实输入接口，也不注入 Fn 事件。

## 3. 设备报文与事件生命周期

| 输入或条件 | 转换行为 |
|---|---|
| 匹配 AU05 厂商/产品标识及标准输入接口 | 独立于厂商通道打开这个设备接口 |
| 键盘 Report ID `0x03`、完整报文、恰好一个 `0x01` 键码条目 | 切换到按住状态时发送 Fn 按下 |
| 相同 Fn 按住状态的重复报文 | 不重复发送 Fn 按下 |
| 不含 Fn 触发码的有效报文，包括全零释放 | 若存在本转换产生的按住状态，则发送 Fn 松开 |
| 六个 `0x01` 条目（ErrorRollOver）或错误条目 | 不触发 Fn 按下 |
| 非键盘或不完整报文 | 忽略 |
| 设备断开、在线状态不可用、关闭转换或服务退出 | 关闭输入接口前尝试释放 Fn |
| 松开事件发送失败 | 显示错误并保留待释放状态以重试，不虚报释放成功 |

筛选目标为 VID `0xFFF1` / PID `0x00DD` 和 AU05 标准输入接口，不监控其他键盘的输入报文。关闭转换时，不打开该输入接口。事件发送器读取物理修饰键的汇总位掩码，以保留同时按住的修饰键；它不采集或记录其他键盘的按键事件。

主机事件采用虚拟键码 63，对应 Apple SDK 的 `HIToolbox.framework/Headers/Events.h` 中的 `kVK_Function = 0x3F`，以及 Fn 标志位 `0x800000`。Apple 的 [maskSecondaryFn 文档](https://developer.apple.com/documentation/coregraphics/cgeventflags/masksecondaryfn) 将这个标志定义为 Fn 按下指示。按下和松开均发送为 [flagsChanged 事件](https://developer.apple.com/documentation/coregraphics/cgeventtype/flagschanged)。

当前实现创建键盘事件、设置类型与标志位，再通过 [cgSessionEventTap](https://developer.apple.com/documentation/coregraphics/cgeventtaplocation/cgsessioneventtap) 投递，并使用私有事件源。这种隔离旨在合并修饰键时，避免把自身合成的 Fn 状态误认为物理键盘状态。这项实现选择不能证明它与所有硬件路径或 Studio 专用 Fn 路径等效。事件标志位设置见 Apple 的 [CGEventSetFlags 文档](https://developer.apple.com/documentation/coregraphics/cgeventsetflags?language=objc)。

## 4. 旧原型的设置与配置文件

本机开关保存在：

```text
~/Library/Application Support/Olanzi/settings.json
```

这是当前 Mac 的服务设置，与设备内键位映射、浏览器本地配置都相互独立。服务重启时重新读取保存的开关；更换浏览器或端口不会创建另一份服务偏好。若设置文件读取失败，转换保持关闭并显示错误。

设备配置的导入导出包含键码，因此配置可以带有 Fn 触发码，但不会包含或修改本机 Fn 开关。应用出厂映射不会关闭转换；若本机开关已启用，出厂顶部按键仍会触发 Fn。演示模式的修改不会写入真实设置文件。

本地 HTTP API 使用 `POST /api/fn` 携带 `{"enabled": true}` 或 `{"enabled": false}` 修改开关，使用 `POST /api/fn/permissions` 携带 `{}` 显式请求权限。这些端点沿用工作台其他修改操作的回环地址、主机与同源检查。界面分别呈现已启用、实际运行、权限、按住和错误状态；设置已启用本身不代表转换已在运行。

## 5. 验证边界

旧原型实现与自动化测试覆盖报文解码、筛选、重复报文、按下/松开转换、权限失败、重连、设置持久化和清理行为。模拟测试通过只能证明应用在模拟输入下的行为，不能证明 macOS 已执行某个用户动作。

本转换不声称与 Apple 硬件 Fn/地球键、官方 Studio 的专用 Fn 处理、听写、输入源切换或每个应用的快捷键处理完全等效。这些结果需要在用户实际的 macOS 版本、键盘设置和目标应用中测试。浏览器输入测试不能可靠验证 Fn，因为它可能不会作为普通键盘事件送到页面。

手动测试应保持明确的顺序与间隔：

1. 确认转换已运行，目标物理控件已映射为 Fn 触发码，其他控件保持不动。
2. 按住该控件一秒后松开，等待两秒，检查界面不再显示按住。
3. 再重复一次，等待两秒，确认一次持续按住没有被当成重复按下。
4. 在目标应用或系统设置中检查预期的 Fn 动作，将实际可见结果与转换事件计数分别记录。
5. 按住控件时关闭转换，然后松开物理控件，等待两秒，检查不再报告合成 Fn 按住。只有需要继续测试时再重新开启。

不要把未观察到的系统效果写成已确认结论。硬件观察与系统可见行为应记录 macOS 版本、相关键盘设置、目标应用和实际结果；缺少这些观察时，相应系统动作仍然待验证。
