# olanzi · 轻量 Ulanzi 设备工作台

> 🌐 [English](README.md)

> 📚 文档集：[01 职责边界](docs/01-ulanzi-studio-scope.zh.md) · [02 协议](docs/02-vibekey-protocol.zh.md) · [03 工具手册](docs/03-tool-manual.zh.md) · [04 方法论](docs/04-methodology.zh.md) · [05 验证记录](docs/05-verification-log.zh.md) · [06 工作台](docs/06-local-workspace.zh.md) · [07 心跳](docs/07-heartbeat-investigation.zh.md) · [08 Mac Fn](docs/08-mac-fn.zh.md) · [09 原生 macOS](docs/09-native-macos.zh.md) · [10 输入运行时](docs/10-input-runtime.zh.md)

> 面向 Ulanzi 设备的轻量 Studio 替代客户端：从 Vibe Key（AU05）键位配置开始。
> **SwiftUI + AppKit 原生菜单栏 App，直接使用 IOKit / CoreGraphics；主应用无需 Python、浏览器或 HTTP 服务。**

---

## 一句话

Olanzi 是一个可扩展的原生 macOS 设备工作台，用轻量菜单栏 App 承接 Studio 的设备管理定位。首期提供 VIA 风格的可视化键位配置、后台心跳和 Fn 键位支持；后续按协议验证结果扩展其他设备能力。Python 网页原型与逆向工具保留作研究参考。

Ulanzi Vibe Key 是一个 USB 复合 HID 设备。Ulanzi Studio 把它包了一层私有协议，
让它看起来"必须装 Studio 才能用"。我们把那层协议拆掉了：

```
✅ 读按键      直出模式用标准 HID；Studio 心跳模式改走厂商事件
✅ 改按键      私有通道 01 06 50 04，设备端持久化，已实测生效
✅ 读设备状态   固件 / 电量 / 降噪 / 指示灯 / SN / UUID
✅ 解密私有协议  TEA-ECB，密钥与算法全部解出，85 条命令表
```

---

## 快速上手

### 原生 macOS App

要求 macOS 14 或更新版本，以及 Swift 6 工具链（源码使用 Swift 5 语言模式）。从仓库根目录构建并打开：

```bash
make dev
```

`make release` 会编译、签名 Release 应用并生成 `build/Olanzi-<version>-<arch>.dmg`；`make dmg` 是同一流程的别名。打开 DMG，将 Olanzi 拖入 Applications 即可安装。磁盘映像沿用 App 的签名证书；本地签名不等于 Apple 公证。

`make dev` 通过现有打包脚本编译并打开 Debug 版本，输出 `build/Olanzi.app`。主应用使用完整 SwiftUI 键位界面和 AppKit 菜单栏，不需要运行 Python、浏览器或本地 HTTP 服务。关闭官方 Studio 及占用设备的旧工具后，插入接收器并打开 Vibe Key，再在 App 中选择控件、修改键码并应用。

界面支持简体中文与 English。通过主窗口顶部的设置页或 macOS 应用菜单中的设置（`Cmd-,`）选择跟随系统、English 或简体中文；权限欢迎页也提供语言选择。默认跟随系统，未支持的系统语言回退到 English。切换即时生效并保存偏好，无需重启，不改动键位配置或丢弃草稿；用户自定义的配置名称和文件路径保持原样。

动作标题旁的**录制组合键**会启动紧凑录制栏。按住需要组合的按键，例如 A+B 或 Control+A+B，全部松开后预览结果；点击**使用组合键**写入草稿，再保存到本机生效。组合键表示同时按住多个键，不是带时序的宏。

支持三个按键，以及旋钮按下、右拧、左拧，共六个动作。每个可按压控件支持主要动作及可选双击、长按动作，旋转按格立即执行。编辑长按动作时，通过紧凑模式菜单选择**保持按住**（默认）、**短按一次**或**连按**。保持按住持续至松开；短按一次发送一个脉冲；连按在达到阈值后发送指定次数，默认 2 次，可调 2–20 次。连按触发后松开控件仍完成该组，继续按住不会重复整组。已有保持按住和短按一次配置继续兼容；缺少模式的旧配置默认保持按住。日常编辑原子保存本机映射，不再改写设备键码；宏、多媒体和灯效不在此次实现范围内。关闭窗口后，菜单栏 App 继续维护设备连接、心跳与按本机已保存映射执行的按键转发；从菜单退出 App 才停止。当前不安装登录项或开机服务。

```bash
# 隔离演示，不访问真实硬件
swift run --package-path native Olanzi --demo

# 原生核心测试
swift test --package-path native
```

Studio 心跳会把按键切换到厂商事件路径，因此普通键与 Fn 都需要 App 依据本机已保存映射进行主机转发，并为 **Olanzi App** 授予输入监控与辅助功能权限。只有有效本机配置、设备在线和权限就绪时才启用心跳；否则暂停心跳，保留只读查询。应用优先读取已有本机配置；文件不存在时直接提供可编辑的出厂键位草稿，无设备也可编辑，只有显式保存到本机后才落盘并激活。设备旧键位不决定默认草稿，也不阻塞编辑；配置页的“从设备键位导入”是可选操作，校验成功才载入草稿，失败会指出不支持的控件并保留当前草稿，不改写设备键位。损坏的本机配置文件会保留，须修复后重启。在修饰键类别选择 **Fn** 并应用即可分配 Fn，无需额外开关；草稿不影响转发。Fn 对应设备键码 `0x01`，出厂顶部键也使用它。保持 App 路径和签名证书稳定，签名身份变更可能需要重新授权。前一版厂商转发已实测 Enter 与豆包 Fn，新运行时架构、迁移、手势规则与检查见 [10 · Daemon 输入运行时](docs/10-input-runtime.zh.md)。

主窗口在连接状态下方显示电量百分比与充电状态，在线时每 20 秒通过只读查询刷新；20% 及以下显示橙色，离线或读数不可用时显示 `电量 —`。电量查询失败单独提示，不会停用 Fn 转发。

双击和长按动作继续保留。跨 Mac 使用时，导出完整 `HostProfile` JSON，在另一台 Mac 导入后显式保存到本机；文件包含主要动作、双击、长按动作、长按触发方式、连按次数及时间参数。不提供通过设备自动跨 Mac 同步，此流程不写设备键位。

构建、菜单栏生命周期、权限与验证边界见 **[09 · 原生 macOS App](docs/09-native-macos.zh.md)**。旧 Python/浏览器原型和 daemon 说明保留在 [06 · 旧本地工作台原型](docs/06-local-workspace.zh.md)，不再是主应用入口；Fn 的底层原理见 [08 · Mac Fn](docs/08-mac-fn.zh.md)。

### 原有终端工具

```bash
cd olanzi

# 1. 实时监控按键（Ctrl-C 退出）
python3 vibekey.py --probe --poll 2

# 2. 看设备里存的按键配置
python3 vibekey.py --keys

# 3. 改键（把最上面那个键改成 F13）
python3 vibekey.py --set-key 0=F13
```

输出长这样：

```
13:29:21 按键   ⌨ 键 2 (中)        Enter                      400 ms
13:29:26 旋钮   ⟳ 旋钮 → 右拧       RightArrow                   4 ms
13:29:34 按键   ⌨ 旋钮 按下        PrintScreen               1220 ms
```

> ⚠️ **按键会真的注入你的焦点窗口**（键 2 打 `Enter`、键 3 打 `Esc`、旋钮打方向键/退格）。
> 程序默认关闭终端回显，让输出保持干净；加 `--echo` 可以恢复看到按键字符。

### 终端按键监控的前置条件：输入监控权限

macOS 需要 **输入监控** 权限才能读键盘接口。

> 系统设置 → 隐私与安全性 → **输入监控** → 打开你用的终端（iTerm2 / Terminal）→ **重启终端**

没权限时程序会红字报警并自动重试，一开权限就自动接上，不用重启程序。

---

## 这台设备有什么

| 项 | 值 |
|---|---|
| 型号 | **AU05**（Vibe Key） |
| USB | VID `0xFFF1` / PID `0x00DD`，复合设备，序列号 `202606031150` |
| 固件 | 4.4.2（dongle 与设备同版本） |
| 控件 | **3 个键（上下排列）+ 1 个旋钮 + 1 个电源键** |
| 接口 2 | 标准 HID：Consumer `0x01` / Mouse `0x02` / **Keyboard `0x03`** |
| 接口 3 | 厂商私有：Usage Page `0xFFFC`，Report ID `0x55`，TEA 加密 |

**出厂按键映射**（实测确认）：

| 控件 | HID 键码 | 含义 |
|---|---|---|
| 键 1（上） | `0x01` | ErrorRollOver —— **系统原生忽略**；原生 App 按确认映射自动将其作为 Fn 触发码 |
| 键 2（中） | `0x28` | Enter |
| 键 3（下） | `0x29` | Esc |
| 旋钮 → 右拧 | `0x4F` | RightArrow |
| 旋钮 ← 左拧 | `0x2A` | Backspace |
| 旋钮 按下 | `0x46` | PrintScreen |
| 电源键 | — | **不发报文**，由设备硬件处理 |

> **键 1 是"残废"的** —— 它发的是无效码，脱离 Studio 等于没有。
> 这不是 bug，是设计：键 1 就是 AI 对话键，被绑死在自家软件上。
> **现在你可以改它**，也可以保留该键码，由原生 App 在获得权限后自动转换为 Fn。厂商事件按物理控件索引查映射，不再使用旧标准 HID 原型的同码识别方式。

---

## 能力边界

| 归设备/系统管 | 归 Ulanzi Studio 管 |
|---|---|
| ✅ 无 Studio 心跳时的标准 HID 直出；心跳模式由主机转发 | ⬜ 指示灯效果（AI 状态 → 灯效） |
| ✅ 按键表（我们现在能读写） | ⬜ 固件 OTA |
| ✅ 多媒体键 / 鼠标 | ⬜ 插件生态、云市场 |
| | ⬜ profile 管理、多设备编排 |

第一期完整分析见 [docs/01-ulanzi-studio-scope.md](docs/01-ulanzi-studio-scope.zh.md)。

---

## 文档导航

| 文档 | 内容 |
|---|---|
| **[01 · Studio 职责边界](docs/01-ulanzi-studio-scope.zh.md)** | Ulanzi Studio 到底做了什么、哪些不归它管（第一期） |
| **[02 · Vibe Key 协议](docs/02-vibekey-protocol.zh.md)** | TEA 密钥、帧格式、85 条命令表、控件映射、**可编程按键表** |
| **[03 · 工具手册](docs/03-tool-manual.zh.md)** | `vibekey.py` 全部参数、输出解读、故障排查 |
| **[04 · 逆向方法论](docs/04-methodology.zh.md)** | 怎么逆出来的：可复现的步骤、关键突破点、踩过的坑 |
| **[05 · 验证记录](docs/05-verification-log.zh.md)** | 所有实测数据留档（含失败尝试） |
| **[06 · 旧本地工作台原型](docs/06-local-workspace.zh.md)** | 保留的 Python/浏览器原型、配置文件与 daemon 说明 |
| **[07 · 心跳调查](docs/07-heartbeat-investigation.zh.md)** | 官方心跳命令、在线状态与防休眠验证 |
| **[08 · Mac Fn](docs/08-mac-fn.zh.md)** | Fn 原理、旧 Python 原型记录与验证边界 |
| **[09 · 原生 macOS App](docs/09-native-macos.zh.md)** | 当前主入口：Swift 构建、菜单栏、权限与验证边界 |
| **[10 · 输入运行时](docs/10-input-runtime.zh.md)** | 本机动作、双击长按、持久化与迁移 |

> **英文是默认入口**：文档文件名不带语言后缀。中文版加 `.zh.md`。两版结构严格对应，改一边必须同步另一边。

---

## 原有逆向工具的数据流

```
                    ┌──────────────────────────────────┐
   ┌──────────┐     │         Vibe Key (AU05)          │
   │  3 个键   │────▶│  固件查"按键表"决定发什么键码        │
   │  1 个旋钮 │     │                                  │
   └──────────┘     └────────────┬─────────────────────┘
                                 │
              ┌──────────────────┴──────────────────┐
              ▼                                     ▼
   ┌─────────────────────┐              ┌──────────────────────┐
   │ 接口 2 · 标准 HID    │              │ 接口 3 · 厂商私有      │
   │ Report ID 0x03      │              │ Report ID 0x55       │
   │ 明文键盘报文         │              │ TEA 加密             │
   └──────────┬──────────┘              └──────────┬───────────┘
              │                                     │
              ▼                                     ▼
    直接注入 macOS                        ┌─────────────────┐
    任何程序都能读                         │  配置读写        │
    （我们的工具走这条路）                   │  设备信息查询     │
              │                          │  指示灯控制       │
              │                          │  固件升级         │
              │                          └─────────────────┘
              │                                     │
              └──────────────┬──────────────────────┘
                             ▼
                    ┌─────────────────┐
                    │  vibekey.py     │
                    │  （本项目）       │
                    └─────────────────┘
                    ↑ 完全绕开 Ulanzi Studio
```

> **范围更新**：上图与早期标准 HID 抓包描述未发送 Studio 专用心跳的历史状态。2026-09-21 实测 Olanzi 心跳会让按键改走厂商 `8b 10` 事件，停止心跳后 Enter 直出恢复；普通键也需要主机转发。旧 Hooks 查询不等于心跳，防休眠因果关系仍须独立验证，见 [07 · 心跳调查](docs/07-heartbeat-investigation.zh.md)。

---

## 项目结构

```
olanzi/
├── AGENTS.md                    ← 项目 Memory（约定 / 技术不变量 / 安全规则）
├── README.md / README.zh.md     ← 你在这里（英 / 中）
├── native/
│   ├── Package.swift           ← macOS 14+，Swift 6 工具链 / Swift 5 语言模式
│   ├── Sources/OlanziCore/     ← TEA、IOKit、CoreGraphics 与后台线程
│   ├── Sources/OlanziApp/      ← SwiftUI 界面与 AppKit 菜单栏
│   └── Tests/                  ← 原生核心测试
├── vibekey.py                  ← 逆向终端工具（零第三方依赖）
├── olanzi*.py / web/ / tests/   ← 保留的旧 Python / 浏览器原型与测试
├── tools/
│   ├── build-macos.sh          ← 构建 build/Olanzi.app
│   └── check_docs.py           ← 文档双语一致性校验
└── docs/
    ├── 01-ulanzi-studio-scope.md   (+ .zh.md)
    ├── 02-vibekey-protocol.md      (+ .zh.md)
    ├── 03-tool-manual.md           (+ .zh.md)
    ├── 04-methodology.md           (+ .zh.md)
    ├── 05-verification-log.md      (+ .zh.md)
    ├── 06-local-workspace.md       (+ .zh.md)
    ├── 07-heartbeat-investigation.md (+ .zh.md)
    ├── 08-mac-fn.md                (+ .zh.md)
    ├── 09-native-macos.md          (+ .zh.md)
    └── evidence/
        └── 2026-09-21-key-reprogram.log
```

逆向过程的原始数据（反汇编、符号表、62 MB 解码日志等）在 `~/ulanzi-re/`，
属于**中间产物**，不在本仓库内。

---

## 环境

| 项 | 版本 |
|---|---|
| 原生应用系统 | macOS 14 或更新版本 |
| 原生工具链 | Swift 6（Swift 5 语言模式） |
| 旧逆向工具 | Python 3.x（仅标准库，主应用不依赖它） |
| 被测固件 | Ulanzi Studio **3.3.9** / Vibe Key 固件 **4.4.2** |
| 验证日期 | 2026-09-21 |

> 协议可能随固件更新而变化。升级后若行为异常，先跑 `python3 vibekey.py --keys` 看配置表是否还在。

---

## 路线图

- [x] **第一期** —— 划清 Studio 的职责边界
- [x] **第二期** —— 解出私有协议（TEA + 85 条命令 + 控件映射）
- [x] **第三期** —— 读按键的终端工具（脱离 Studio 可用）
- [x] **第四期** —— 读写设备的可编程按键表（**改键**）
- [x] **第五期** —— Python 本地工作台原型（保留作研究参考）
- [x] **第六期** —— Swift 原生菜单栏 App（键位界面、后台心跳与 Fn 键位）
- [ ] **后续** —— 按实测协议扩展指示灯、自动化及其他 Studio 能力
- [ ] 待验证 —— 设备端键位表中的组合键（`num > 1`）、`类型=0x03`（系统/多媒体）

---

## 说明

本项目为**互操作性研究**：目的是让用户在自己买的硬件上运行自己写的软件。
所有结论均来自对**本机已购设备**的观察与静态分析，未破解任何版权保护措施，
未绕过任何鉴权，未分发厂商代码或固件。

`vibekey.py` 只依赖系统自带的 IOKit，**不读取、不修改 Ulanzi Studio 的任何文件**。
