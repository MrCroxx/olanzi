# 03 · vibekey.py 工具手册
> 🌐 [English](03-tool-manual.md)

> 一个文件，零第三方依赖，直接和硬件对话。
> 源码：[vibekey.py](../vibekey.py)

> 📚 文档集：[README](../README.zh.md) · [01 职责边界](01-ulanzi-studio-scope.zh.md) · [02 协议](02-vibekey-protocol.zh.md) · **03 工具手册** · [04 逆向方法论](04-methodology.zh.md) · [05 验证记录](05-verification-log.zh.md) · [10 输入运行时](10-input-runtime.zh.md)

---

## 1. 安装

没有安装步骤。

```bash
cd <项目目录>
python3 vibekey.py --help
```

依赖只有 **Python 3 标准库** + 系统自带的 **IOKit / CoreFoundation**（通过 `ctypes` 调用）。
**不需要 `pip install`，不需要 Ulanzi Studio，不需要后台服务。**

### 唯一的前置条件：输入监控权限

macOS 从 10.15 起，读键盘类 HID 接口需要用户显式授权。

> **系统设置 → 隐私与安全性 → 输入监控 → 打开你用的终端 → 完全退出并重启该终端**

**权限没开时会怎样？**

```
13:33:54.756 ✗ 打不开 AU05  输入接口  无权限 (kIOReturnNotPermitted)

  ⚠ 输入接口没打开，按 Vibe Key 不会有任何输出！
    请到 系统设置 → 隐私与安全性 → 输入监控，
    把你运行本程序的终端（如 iTerm2）打开，然后重启终端。
    （程序会持续重试，权限开放后会自动接上）
```

程序**不会静默失败** —— 这是刻意的设计（早期版本会默默跳过，导致"按了没反应"却查不出原因）。
它会每 2 秒重试一次，**权限一开就自动接上，不用重启程序**。

---

## 2. 四种使用模式

### 2.1 监控模式（最常用）

```bash
python3 vibekey.py --probe --poll 2
```

| 参数 | 作用 |
|---|---|
| `--probe` | 启动时先读一遍设备状态（固件/电量/降噪/SN…） |
| `--poll 2` | 每 2 秒读取 Hooks 模式；防休眠效果未验证 |

**`--poll` 做什么？** 它周期性读取 Hooks 模式。dongle 有回复不代表本体清醒。
每 2 秒查询可正常往返；Studio 专用心跳与测量限制见 [07 心跳调查](07-heartbeat-investigation.zh.md)。

### 2.2 配置模式

```bash
python3 vibekey.py --keys                        # 列出六个控件的当前配置
python3 vibekey.py --set-key 0=F13               # 键1 → F13
python3 vibekey.py --set-key 0=enter --set-key 2=0x04    # 一次改多个
```

配置模式下**日志自动静音**，只输出结果表格：

```
  设备端按键配置（index 0-5 = 六个控件）

  index     控件               类型           键码
  ──────────────────────────────────────────────────────────
  0         键 1 (上)          按键           F13 0x68
  1         键 2 (中)          按键           Enter 0x28
  2         键 3 (下)          按键           Esc 0x29
  3         旋钮 按下            按键           PrintScreen 0x46
  4         旋钮 → 右拧          按键           →右方向键 0x4F
  5         旋钮 ← 左拧          按键           Backspace 0x2A
```

`--set-key` 会**自动读原值 → 写新值 → 再读回确认**：

```
  修改设备端按键配置

  0  键 1 (上)        F13                    →  0x01 (无效码/未配置) 0x01   ✔ 已写入并确认
```

**写入是持久的**（存在设备里），断电重连依然生效。

配置完若不加 `--poll`/`-t`，程序会立即退出。

### 2.3 诊断模式

```bash
python3 vibekey.py --list           # 只列 HID 接口
python3 vibekey.py --descriptor -t 2   # dump HID 报文描述符
python3 vibekey.py --probe -t 3     # 只读一遍设备状态
```

### 2.4 学习模式（看协议）

```bash
python3 vibekey.py --learn --raw -t 30
```

额外打印每一帧的**原始密文和明文**：

```
13:44:21.333 厂商 ← 读 按键快捷功能  00 01 01 02 68
               CT 5d 07 5c ae 29 61 af 33 38 90 c4 99 a3 60 aa ad ...
               PT 81 06 50 11 00 01 01 02 68 00 00 00 00 00 00 00 ...
```

| 字段 | 含义 |
|---|---|
| `CT` | CipherText，线上收到的原始密文（56 字节可解） |
| `PT` | PlainText，TEA 解密后的明文帧 |

---

## 3. 全部参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--list` | | 只列出设备接口，然后退出 |
| `--probe` | | 启动时主动查询设备状态（**只读**，安全） |
| `--keys` | | 列出设备端按键配置 |
| `--set-key IDX=VALUE` | | 改控件的 HID 键码，**可重复** |
| `--descriptor` | | dump HID 报文描述符 |
| `--learn` | | 学习模式：打印原始密文/明文 |
| `--raw` | | 显示每一条心跳（默认每 10 条只显示 1 条） |
| `--poll 秒` | `0` | 每隔 N 秒发保活查询，推荐 `2` |
| `-t, --duration 秒` | `0` | 运行时长，`0` = 一直跑 |
| `--log 文件` | `/tmp/vibekey-events.log` | 事件同时写入日志（追加） |
| `--echo` | 关 | 保留终端回显。**默认关闭**，避免按键字符冲乱输出 |
| `--no-color` | 关 | 关闭 ANSI 颜色 |

### 键码写法

`--set-key` 的 VALUE 支持三种：

| 写法 | 例 |
|---|---|
| 十六进制 | `0x68` |
| 十进制 | `104` |
| 名称 | `F13`、`enter`、`esc`、`backspace`、`lctrl`、`right`、`pageup`… |

常用键码速查：

| 键 | 码 | 键 | 码 |
|---|---|---|---|
| `a`–`z` | `0x04`–`0x1D` | `F1`–`F12` | `0x3A`–`0x45` |
| `1`–`9`,`0` | `0x1E`–`0x27` | `F13`–`F24` | `0x68`–`0x73` |
| `Enter` | `0x28` | `LeftCtrl` | `0xE0` |
| `Esc` | `0x29` | `LeftShift` | `0xE1` |
| `Backspace` | `0x2A` | `LeftAlt` | `0xE2` |
| `Tab` | `0x2B` | `LeftGUI/⌘` | `0xE3` |
| `Space` | `0x2C` | `RightCtrl` | `0xE4` |
| `PrintScreen` | `0x46` | `RightShift` | `0xE5` |
| `RightArrow` | `0x4F` | `RightAlt` | `0xE6` |
| `LeftArrow` | `0x50` | `RightGUI/⌘` | `0xE7` |

> **建议**：优先用 `F13`–`F24` 这类 macOS 默认无功能的键，
> 避免改完之后打字误触发。想让它干活，再用 Karabiner / skhd / Hammerspoon 绑定。

---

## 4. 输出解读

### 4.1 按键事件

```
13:29:21 按键   ⌨ 键 2 (中)        Enter                      400 ms
13:29:26 旋钮   ⟳ 旋钮 → 右拧       RightArrow                   4 ms
```

| 列 | 含义 |
|---|---|
| 时间 | 精确到毫秒 |
| 类别 | `按键` / `旋钮` |
| 图标 | `⌨` 按键 · `⟳` 旋钮转动 |
| 控件名 | 从 index 映射表查出来的 |
| 原始码 | HID 名称 + `0x` 值 |
| 时长 | 按住的毫秒数 |

### ⭐ 时长能区分控件类型

实测发现的规律：

| 类型 | 按压时长 |
|---|---|
| **旋钮转动**（瞬时脉冲） | **0 – 10 ms** |
| **人手按键** | **80 – 2000 ms** |

程序用 **25 ms** 作为阈值自动分类，所以**不需要预先知道映射**就能分开这两类事件。

### 4.2 厂商通道事件

```
13:44:21.333 厂商 ← 读 按键快捷功能  00 01 01 02 68     cmd=0x01 flags=4 len=63
```

- `←` = 设备回复，`→` = 主机发出
- `读` / `写` = access 字段
- 后面是解码后的数据
- `cmd` / `flags` / `len` 是原始帧信息

常见的心跳：

```
厂商 → 通知/心跳 ctr=2135102066141   cmd=0x0B flags=0 len=63
```

### 4.3 会话统计

退出时（`Ctrl-C` 或 `-t` 到时间）打印：

```
  本次会话统计
  ────────────────────────────────────────────────
  按键 Enter                                  3
  旋钮 RightArrow                             10
  （保活往返）                                  5
  时长                                    30.2s
```

---

## 5. 日志

默认**始终**写日志到 `/tmp/vibekey-events.log`（追加模式，自动剥掉 ANSI 颜色码）。

**为什么需要它？** 按键会真的注入终端，把屏幕冲乱 —— 日志文件永远是干净的。

```bash
python3 vibekey.py --poll 2 --log ~/vibekey.log
```

> 程序启动时会往日志里写一行 `===== 2026-09-21T13:44:21 =====` 作为分隔。

---

## 6. 故障排查

| 现象 | 原因 | 解决 |
|---|---|---|
| `✗ 打不开 … 无权限 (kIOReturnNotPermitted)` | 缺输入监控权限 | 系统设置 → 隐私与安全性 → 输入监控 → 打开终端 → **重启终端** |
| `✗ 打不开 … 被独占 (kIOReturnExclusiveAccess)` | 别的进程独占了 | `pkill -f UlanziDeck`，然后重跑 |
| `没有找到 Vibe Key` | dongle 没插好 | 拔插 dongle，或 `python3 vibekey.py --list` 确认 |
| 按了键没反应 | 输入接口没打开 | 看启动输出有没有 `● 已连接 … 输入接口` |
| 屏幕被按键字符冲乱 | 终端回显 | 默认已关闭；如果你用 `--echo` 就会出现 |
| 键 1 按了没反应 | **它是无效码 `0x01`** | 用 `--set-key 0=F13` 改成有用的键 |
| 改了键没生效 | 读回确认失败 | 重跑 `--keys` 看配置表；必要时 `--set-key` 再写一次 |
| `--keys` 六个控件全是 `(无回复)` | **Vibe Key 本体没开机**（dongle 是好的） | 长按设备电源键开机；原理见 [02 §4](02-vibekey-protocol.zh.md) |

### 应急恢复

如果键被改乱了，回到出厂值：

```bash
python3 vibekey.py \
  --set-key 0=0x01 \
  --set-key 1=0x28 \
  --set-key 2=0x29 \
  --set-key 3=0x46 \
  --set-key 4=0x4F \
  --set-key 5=0x2A
```

---

## 7. 实现要点（踩过的坑）

这部分是给想改源码的人看的。

### 7.1 不能用 `IOHIDManagerOpen`

`IOHIDManagerOpen(mgr, 0)` 会**一次性打开所有匹配设备**，只要其中任何一个失败
（被独占 `0xE00002C5`、或无权限 `0xE00002E2`），**整个调用就失败**。

✅ 正确做法：`IOServiceGetMatchingServices` 枚举 → 对每个 `IOService` 单独
`IOHIDDeviceCreate` + `IOHIDDeviceOpen`。

```python
matching = iok.IOServiceMatching(b"IOHIDDevice")
cf.CFDictionarySetValue(matching, cfstr("VendorID"), cfnum(VIBE_VID))
cf.CFDictionarySetValue(matching, cfstr("ProductID"), cfnum(VIBE_PID))
iok.IOServiceGetMatchingServices(kIOMainPortDefault, matching, ctypes.byref(it))
# 逐个 IOHIDDeviceCreate / IOHIDDeviceOpen
```

### 7.2 63 字节 vs 64 字节

帧结构体是 **64 字节**，TEA 也是按 **8 个完整分组**加密的。
但 HID 报文总长只有 64 字节，其中 **1 字节是 report ID**。

| 方向 | 做法 |
|---|---|
| **解密** | 只解 **7 个分组（56 字节）**；末尾 7 字节是不可解的填充，当 0 处理 |
| **加密** | 加密完整 64 字节，**只发前 63 字节** |

```python
ct = tea_encrypt(pt)              # 64 字节
wire = bytes([0x55]) + ct[:63]    # 64 字节（含 report ID）
```

### 7.3 设备是被动的

一次 60 秒空闲测量没有收到通知，但结束时在线状态仍为在线。**没有报文不代表休眠。** Hooks 轮询与 Studio 专用心跳不同，长期防休眠效果需要受控对照。

### 7.4 并发打开是安全的

所有打开都用 `kIOHIDOptionsTypeNone`（非独占），
**多个实例可以同时打开同一个设备**，不会互相打架，也不会独占。

已验证：同时跑两个 `vibekey.py` 实例都成功。

### 7.5 保活查询的回复要过滤掉

`--poll` 会周期性发 `01 0B 89 01`（读 Hooks 模式），设备每次都回。
如果不加过滤，输出会被淹没。程序识别 `pt[2] == 0x89 and (pt[3] & 0x0F) == 0x01`
的回复并归入"（保活往返）"统计。

（`--learn` 或 `--raw` 时会显示。）

---

## 8. 想扩展？

`vibekey.py` 是一个单文件脚本，可以直接 import：

```python
import vibekey as V

class MyMon(V.Monitor):
    def _keyboard(self, p):
        ...   # 重写按键处理

mon = MyMon()
handles, pending = V.build_manager(mon)
runloop = V.cf.CFRunLoopGetCurrent()
while True:
    V.cf.CFRunLoopRunInMode(V.kCFRunLoopDefaultMode, 0.1, False)
```

有用的导出：

| 名字 | 作用 |
|---|---|
| `tea_encrypt` / `tea_decrypt` | TEA 编解码（自动按 8 字节分组） |
| `send_frame(handles, pt)` | 发一条明文帧（自动加密 + 截断） |
| `build_manager(mon)` | 枚举并打开所有接口 → `(handles, pending)` |
| `retry_pending(...)` | 重试打不开的接口 |
| `close_all(handles)` | 关闭所有接口 |
| `Monitor` | 报文解码 + 显示（可继承） |
| `OP_TABLE` | 85 条命令的 `(grp, op) → 名称` 表 |
| `VIBE_CONTROLS` | 键码 → 控件名映射 |
| `read_key_config` / `write_key_config` | 读写设备按键表 |
| `parse_keycode` / `keyname` | 键码 ↔ 名字 |

---

## 9. 安全提示

| 操作 | 风险 |
|---|---|
| `--probe`、`--keys`、`--list`、`--descriptor` | **只读，安全** |
| `--poll` | 只发读命令，安全 |
| `--set-key` | **写设备配置**。改动持久化，但可随时改回；见 §6 应急恢复 |
| 电源键长按 | **可能直接关机**，程序不涉及 |

> 未知的 `access=0x04`（写）命令**不要乱发** —— 命令表里有几十条写命令
> （亮度、麦克风、指示灯、OTA…），在没弄清参数格式前发出去可能让设备进入异常状态。
