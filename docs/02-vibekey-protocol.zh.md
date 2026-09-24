# 02 · Vibe Key 协议与终端工具（第二期）

> 🌐 [English](02-vibekey-protocol.md)

> 第一期结论见 [01-ulanzi-studio-scope.md](01-ulanzi-studio-scope.zh.md)。
> 本文记录**已实测跑通**的协议细节与工具。
>
> 📚 文档集：[README](../README.zh.md) · [01 职责边界](01-ulanzi-studio-scope.zh.md) · **02 协议** · [03 工具手册](03-tool-manual.zh.md) · [04 逆向方法论](04-methodology.zh.md) · [05 验证记录](05-verification-log.zh.md) · [10 输入运行时](10-input-runtime.zh.md)

---

## 0. 一句话结论

**Ulanzi Vibe Key（AU05）可以完全脱离 Ulanzi Studio 使用。**
不需要 Studio、不需要网络、不需要任何第三方库 —— 一个 800 行的 Python 文件就够了。

---

## 1. 硬件

| 项 | 值 |
|---|---|
| 产品 | Ulanzi Vibe Key（型号 **AU05**） |
| USB | VID `0xFFF1` / PID `0x00DD`，复合设备 |
| 序列号 | `202606031150` |
| 固件 | dongle `4.4.2` / device `4.4.2` |
| flashId | `<REDACTED>`（前 7 字节 ASCII = `AP53002`，型号前缀） |
| deviceSn | `<REDACTED>` |
| MAC | **空**（无网络接口） |
| 控件 | **3 个键（上下排列）+ 1 个旋钮 + 1 个电源键** |

### HID 接口（实测描述符）

**接口 2** —— 标准 HID，165 字节描述符，三个集合共用一个接口：

| Report ID | 集合 | 布局 |
|---|---|---|
| `0x01` | Consumer | 16 bit 多媒体键码 |
| `0x02` | Mouse | 3 bit 按键 + 8 bit X + 8 bit Y + 8 bit 滚轮 + 8 bit AC Pan |
| `0x03` | Keyboard | 8 bit 修饰位 + 8 bit 保留 + **6 × 8 bit 键码** + 5 bit LED 输出 |

**接口 3** —— 厂商私有，36 字节描述符：

```
06 fc ff   Usage Page = 0xFFFC
09 01      Usage
a1 01      Collection (Application)
09 02  85 55
75 08  95 3f  81 02   → Input   Report ID 0x55，63 字节
09 03  75 08  95 3f  91 02   → Output  Report ID 0x55，63 字节
```

> ⚠️ 两个接口都在**同一个 USB 接口 2/3 上**，但 IOKit 里是**两个独立的 IOHIDDevice**。

---

## 2. 传输层：TEA 加密

接口 3 的 63 字节负载是 **TEA 加密**的。

| 项 | 值 |
|---|---|
| 算法 | **TEA**（Tiny Encryption Algorithm，**不是 XTEA**） |
| 模式 | **ECB**，8 字节分组，就地加密，无 IV、无填充 |
| 轮数 | **32** |
| delta | `0x9E3779B9` |
| 密钥（16 B） | `ca ba a5 ca 6d 8a 2a bc ba 9e 5a ca ca 8b b8 9b` |

密钥位置：`kwdm.dylib` 全局 `_gaui_custom_encrypt_keys`
（arm64 `__DATA,__data+0x4a580`，x86_64 `+0x4e740`）。

**验证方式（决定性）**：

```
TEA_ECB_Enc(00 00 00 00 00 00 00 00) == 38 90 c4 99 a3 60 aa ad
```

那串曾经神秘兮兮的"固定尾串"，**就是全零分组的密文**。它从来不是常量。

### 63 vs 64 的关键细节

* 明文结构体是 **64 字节**，加密也是 **8 个完整分组（64 字节）**
* 但 HID 报文总长也是 64 字节 —— **包含 1 字节 report ID**
* 所以线上只发 `ct[0..62]`，**第 8 个分组的最后一个字节永远丢失**

| 方向 | 做法 |
|---|---|
| **解密** | 只解 **7 个分组（56 字节）**；末 7 字节是不可解的填充，当作 0 |
| **加密** | 加密完整 64 字节，**只发前 63 字节** |

TEA 实现见 [vibekey.py](../vibekey.py) 顶部，或 `~/ulanzi-re/tools/tea_kwdm.py`。

---

## 3. 帧格式

```
frame[0]        帧头：cmd = frame[0] & 0x1F，高 3 位是标志
frame[1]        配置头 { grp = b & 0x0F, sub = b >> 4 }
frame[2]        opcode
frame[3]        access：0x01 = 读，0x04 = 写，其他值见下
frame[4..]      参数
```

### 方向判定

| 标志 | 含义 |
|---|---|
| `frame[0] & 0x80` = 1（即 `0x81`） | **设备 → 主机（回复）** |
| `frame[3] & 0x10` = 1（即 `0x11`） | 同上，回复标记 |

请求 `01 0b 89 01` → 回复 `81 0b 89 11`。

### cmd 取值

| cmd | 处理器 |
|---|---|
| `0x01` | 设备消息 `handleDeviceMessage` |
| `0x06` | USB 消息 `handleUsbMessage` |
| `0x0B` | 通知 `handleNoticeMessage` |
| `0x0C` / `0x0D` | BLE 短/长音频 |
| `0x0E` | USB 音频 |
| `0x15` | 上传图片 |
| `0x1E` / `0x1F` | dongle / 设备升级 |

### 通知子类型（cmd = 0x0B，取 `frame[1]`）

| 子类型 | 含义 |
|---|---|
| `0x10` | 按键事件：状态在 `frame[3]`，AU05 物理控件索引在 `frame[4]`；见 [07 §4](07-heartbeat-investigation.zh.md) |
| `0x7B` | 心跳（`frame[2..7]` 是计数/状态） |
| `0x0B` | 通知 B |
| `0x0D` | 通知 D |

---

## 4. 命令表（实测可用）

完整 85 条见 `~/ulanzi-re/raw/kwdm_message_builders.txt`。
下面是 Vibe Key 上**实际验证过**的：

### 只读查询（安全，随时可发）

| 名称 | 报文字节 | 实测回复 |
|---|---|---|
| 设备在线状态 | `06 03 0a 01` | `01` = 在线 |
| 设备 flashId | `01 04 0b 01` | ⟨16 字节，已脱敏⟩，前 7 字节 = `AP53002` |
| 设备 SN | `01 01 0b 01` | `<REDACTED>`（分两包） |
| 固件版本 | `01 04 04 01` | `… 04 04 02 …` = 4.4.2 |
| dongle 版本 | `06 02 03 01` | `… 04 04 02 …` = 4.4.2 |
| 电量 | `01 01 02 01` | `dd 0d 1e 00 f1 01`（`0x0ddd` ≈ 3549 mV） |
| Hooks 模式 | `01 0b 89 01` | 全 0 |
| 指示灯参数 | `01 0b 88 01` | `00 00 02 07 02 \| 0a 02 07 02 02 \| 0a 02 07 02 01 \| 0a 02 07 02 00` |
| 麦克风降噪 | `01 01 90 01` | `00 64 00 64` → 双麦各 低=0 高=100 |
| 全部按键功能 | `01 06 31 01` | 全 0（未配置） |
| AI 按钮功能 | `01 06 21 01` | 全 0 |
| 马达强度 | `01 06 40 01` | 全 0 |
| 旋钮开关 | `01 01 34 01` | 全 0 |

### 电量回复字段

[CONFIRMED] 只读请求为 `01 01 02 01`，回复前缀为 `81 01 02 11`。下表的 payload 偏移从明文帧第 4 字节开始；Studio 的 `kwdm.dylib` 电量回复处理器按小端 16 位读取电压与电量字段，并非单字节。

| Payload 偏移 | 明文帧偏移 | 字段 | 样本值 |
|---|---|---|---|
| 0–1 | 4–5 | `voltage`，小端毫伏值 | `f6 0c` = 3318 mV |
| 2–3 | 6–7 | `battery`，小端百分比 | `0a 00` = 10% |
| 6 | 10 | `charging`，0 = 未充电，1 = 充电中 | `01` = 充电中 |

23:25:12 的样本前缀为 `81 01 02 11 f6 0c 0a 00 c8 01 01 00 ...`，采集时设备在线。[CONFIRMED] Studio 直接将 `battery` 整数传给电量图标，限制上限为 100，并按 10/25/50/75 分档。[处理器与界面反汇编](evidence/2026-09-21-battery-disassembly.log) 确认其百分比标度，并非由电压估算。Olanzi 将超出 0–100 的百分比及非 0/1 的充电字段视为未知。见 [05 §9.10](05-verification-log.zh.md#910-只读电量状态与主窗口显示)。

### 写入类（⚠️ 已定位但尚未实测）

| 名称 | 报文字节 |
|---|---|
| **设置按键快捷功能** | `01 06 50 04` + `num/pages/values/signs` |
| 设置按键功能 | `01 06 10 04` + `funcIndex` |
| 设置 AI 按钮功能 | `01 06 21 04` + `index` |
| 设置指示灯参数 | `01 0b 88 04` + `which/value` |
| 设置 Hooks 模式 | `01 0b 89 04` |
| 设置亮度 | `01 06 20 04` |
| 设置麦克风降噪 | `01 01 90 04` + `low/high` |

---

### ⚠️ dongle 级 vs 设备级（`cmd = 0x06` vs `0x01`）

`cmd` 决定这条报文归谁处理，**排查问题时这是第一分界线**：

| cmd | 处理者 | 设备关机时 |
|---|---|---|
| `0x06` | **dongle**（USB 那一端） | ✅ 照常应答 |
| `0x01` | **Vibe Key 本体**（走无线） | ❌ 完全无应答 |

**实测**：设备关机时跑 `--probe`，17 条查询只有 2 条回复，
且恰好都是 `0x06`（`设备在线状态`、`dongle 版本`）。

### 设备在线状态的判读

```
→ 06 03 0a 01                    查询在线状态
← 06 03 0a 11 ⟨status⟩ 00 00 …   status = 0x01 在线 / 0x00 离线
```

⚠️ **注意**：这条查询本身由 dongle 应答，所以**永远会有回复** ——
真正要看的是回复里那个 `status` 字节。别把"有回复"当成"设备在线"。

---

### Studio 专用心跳

[CONFIRMED] `+[MessageHelper deviceHeartbeatMessage]` 构造 `06 01 23 00 01`，随后为 59 个零字节；Studio 后台 worker 约每秒发送一次。它与旧工具的 Hooks 查询 `01 0b 89 01` 不同。该心跳尚无已验证的应答约定，因此应依据上面的明确状态字节判断本体在线，而非心跳应答。

[INFERRED] 缺失该心跳可能影响休眠，但实测 60 秒空闲与 Hooks 窗口结束均在线，长期防休眠效果仍未验证。反汇编与受控测试限制见 [07 心跳调查](07-heartbeat-investigation.zh.md)。

[CONFIRMED] 2026-09-21 后续对照发现，持续发送此心跳会让普通键停止标准 HID 直出，按键改为 `8b 10` 厂商事件；保留厂商连接但停止心跳后 Enter 恢复。`frame[2]` 是逻辑动作号，不能作 HID 键码；`frame[3]` 是按下/松开，`frame[4]` 是 AU05 物理控件 index。主机应使用已确认设备键位转发普通键和 Fn，新转发已验证 Enter 与顶部 Fn 的系统效果；其余控件的全部系统动作仍待验证。

## 5. 控件映射（实测确认）

**验证方法**：让你按固定顺序操作（按下旋钮 → 键1 → 键2 → 键3 → 右拧×3 → 左拧×3 → 长按旋钮），
与捕获到的事件流做 1:1 时间对齐。结果完全吻合。

| 控件 | 报码 | HID 含义 | 说明 |
|---|---|---|---|
| **键 1（上）** | `0x01` | ErrorRollOver | **无效码，系统会忽略** |
| **键 2（中）** | `0x28` | Enter | |
| **键 3（下）** | `0x29` | Esc | |
| **旋钮 → 右拧** | `0x4F` | RightArrow | 每格一次 |
| **旋钮 ← 左拧** | `0x2A` | Backspace | 每格一次 |
| **旋钮 按下** | `0x46` | PrintScreen | 短按/长按都发 |
| **电源键** | — | — | **短按无报文**（由设备硬件处理） |

### ⭐ 一个意外但重要的规律

**按压时长可以区分旋钮转动和按键：**

| 类型 | 时长 |
|---|---|
| 旋钮转动（瞬时脉冲） | **0～10 ms** |
| 人手按键 | **80～2000 ms** |

阈值取 **25 ms** 非常可靠。这让程序不需要预先知道映射就能分类事件。

### ⚠️ 键 1 是"残废"的

键 1 发 `0x01`（ErrorRollOver）—— **一个协议上无效的键码，操作系统直接丢弃**。

这不是 bug，是**设计如此**：键 1 就是 AI 对话键，天生只为 Studio 服务。
脱离 Studio，**键 1 等于没有**。

> 这解释了 Ulanzi 为什么一定要用户装 Studio —— 主功能键被绑死在自家软件上了。
> **但这是可以改的**，见下文下一步。

---

## 6. 按键配置读写（设备端可编程按键表）⭐

**这是"甩掉 Studio"的关键能力：设备内部的按键表可以被任意改写。**

### 帧格式

| 操作 | 报文 |
|---|---|
| **读** | `→ 01 06 50 01 <index>` |
| | `← 81 06 50 11 <index> 01 <num> <类型\|sign<<7> <键码> ×num` |
| **写** | `→ 01 06 50 04 <index> 01 <num> <类型\|sign<<7> <键码> ×num` |
| | `← 81 06 50 14 …` ← `access = 0x14` 表示写确认 |

| 字段 | 含义 |
|---|---|
| `index` | 控件编号 |
| `num` | 这一项包含几个按键（**支持组合键**） |
| `类型` | `0x02` = 普通按键，`0x03` = 系统/多媒体 |
| `sign` | 类型字节的最高位（bit 7） |
| `键码` | HID Usage ID |

### index ↔ 控件（出厂值）

| index | 控件 | 出厂键码 |
|---|---|---|
| 0 | 键 1（上） | `0x01` ErrorRollOver（**无效码**） |
| 1 | 键 2（中） | `0x28` Enter |
| 2 | 键 3（下） | `0x29` Esc |
| 3 | 旋钮 按下 | `0x46` PrintScreen |
| 4 | 旋钮 → 右拧 | `0x4F` RightArrow |
| 5 | 旋钮 ← 左拧 | `0x2A` Backspace |

> index 6、7 存在但未使用。

### ⭐ 实测验证（端到端闭环，四次全部通过）

| 步骤 | 结果 |
|---|---|
| 1. 读 index 0 | `[0x02, 0x01]` |
| 2. 写 `01 06 50 04 00 01 01 02 68` | 回复 `81 06 50 14 00 01 01 02 68` |
| 3. 读回 index 0 | `[0x02, 0x68]` ✅ 已落盘 |
| 4. **按"键 1"** | **设备真的发出 `0x68` = F13** ✅✅ |

**结论：`类型=0x02` 时，第二个字节存储该控件分配的 HID 键码。直出模式由设备上报；心跳/厂商事件模式由主机从已确认映射中查询。**

### 命令行

```bash
python3 vibekey.py --keys                                # 列出六个控件当前配置
python3 vibekey.py --set-key 0=F13                       # 键1 改成 F13
python3 vibekey.py --set-key 0=enter --set-key 2=0x04    # 一次改多个
```

键码三种写法都接受：`0x68` / `104` / `F13`（也认 `enter`、`esc`、`lctrl` 等名字）。

### 尚未验证

- `num > 1` 的组合键实际行为（推测 `[(0x02,0xE0),(0x02,0x06)]` = Ctrl+C）
- `类型 = 0x03`（系统/多媒体）的取值范围
- `sign` 位（bit 7）的语义

---

## 7. 数据流向与心跳模式

```
未发送 Studio 专用心跳 → 标准 HID 直出（早期实测状态）
持续发送 Studio 专用心跳 → 厂商按键事件 → 按物理 index 查已确认设备映射 → 主机转发
```

**历史实测**：Studio 退出且替代程序未发送专用心跳时，按键时段内厂商通道没有 `deviceKeyEvent`。该观察不等于“只有官方 Studio 进程在跑才会有厂商按键事件”。

[CONFIRMED] Olanzi 自行发送专用心跳时也观察到按键改走厂商通道，停止心跳后 Enter 直出恢复。直接读标准 HID 的早期方法仅适用于当时的直出状态；启用心跳的替代客户端还需要解释厂商事件并执行主机按键转发，见 [07 §4](07-heartbeat-investigation.zh.md)。

---

## 8. 终端工具 vibekey.py

零依赖（Python 3 标准库 + 系统 IOKit），**不读 Ulanzi Studio 的任何文件**。

```bash
cd <项目目录>
python3 vibekey.py --probe --poll 2
```

| 参数 | 作用 |
|---|---|
| `--probe` | 启动时读一遍设备状态 |
| `--poll 2` | 每 2 秒读取 Hooks 模式；防休眠效果未验证 |
| `--learn` | 打印每帧原始密文/明文 |
| `--raw` | 心跳也全打出来 |
| `--descriptor` | dump HID 报文描述符 |
| `--list` | 只列接口 |
| `--log 文件` | 事件同时写日志（默认 `/tmp/vibekey-events.log`） |
| `--echo` | 保留终端回显（默认关闭，避免按键字符冲乱输出） |
| `--keys` | **列出设备端按键配置** |
| `--set-key IDX=VALUE` | **改控件的 HID 键码**（可重复） |
| `-t 30` | 只跑 30 秒 |

输出示例：

```
13:36:28.960 按键   ⌨ 旋钮 按下    PrintScreen    178 ms
13:36:32.822 旋钮   ⟳ 旋钮 ← 左拧   Backspace        2 ms
13:36:33.778 旋钮   ⟳ 旋钮 → 右拧   RightArrow       3 ms
13:36:35.209 按键   ⌨ 键 1 (上)    ErrorRollOver  132 ms
13:36:36.164 按键   ⌨ 键 2 (中)    Enter          147 ms
13:36:36.908 按键   ⌨ 键 3 (下)    Esc             90 ms
```

### 实现要点（踩过的坑）

1. **不能用 `IOHIDManagerOpen`** —— 它要求所有匹配设备同时打开，任何一个失败
   （被独占 `0xE00002C5` 或无权限 `0xE00002E2`）整个调用就失败。
   → 必须用 `IOServiceGetMatchingServices` + 逐个 `IOHIDDeviceOpen`。

2. **输入监控权限是硬门槛** —— 没权限时 `IOHIDDeviceOpen` 返回 `0xE00002E2`，
   此时**按键一条都收不到**，但设备照样往系统注入按键。
   → 程序必须**大声报错**，不能静默跳过。

3. **按键会真的打进焦点窗口** —— 键 2 打 `Enter`、键 3 打 `Esc`、旋钮打方向键/退格。
   → 默认 `stty -echo`，否则屏幕会被冲乱。

4. **没有报文不代表休眠** —— `--poll` 读取 Hooks 模式，与 Studio 专用心跳不同，防休眠效果未验证。见 [07 心跳调查](07-heartbeat-investigation.zh.md)。

5. **两个实例可以同时打开**（都是 `kIOHIDOptionsTypeNone`，非独占），不会互相打架。

---

## 9. 未解 / 下一步

### 未解

- 电源键长按是否关机会不会发报文（未测，有风险）
- 通知子类型 `0x0B` / `0x0D` 的完整语义
- 指示灯枚举在本机固件上的实际效果、时间单位和断电后的持久化；字段布局已由源码交叉确认，见下文
- AI 状态 → 指示灯的具体数值映射
  （`UlanziDeck::updateIndicatorLightByState` / `LedIndicator::getConfigForState`）
- 组合键（`num > 1`）与 `类型=0x03` 的实际行为

[CONFIRMED] 源码交叉确认：[VibeKey Lite 字段表](https://github.com/arumwu/vibekey-lite/blob/43fb9017790838c454fc2159f3608d576c5c6e3a/docs/protocol.md#L270-L306) 与 [OpenVibeKey 构帧](https://github.com/palaemonboy/OpenVibeKey/blob/c9970faa126cb2ee355571ecd79901e397f49574/native/VibeKit/Sources/VibeKitHID/VibeKitDevice.swift#L92-L126) 一致使用读取 `01 0b 88 01`、写入 `01 0b 88 04`。明文偏移 4 为字段掩码，5 为灯索引，6 为全局模式，7 为全亮亮度；偏移 `8 + 5*i` 起有四组 `[type, workTime, breatheLevel, breatheBrightness, alwaysOnBrightness]`，对应掩码 `0x04`、`0x08`、`0x10`、`0x20`、`0x40`，全局模式与亮度掩码为 `0x01`、`0x02`。此前“疑似三组”的解释已被此源码布局取代。

[CONFIRMED] 当前实现依据下文 Studio 亮度范围与 [OpenVibeKey 模式/类型枚举](https://github.com/palaemonboy/OpenVibeKey/blob/c9970faa126cb2ee355571ecd79901e397f49574/native/VibeKit/Sources/VibeKitApp/ContentView.swift#L435-L478)，提供全局模式 0/1/2（全灭/全亮/工作）、全亮与逐灯常亮/呼吸亮度 0–20（整数档位），四灯按键 1/2/3/旋钮顺序可设灭或常亮，仅键 1 可选呼吸。打开灯效标签页时自动读取，无草稿时切回会重新读取；连接未就绪或操作忙时延后，有草稿时保留编辑。先读改写并保留全部四灯的其他参数，写后再次 GET 核对，不做后台灯效轮询，读取失败不循环查询。应用失败保留草稿，以当前回读作为下一次显式重试基线，不自动重发。[INFERRED] 上述物理灯顺序与枚举语义沿用参考实现，尚未在本机硬件上验证；不承诺持续呼吸、时间单位或持久化。使用入口见 [09 · 原生 App](09-native-macos.zh.md)。

[CONFIRMED] 原 Studio 静态证据：本机 `/Applications/Ulanzi Studio.app/Contents/Resources/Ulanzi/UlanziDeck/version.txt` 为 `version=3.3.9`。其 `Contents/MacOS/UlanziDeck` 的 `SettingDialog::SettingDialog(QString, QWidget*)` 在 `0x1003ac404` 至 `0x1003ac43c` 将灯效滑块设为最小 0、最大 20、步长 1。`SettingDialog::onLightBrightnessChanged()` 在 `0x1003b3974` 至 `0x1003b39bc` 将原始滑块值用于工作模式旋钮（index 3）的常亮亮度，以及按键（index 0/1/2）的呼吸亮度；在 `0x1003b3a74` 至 `0x1003b3a80` 写全亮亮度，不做比例换算。`Contents/Frameworks/kwdm.dylib` 的 `+[MessageHelper setDeviceIndicatorLightWorkModeBreatheBrightnessLevel:level:]` 与 `+[MessageHelper setDeviceIndicatorLightWorkModeAlwaysOnBrightnessLevel:level:]` 分别以掩码 `0x20`、`0x40` 写偏移 `11 + 5*i`、`12 + 5*i`。这些证据确认原 Studio 的使用范围与工作模式调光路径，不证明每档物理效果或光强线性；0–20 不能标为百分比。原生 App 按当前逐灯类型编辑对应亮度，保留另一类型亮度与时间参数。

[CONFIRMED] 本机只读查询收到 `81 0b 88 11 00 00 02 07 02 0a 02 07 02 02 0a 02 07 02 02 0a 02 07 02 01 0a 02 07 02`，确认读取 access 为 `0x11`，模式原值为 2、亮度原值为 7、四灯类型原值为 2/2/2/1。亮度 7 是原 Studio 采用的 0–20 范围内的档位，不是百分比；它对应的实际光强未测。超出已知范围的读数仍须原样保留。读取到类型 2 不证明该灯实际持续呼吸。

[CONFIRMED] 2026-09-24 本机模式写入与恢复回读：从模式 2 以掩码 `0x01` 改为 0，GET 确认偏移 6 为 0，偏移 7…27 不变；随后恢复模式 2，GET 确认偏移 6…27 全部与原始值一致。这确认模式字段的读写及本次恢复，不代表已观察实体灯光变化；逐灯类型写入仍待真机验证；亮度验证见下文。

[CONFIRMED] 同日亮度写入测试：全亮亮度通过掩码 `0x02` 从 1 改为 2、键 1 呼吸亮度通过掩码 `0x20` 从 7 改为 8，均由 GET 确认。旋钮常亮亮度通过掩码 `0x40`、focus index 3、偏移 27 从 2 分别尝试改为 3、1、0、20，GET 均仍为 2，其他字段不变。这保留了此前回读不一致的事实，但不能推出写入未生效：后续完整负载 `0x40`、完整负载 `0x7c` 与原 Studio 风格稀疏负载均收到 access `0x14`、值 8 的 ACK，而 GET 仍为 2。用户现场明确确认，旋钮亮度 0 → 20 时明显先暗后亮；该写入有效，原先把 GET 不变当作失败属于误判。随后发送值 2 的恢复命令并收到 ACK；由于 GET 此字段不可靠，不能仅凭 GET 宣称恢复了此前真实光强。关键帧见[灯效验证记录](evidence/2026-09-24-knob-brightness-readback.log)。

[CONFIRMED] 修复对每条请求等待匹配命令、字段掩码、灯索引与选中字段值的 `0x14` ACK。仅旋钮常亮亮度不依赖 GET 偏移 27 判断成功，以本连接内最近 ACK 确认的命令值供显示；原始 GET 保留，不伪造成新读数。首次连接无确认值时显示 `—`，重连或离线清除会话值；其他字段继续 GET 核对。会话值表示本应用最近确认的设置，不能跟踪外部工具的修改，不证明断电持久化或全部亮度档位的物理效果。

### 下一步（按价值排序）

1. ~~把键 1 重新编程~~ ✅ **已完成**，见第 6 节
2. **验证指示灯** —— 原生 App 已接入 `setDeviceIndicatorLight*` (`01 0b 88 04`) 的手动调节与回读核对；
   本机物理灯效、持久化及 AI 状态联动仍待验证
3. **Ollama / 脚本回调** —— 既然按键是标准键盘，可以直接接 shell 脚本
4. **做成常驻服务** —— 替代 Studio 的"AI hooks → 指示灯"链路

---

## 10. 证据与产物位置

| 内容 | 路径 |
|---|---|
| 终端工具 | [vibekey.py](../vibekey.py) |
| TEA 编解码器 | `~/ulanzi-re/tools/tea_kwdm.py` |
| 命令表（85 条） | `~/ulanzi-re/raw/kwdm_message_builders.txt` |
| 结构体布局（109 条） | `~/ulanzi-re/raw/kwdm_struct_layout.txt` |
| kwdm 逆向报告 | `~/ulanzi-re/findings/kwdm-protocol.md` |
| xlog 解码后的 62 MB 日志 | `~/ulanzi-re/raw/logs_decoded.txt` |
| 实测事件日志 | `/tmp/vibekey-events.log` |
