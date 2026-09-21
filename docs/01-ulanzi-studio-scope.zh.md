# Ulanzi Studio 逆向 · 第一期：职责边界
> 🌐 [English](01-ulanzi-studio-scope.md)

> 目标：搞清楚 **Ulanzi Studio 到底做了什么、哪些归它管、哪些不归它管**，为写一个开源替代客户端划定范围。
>
> 被测对象：macOS 上的 `Ulanzi Studio 3.3.9`（主程序名 `UlanziDeck`）
> 硬件：Ulanzi Vibe Key（USB 无线麦克风套装，dongle 产品名 `AU05`）
> 方法：静态分析（符号表 / ObjC 元数据 / 反汇编）+ 运行时抓包（HID / lsof / WebSocket 探测）
>
> 标注约定：**[CONFIRMED]** = 有直接证据（实测或二进制字面量）；**[INFERRED]** = 由间接证据推断，待验证。
>
> 📚 文档集：[README](../README.zh.md) · **01 职责边界** · [02 协议](02-vibekey-protocol.zh.md) · [03 工具手册](03-tool-manual.zh.md) · [04 逆向方法论](04-methodology.zh.md) · [05 验证记录](05-verification-log.zh.md) · [10 输入运行时](10-input-runtime.zh.md)
>
> ⚠️ 本文是**第一期**快照（写于协议解出之前），部分"待确认"项**已完成**，见 §5 与 [02](02-vibekey-protocol.zh.md)。

---

> 范围更新（2026-09-21）：本文关于标准 HID 直出的早期观察仅适用于未发送 Studio 专用心跳的状态。后续实测 Olanzi 发送该心跳会停止标准按键直出，改为厂商事件；因此普通键也需要主机转发。下文原始记录保留，新的对照与字段解释见 [07 §4](07-heartbeat-investigation.zh.md)。

## 0. 结论速览（先看这个）

| 问题 | 结论 |
|---|---|
| Vibe Key 的按键是怎么传给电脑的？ | 未发 Studio 专用心跳的历史状态为**标准 USB HID 键盘报文**；心跳模式改走厂商事件 **[CONFIRMED]** |
| 那 Ulanzi Studio 管什么？ | **管输出**（指示灯/状态/LED/固件 OTA）、**配置**（profile、绑定、亮度），以及心跳模式的按键转发 |
| Vibe Coding 的 AI 状态怎么到设备上的？ | 对 **WiFi 设备**可以绕过 Studio 直接 HTTP；对 **Vibe Key（纯 USB）必须经过 Studio** **[INFERRED，见 §4.2]** |
| 插件系统是什么？ | 本地 WebSocket，`127.0.0.1:3906`，**无鉴权、无路径路由**，协议可完全复刻 **[CONFIRMED]** |
| 能不能只写一个替代 Studio？ | 可以，但必须复刻 `kwdm.dylib` 的 HID 私有协议 —— **✅ 已完成，见 [02](02-vibekey-protocol.zh.md)** |

**历史概括的边界**：直出模式下，键盘输入由设备固件提供；Studio 还负责
**① 把 AI agent 状态翻译成指示灯效果**、**② 固件 OTA**、**③ 插件生态与云市场**。发送专用心跳后的厂商事件模式另需主机按键转发。

---

## 1. 程序组成

### 1.1 基本信息 **[CONFIRMED]**

| 项 | 值 |
|---|---|
| 版本 | `3.3.9`（`version.txt`、crashpad `AppVersion=3.3.9`） |
| 主二进制 | `/Applications/Ulanzi Studio.app/Contents/MacOS/UlanziDeck`（62 MB，Mach-O arm64，**未 strip**） |
| UI 框架 | Qt 6（QtQuick / QtWebEngine / QtWebChannel 全套） |
| 单实例 | `QtSingleApplication` + `qtlocalpeer` / `qtlockedfile` |
| 数据目录 | `~/Library/Application Support/Ulanzi/UlanziDeck/` |
| 偏好设置 | `~/Library/Preferences/com.ulanzi.UlanziDeck.plist` |

### 1.2 关键依赖（决定它能干什么） **[CONFIRMED]**

| 组件 | 作用 |
|---|---|
| `kwdm.dylib`（Kehwin SDK，**运行时 QLibrary 加载**） | **Vibe / Dial 家族的私有 HID 协议** ← 核心 |
| `libhidapi.0.14.0.dylib` | **仅用于老款 Ulanzi Deck**：`hid_enumerate(0x2207, 0x0019)` |
| `libUlanziFZBle.dylib` | BLE 设备（TC002 / K6500 灯 + 可能的配网） |
| `libcountly.dylib` | 埋点统计 |
| `crashpad_handler` | 崩溃上报 |
| `libmars-boost.a` + `xlog` | 腾讯 mars xlog 日志（**加密，暂不可读**） |
| `QtBluetooth` / `QtSerialPort` | BLE / 串口（**串口实际未使用**） |

---

## 2. Ulanzi Studio 管什么

### 2.1 设备接入与固件

- 维护设备列表、型号识别、profile 持久化（`ProfilesV2/`）、亮度、字体、图标 **[CONFIRMED]**
- **固件 OTA**：`VibeOtaManager` 负责 Vibe 家族的**链式升级**（先 dongle `AU05_USB` 后 mic `AU05_Device`，20 秒无进度则中止，出错后重启两端）**[CONFIRMED]**
  - 升级包走 `kwdm` 的 `FirmwareFrame` / `UploadImageFrame` / `calc_crc16-8`，**不走 HTTP**
  - HTTP 只用来**问有没有新版本**：`/vibekey/firmware/checkUpdate?deviceSn=&pid=&ver=&lang=`
- 设备发现：**UDP 55555**（`DeviceWatcherManager`，`ShareAddress`）。**没有 mDNS** **[CONFIRMED]**

### 2.2 插件系统（`127.0.0.1:3906`）**[CONFIRMED]**

- 裸 `QWebSocketServer`，**只监听 localhost，`ws://` 无 TLS**
- **没有任何路径路由**——`/`、`/index.html`、`/api` 一律等价（实测三个路径都返回 `101 Switching Protocols`）
- 插件握手：`{"cmd":"connected","code":0,"uuid":"<plugin-uuid>"}`，`code` 必填（int `0` 或 `"0"`），**不回包**
- **无鉴权**：任何本地进程都能冒充任意 `uuid`
- 应用→插件命令：`run` / `add` / `paramfromapp` / `setactive` / `clear` / `rotateEvent`
- 插件→应用命令：`setImage` / `setTitle` / `setState` / `setSettings` / `hotkey` / `toast` / `showAlert` / `openurl` / `sendToPlugin` / `subscribeAiAgentState` / `getAiAgentSessions` 等

→ **这是最容易复刻的部分**：社区已有 Elgato Stream Deck 的同类实现（Ulanzi 的 `deps/DeckSDK/` 就是 Stream Deck SDK 的血统）。

### 2.3 云服务 **[CONFIRMED]**

| 域名 | 用途 |
|---|---|
| `api.ulanzistudio.com/api` | 登录 / 用户信息 / 短信验证码 / 忘记密码 / 日志上传 |
| `ulanzistudio.com` | 产品列表、图标、下载、公告、插件市场、**crashpad 上传** |
| `countly.ulanzistudio.com` | 埋点（app key `e7655fcbc00acffc5ca86f196bba2a68cfc8001b`） |

### 2.4 Vibe Coding 集成（`ustudio-cli`）

这是本期的重点，结构是**三段式**：

```
①  AI 编码 agent 触发 hook
        ↓  (stdin JSON)
②  ustudio-cli-hook  (shell wrapper → 编译好的 ustudio-cli 二进制)
        ↓  QLocalSocket，socket 名 "ulanzistudio_cli"
③  UlanziDeck  (必须正在运行，否则 CLI 直接报错退出)
        ↓
④  kwdm.dylib  →  USB HID 厂商通道  →  设备
```

> ⚠️ **重要修正（第二期）**：网上/早期分析里常见的
> `ustudio-cli` 直接 `POST http://<设备IP>/events` 那条路径是**已废弃的遗留代码**。
> `hooks/device-hook.js` 与 `installers/device-install.js` 是**孤儿文件，没有任何调用方**；
> 而且 `install.js` 里的 `isLegacyLocalStateCommand()` 会**主动删除**任何匹配
> `https?://(127.0.0.1|localhost):\d+` + `"state":"(thinking|streaming|done|idle|error)"`
> 的 hook 条目——厂商在主动清理这条老路。
> 证据：整个 `~/Library/Application Support/Ulanzi/` 目录树里
> **IPv4 字面量 0 命中**；主二进制里**没有** `--device-ip` / `ai-tool-state` / `device-hook` 字符串。
>
> **真实链路是本地 socket，不是网络。**

- 支持 **8 个 agent**：`claude-code`、`codex`、`gemini-cli`、`cursor-agent`、`codebuddy`、`kiro-cli`、`kimi-cli`、`copilot-cli` **[CONFIRMED]**
- 事件 → 状态映射（`hooks/mappings.js`）**[CONFIRMED]**：

  | 状态 | 触发事件（claude-code） |
  |---|---|
  | `idle` | SessionStart |
  | `thinking` | UserPromptSubmit |
  | `working` | PreToolUse / PostToolUse / SubagentStart / SubagentStop |
  | `error` | PostToolUseFailure / StopFailure |
  | `attention` | Stop |
  | `notification` | Notification / PermissionRequest |
  | `sweeping` | PreCompact |

- 已确认写入你机器上的 `~/.claude/settings.json`（12 个 hook 事件全部注册）**[CONFIRMED]**
- 官方声明会**脱敏**：只转发白名单元数据，不记录 prompt / transcript / 工具入参 **[CONFIRMED，来自 manifest.json]**

---

## 3. 不归它管的部分（重要！）

这是本期最有价值的发现。

### 3.1 ⭐ 未发专用心跳时可直接读标准 HID **[CONFIRMED]**

Vibe Key 的 dongle（`AU05`）是一个 **USB 复合设备**，一次枚举出这些接口：

| 接口 | 用途 | 说明 |
|---|---|---|
| USB Audio | 麦克风输入（2 声道 48 kHz） | 无线麦的声音就从这个口进来 |
| HID 接口 2 | **键盘 + 鼠标 + 多媒体键** | Report ID 1/2/3，标准 HID |
| HID 接口 3 | **厂商自定义控制通道** | Usage Page `0xFFFC`，Report ID `0x55`，63 字节 |

**实测证据**：让你依次按 4 个键和旋钮，捕获到 **12 条 `rid=0x03` 标准键盘报告**（6 按 + 6 抬），
每条都对应你的一次动作，**厂商通道一条都没动**：

| 你的动作 | 捕获到的键码 |
|---|---|
| 按第 1 个键 | `0x01` |
| 按第 2 个键 | `0x28` Enter |
| 按第 3 个键 | `0x29` Esc |
| 旋钮右拧 | `0x4f` → |
| 旋钮右拧（第二次） | `0x2a` Backspace |
| 按下旋钮 | `0x46` PrintScreen |

> **当时状态下的推论**：未发 Studio 专用心跳时，标准 HID 足以读取按键；不能将此推广到心跳运行后的厂商事件模式。
> 而且设备还能直接向 Mac **注入键鼠**（这就是它能控制 Claude Code 的方式）。
>
> ✅ **已完成**：映射表已通过受控顺序实验固定，并与设备端配置表交叉验证。
> 6 个控件 = `01 / 28 / 29 / 46 / 4f / 2a`，见 [02 §5](02-vibekey-protocol.zh.md)。
> **并且这些键码现在是可改写的** —— 见 [02 §6 可编程按键表](02-vibekey-protocol.zh.md)。

### 3.2 当次抓包的厂商通道只有**周期通知** **[CONFIRMED]**

厂商接口（接口 3）在你操作期间只发了 4 帧，时间戳间隔为
`10.100s / 10.100s / 10.100s` —— **精确周期**，与按键时间无关联。

载荷结构固定：

```
rid=0x55 | 前 8 字节（每次不同） | 后 55 字节（每次相同）
                                  38 90 c4 99 a3 60 aa ad  (重复 6 次 + 截断 7 字节)
```

- 这串固定尾串**在二进制里搜不到**（0 命中）→ 运行时算出来的
- 4 帧中有 3 帧前 8 字节**完全相同** → 无随机 IV，**加密是确定性的**
- 高度怀疑是 **8 字节分组密码 ECB + 静态 IV**，明文大部分是固定/零值

### 3.3 私有协议的真实边界

`kwdm.dylib` 是 Objective-C 写的，**保留了完整的类型编码**，直接把线上结构体布局暴露了：

```
st_small_base_com_msg = { st_base_header(1B) | union { ... } }  总长 63 字节
```

正好等于我们抓到的 63 字节负载。五个 union 分支：

| 分支 | 方向 | 内容 |
|---|---|---|
| `st_usb_singel_cfg` | ↔ dongle | 版本、flash id、**dongle SN**、心跳、按键长按功能、重启、**加密字段** |
| `st_device_singel_cfg` | ↔ 设备 | **超大配置表**（见下） |
| `st_msg_interactive_pc` | 设备 → PC | **按键消息**、滚轮事件、电量、LED 效果、**麦克风降噪等级** |
| `mic_sbc_data_t` | 麦克风音频 | SBC 编码音频（32 字节） |
| `st_upgrade_software_msg` | OTA | 连接/下载/校验/编程/结果 |

其中 **`st_device_singel_cfg`** 里的字段名几乎是一份需求文档：

- **`ai_index_cfg_t`** ← AI 状态索引（Vibe Coding 的核心）
- **`led_hooks_param_cfg_t`** ← hook 事件的 LED 参数
- `led_light_param_cfg_t`、`sys_work_led_cfg_t`
- **`sys_mic_nr_level_t`** ← 麦克风降噪
- `mic_open_cfg_t`、`device_mic_ui_cfg_t`
- `oled_brightness_cfg_t`、`oled_screen_off_time_cfg_t`、`cfg_lcd_git_param_t`
- `device_uuid_cfg_t`、`device_sn_cfg_t`、`sys_mac_addr_t`、`sys_hardware_version_t`
- `key_shortcut_msg_unit_cfg_t`、`key_shortcut_mode_cfg_t` ← **按键绑定**

---

## 4. 通信面总清单

| # | 通道 | 地址 / 标识 | 归属 | 可复刻性 |
|---|---|---|---|---|
| 1 | 插件 WebSocket | `127.0.0.1:3906` | Studio | ⭐⭐⭐ 极易（明文 JSON） |
| 2 | 内部 CLI IPC | QLocalServer `ulanzistudio_cli` | Studio ↔ ustudio-cli | ⭐⭐ 中等 |
| 3 | 设备发现 | **UDP 55555** 广播 | Studio ↔ 网络设备 | ⭐⭐⭐ 易 |
| 4 | 设备 HTTP | `http://<ip>:<port>/events` | hook → 设备直连 | ⭐⭐⭐ 易（但 Vibe Key 用不上） |
| 5 | **厂商 HID** | Usage Page `0xFFFC`, **Report ID `0x55`**, 63B | kwdm → Vibe Key | ⭐ **难，核心工作** |
| 6 | 标准 HID 输入 | Report ID 1/2/3 | **设备固件** | ⭐⭐⭐ 免费 |
| 7 | BLE GATT | `0000fff0`→`fff2/fff1`；`0000a002`→`c304/c305`；`f000ffc0`→`ffc1` | FZ BLE | ⭐⭐ 中等 |
| 8 | 老 Deck HID | `hid_enumerate(0x2207, 0x0019)` | hidapi | ⭐⭐ 中等（只影响老设备） |
| 9 | 云 API | `api./countly./www.ulanzistudio.com` | Studio | ⭐⭐⭐ 易（但对替代客户端非必需） |
| 10 | 串口 | 已链接但**无实现** | — | 无需处理 |

### 4.1 设备型号全集 **[CONFIRMED，来自随包 `defProfile/`]**

| 型号 | 产品 | 控件 |
|---|---|---|
| `AU05` | **Vibe Key** | **1 旋钮 + 4 键**（main / Talk / Confirm / Cancel），无屏 |
| `AU05-X` | **Vibe Ring** | 双麦 A/B，各带左右插件槽/按键/指示灯 |
| — | Vibe Talk | 2 插件槽 + 2 键 + 2 灯 |
| — | Dial Mini | 1 旋钮 + 1 键 |
| `Dial` | Dial | 3×3 + 1 旋钮 |
| `D200` / `D200H` / `D200X` | 5×3 键盘 |
| `20GBA9901` | Ulanzi Deck 5×3 | 5×3，走老 hidapi |
| TC002 / K6500 | BLE 灯 |

### 4.2 ⚠️ Vibe Key 为什么绕不开 Studio **[CONFIRMED]**

Vibe Key 从 Mac 的视角看是**纯 USB 设备**：

- **没有网络接口**（`ifconfig` 里没有它创建的口）
- **不参与** UDP 55555 发现
- 设备自己上报的 `XXX SN: "" flashId: "4150…1578" MAC: "" Active: true` —— **MAC 为空**
- 整个 App Support 目录树里 **IPv4 字面量 0 命中**

所以对 Vibe Key 来说只有一条路：

> **hook → ustudio-cli → Studio（QLocalServer）→ kwdm → USB HID → 设备指示灯**
>
> 这条链上 **Studio 是必经之路**（CLI 在 Studio 未运行时会直接报
> `Error: Ulanzi Studio is not running. Please start UlanziDeck first.` 并退出）

**这就是"太难用了"的根因。** 想甩掉 Studio，只有两条路：
1. 复刻 `kwdm` 的私有 HID 协议（**推荐**，见 §6）
2. 走标准 HID —— 但那只够读按键，驱动不了指示灯

---

## 5. 待办 / 需要你配合验证

| # | 事项 | 状态 |
|---|---|---|
| 1 | 固定"物理控件 → 键码"映射表 | ✅ **已完成**（受控实验 + 设备配置表双重确认） |
| 2 | 确认按键是否真的注入到系统 | ✅ **已完成**（键 2 打出 Enter、键 3 打出 Esc，实测） |
| 3 | **解密厂商 HID 通道** | ✅ **已完成**（TEA-ECB，密钥与算法全解出） |
| 4 | `ai_index_cfg_t` 状态取值 → LED 颜色 | ⬜ 未做（第五期目标） |
| 5 | 录音/麦克风路径是否也走私有协议 | ⬜ 未做 |
| 6 | xlog 日志解码 | ✅ **已完成**（mars xlog，223/223 条 → 62 MB 明文） |
| 7 | `AU03` / `AU04` 对应哪个 Vibe 型号 | ⬜ 未证实 |
| 8 | **改写设备端按键表** | ✅ **已完成**（`01 06 50 04`，端到端验证生效） |

> 完成项的证据与原始数据见 [05 验证记录](05-verification-log.zh.md)。

---

## 6. 第二期进展：协议语义层已经解出 **[CONFIRMED]**

### 6.1 设备身份

| 项 | 值 |
|---|---|
| flashId（主键） | `<REDACTED>`（前 7 字节 ASCII = `AP53002`，型号前缀） |
| deviceSn | `<REDACTED>` |
| MAC | **空** |
| 固件版本 | dongle `4.4.2` / device `4.4.2` |
| 存储位置 | `config/device_source.json` 的 `Devices[].UUID` |

### 6.2 厂商 HID 通道上传的是 **JSON 字符串**

kwdm 通过回调把明文 JSON 交给应用：

```
DialDeviceManager::onDeviceMessage(const char *deviceId, const char *msg)   ← kwdm SDK 回调
  → parseAndDispatchMessage()
  → DeviceMessageHandler::onRawMessageReceived(flashId, JSON)
  → 按 "type" 分发到 handleKeyEvent / handleBattery / handleIndicatorLightAllParams / ...
```

即 **63 字节的 HID 负载 = 一条 JSON 文本**（这也是为什么它短小、字段名如此直白）。

### 6.3 设备 → 应用：消息词表（从 62 MB 明文日志全量统计）

| `type` | 出现次数 | 说明 |
|---|---|---|
| `deviceKeyEvent` | 15572 | **按键/旋钮事件** |
| `deviceBattery` | 1784 | 电量 |
| `deviceButtonShortcutFunction2` | 1580 | 按键绑定的快捷键码 |
| `deviceActive` | 440 | 在线状态 |
| `deviceHooksMode` | 424 | AI hooks 模式 |
| `deviceSN` | 420 | 序列号 |
| `deviceIndicatorLightAllParams` | 348 | **指示灯全部参数** |
| `deviceSleepTime` | 332+83 | 休眠时间 |
| `deviceMotorStrength` | 332 | 马达强度 |
| `deviceStandbyStatus` | 248 | 待机状态 |
| `dongleVersion` / `dongleSN` | 164 / 160 | dongle 信息 |
| `deviceVersion` | 148 | 固件版本 |
| `deviceMicNRLevel` | 148 | **麦克风降噪等级** |
| `deviceFlashId` | 148 | flashId |

**按键报文实例：**

```json
{ "status" : 1, "access" : 2, "type" : "deviceKeyEvent", "index" : 3 }
```

`index` 实测取值 **0 / 1 / 2 / 3 / 4 / 5**（对应 4 键 + 旋钮 + 按下旋钮），
`status` = 1 按下 / 0 抬起。

**按键绑定报文实例（`content` 是按键码）：**

```json
{ "access" : 0, "content" : "2A",  "type" : "deviceButtonShortcutFunction2", "index" : 3 }
{ "access" : 0, "content" : "105", "type" : "deviceButtonShortcutFunction2", "index" : 5 }
```

### 6.4 应用 → 设备：确认的命令

```json
{ "type" : "deviceHooksMode", "status" : 0|1, "access" : 0 }
```

由 `CliManager::aiHooksStatusFinished → onSetDeviceHooksMode` 触发，
按 `flashId` 定位设备。**这就是"AI hooks 开关"下发到设备的那条命令。**

### 6.5 完整按键处理链（实锤）

```
deviceKeyEvent{index:3,status:1}
 → DeviceMessageHandler::handleKeyEvent       [KeyEvent][Handled] Position: 3 | status: 1
 → UlanziDeck::onDialKeyPressed
 → ProfilePresenter::onDialEvent
 → UlanziDeck::onActionTriggered("com.ulanzi.ulanzideck.system.hotkey")
 → ActionManager::OnTriggerAction
 → HotkeyParser::parse → "F13"
 → InputSimulator::KeyDownEx(CGKeyCode 105, flags 256)
```

**含义**：按键绑定（"快捷键功能"）**存储在设备端固件里**，
设备既可以通过厂商通道上报 `deviceKeyEvent`，**也可以自己直接发标准键盘报文**（接口 2）。
→ 所以 Vibe Key **完全可以脱离 Studio 当一个普通键盘用**。

### 6.6 附加收获：xlog 日志格式已破解 **[CONFIRMED]**

- 73 字节文件头：`magic(1) | seq(u16 LE) | beginHour(1) | endHour(1) | length(u32 LE) | cryptPubkey(64)`
- `0x08` = 同步明文；`0x09` = 异步 **raw DEFLATE**（`deflateInit2(wbits=-15)` + `Z_SYNC_FLUSH`）
- **日志没有加密**（64 字节 ECDH/TEA 密钥字段全零）
- 已全量解码 **223/223 条记录 → 62 MB 明文**
- 解码器：`~/ulanzi-re/tools/xlog_decode.py`
- 这 62 MB 是本项目最有价值的取证素材

---

## 附录：证据来源

- 静态：`~/ulanzi-re/raw/strings_short.txt`、`symbols.txt`、`kwdm.dylib` ObjC 元数据
- 动态：`~/ulanzi-re/raw/cap2.log`（原始）、`cap3.log`（解码版）
- 工具：`~/ulanzi-re/tools/vibekey_probe.py`（hidapi 直连）、`vibekey_decode.py`（可读化抓包）
- 详细拆解：`~/ulanzi-re/findings/binary-surface.md`、`kwdm-protocol.md`
