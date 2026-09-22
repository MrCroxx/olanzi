# 04 · 逆向方法论
> 🌐 [English](04-methodology.md)

> 记录**怎么逆出来的**，让整个过程可复现、可审计。
> 结论本身在 [02-vibekey-protocol.md](02-vibekey-protocol.zh.md)，这里讲过程。
>
> 📚 文档集：[README](../README.zh.md) · [01 职责边界](01-ulanzi-studio-scope.zh.md) · [02 协议](02-vibekey-protocol.zh.md) · [03 工具手册](03-tool-manual.zh.md) · [04 逆向方法论](04-methodology.zh.md) · [05 验证记录](05-verification-log.zh.md) · [10 输入运行时](10-input-runtime.zh.md)

---

## 0. 总览：三条战线

这个目标没法靠单一手段拿下，必须三条线交叉验证：

```
┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐
│  静态分析        │   │  日志解密        │   │  运行时抓包      │
│  反汇编 / 符号   │   │  xlog / 62MB    │   │  HID / lsof     │
├─────────────────┤   ├─────────────────┤   ├─────────────────┤
│ • 算法与密钥     │   │ • 消息语义       │   │ • 真实报文       │
│ • 数据结构       │   │ • 数据流         │   │ • 时序           │
│ • 命令表         │   │ • 字段取值范围    │   │ • 触发条件       │
└────────┬────────┘   └────────┬────────┘   └────────┬────────┘
         │                     │                     │
         └─────────────────────┼─────────────────────┘
                               ▼
                    交叉验证后才敢下结论
```

**经验**：任何单一来源的结论都可能错。第一期里我们就吃过亏 ——
`route: "device-direct"` 那条 HTTP 路径看起来很像真的，实际是**死代码**。

---

## 1. 战线一：静态分析

### 1.1 目标文件

| 文件 | 说明 |
|---|---|
| `/Applications/Ulanzi Studio.app/Contents/MacOS/UlanziDeck` | 主程序，62 MB，Qt 6，arm64，**未 strip** |
| `…/Contents/Frameworks/kwdm.dylib` | **Kehwin SDK** —— 真正和 USB 设备说话的库，ObjC，universal |

### 1.2 第一步永远是符号表

```bash
nm -arch arm64 UlanziDeck > symbols.txt
nm -arch arm64 kwdm.dylib > kwdm_symbols.txt

# 主程序有 64,681 个 demangle 后的符号 —— 基本等于源码
```

**未 strip + ObjC 是巨大的运气。** ObjC 的方法名、类名、selector 全在符号表里，
`+[MessageHelper setDeviceButtonShortcutFunctionMessage:num:pages:values:signs:]`
这种名字直接告诉你参数有几个、叫什么。

```bash
# ObjC 元数据：类 / 方法 / 协议
otool -arch arm64 -ov kwdm.dylib > kwdm_objc.txt

# __cstring 段：字面量
strings -a kwdm.dylib > kwdm_strings.txt
```

### 1.3 反汇编：别用 objdump

踩坑记录：

```bash
# ❌ 这些都没生效（LLVM objdump 对 Mach-O 的地址区间支持有问题）
objdump --macho --disassemble --start-address=0x1f398 --stop-address=0x1f46c kwdm.dylib
objdump --macho --disassemble --disassemble-symbols='+[MessageHelper ...]' kwdm.dylib
```

✅ **用 lldb，可以按符号名精确定位**：

```bash
lldb -b \
  -o "target create --arch arm64 kwdm.dylib" \
  -o "disassemble -n '+[MessageHelper setDeviceButtonShortcutFunctionMessage:num:pages:values:signs:]'" \
  -o "quit"
```

输出：

```
kwdm.dylib[0x1f3c8] <+48>:  mov    w8, #0x601
kwdm.dylib[0x1f3cc] <+52>:  movk   w8, #0x450, lsl #16    ; w8 = 0x04500601
kwdm.dylib[0x1f3d0] <+56>:  str    w8, [sp, #0x48]        ; → 帧头 01 06 50 04
```

> 💡 **小技巧**：`mov` + `movk` 拼出来的立即数，**小端存进去就是帧头**。
> `0x04500601` → `01 06 50 04`，一眼就能对上。

### 1.4 从构造函数批量提取命令表

`+[MessageHelper xxxMessage]` 系列每个方法都在拼一个 4 字节帧头。
写脚本批量反汇编 + 正则提取：

```bash
python3 tools/extract_opcodes.py     # → raw/kwdm_message_builders.txt
```

产出 85 条：`名称 | 构造码 | 帧头字节 | 参数寄存器`。例如：

```
getDeviceAllButtonFuncMessage          0x01310601  01 06 31 01  str w8@8
setDeviceButtonShortcutFunction…       0x04500601  01 06 50 04  str w8@72, strb w2@76 …
```

> ⚠️ 有些方法提取失败（显示成 `01 00 00 00`），**必须手工反汇编确认** ——
> setter 就是这么被漏掉、又被 lldb 补回来的。

---

## 2. 战线二：日志解密（xlog）

Ulanzi Studio 用腾讯 **mars xlog** 写日志。拿到明文日志等于拿到**产品需求文档**。

### 2.1 先找源码

厂商把 mars 的部分源码**原封不动**放进了 App 里：

```
~/Library/Application Support/Ulanzi/…/log_base_buffer.cc
                                 log_zlib_buffer.cc
                                 mars_log_crypt.cc
                                 mars_log_magic_num.h
```

**这是金矿。** `mars_log_magic_num.h` 直接给了魔数，`mars_log_crypt.cc` 给了加密算法。

### 2.2 文件格式

```
[73 字节 header][记录...]
```

header 里有一个字节标记压缩方式，`0x09` = **raw DEFLATE**。

```python
import zlib
d = zlib.decompressobj(-15)      # -15 = raw deflate，没有 zlib 头
plain = d.decompress(payload)
```

> 💡 **关键**：`-15`（raw）不是 `15`/`31`。用错了会一直报 `invalid header`。

**结果**：223/223 条记录全部解出 → **62 MB 明文日志**。

### 2.3 从日志里挖到了什么

```bash
python3 -c "
import re, collections
c = collections.Counter()
for line in open('logs_decoded.txt', errors='ignore'):
    for m in re.finditer(r'\"type\"\s*:\s*\"(\w+)\"', line):
        c[m.group(1)] += 1
print(c.most_common(20))
"
```

设备→App 的 JSON 词汇表（4 天数据）：

| type | 次数 | 含义 |
|---|---|---|
| `deviceKeyEvent` | 3893 | **按键事件，带物理 index** |
| `deviceBattery` | 1784 | 电量 |
| `deviceButtonShortcutFunction2` | 1580 | 按键快捷功能 |
| `deviceActive` | 440 | 在线 |
| `deviceHooksMode` | 424 | AI hooks 模式 |
| `deviceIndicatorLightAllParams` | 348 | 指示灯参数 |
| `deviceMicNRLevel` | 148 | 麦克风降噪 |
| … | | |

**`deviceKeyEvent` 的格式极其关键**：

```json
{ "status": 1, "access": 2, "type": "deviceKeyEvent", "index": 5 }
```

`index` 是**物理控件编号** —— 这是替代客户端最想要的东西。

> ⚠️ 日志里的 JSON 是**转义**过的（`\"index\"`），正则要写 `\\"index\\"`。
> 我第一次搜 `"index"` 得到 0 命中，白折腾了半小时。

### 2.4 完整调用链（从日志读出来的）

```
deviceKeyEvent{index:3}
  → handleKeyEvent
  → UlanziDeck::onDialKeyPressed
  → ProfilePresenter::onDialEvent
  → onActionTriggered("com.ulanzi.ulanzideck.system.hotkey")
  → ActionManager::OnTriggerAction
  → HotkeyParser::parse("F13")
  → InputSimulator::KeyDownEx(105, flags 256)
```

**这条链证明了：Studio 在按键时做的事，只是"再注入一次按键"。** 没有别的魔法。

---

## 3. 战线三：运行时抓包

### 3.1 枚举 HID 设备

```python
# IOKit：按 VID/PID 找设备，逐个拿元素
matching = IOServiceMatching(b"IOHIDDevice")
CFDictionarySetValue(matching, "VendorID", 0xFFF1)
CFDictionarySetValue(matching, "ProductID", 0x00DD)
```

拿到接口后读 `PrimaryUsagePage` / `PrimaryUsage` 就能区分是哪一路：

| Usage Page | 用途 |
|---|---|
| `0x000C` | 标准 HID（键盘/多媒体/鼠标） |
| `0xFFFC` | **厂商私有** |

### 3.2 ⚠️ 第一个大坑：`IOHIDManagerOpen` 全有全无

```c
IOHIDManagerOpen(mgr, 0);   // ❌ 只要有一个匹配设备打不开，整个失败
```

错误码 `kIOReturnExclusiveAccess (0xE00002C5)`。

**更坑的是**：这个错误的成因是**我自己的抓包进程占着设备**，却看起来像权限问题，
排查了很久。

✅ **正确做法：逐个打开**

```c
IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it);
while ((svc = IOIteratorNext(it))) {
    IOHIDDeviceRef dev = IOHIDDeviceCreate(kCFAllocatorDefault, svc);
    IOReturn rc = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone);
    // 单独判断，互不影响
}
```

### 3.3 第二个大坑：输入监控权限

`IOHIDDeviceOpen` 返回 `kIOReturnNotPermitted (0xE00002E2)` = **没有输入监控权限**。

**最阴险的地方**：此时设备**照样在往系统注入按键**（你按什么它就打什么），
但你的程序**一条报文都收不到**。如果程序默默跳过失败的接口，
现象就是"按了没反应、但键真的生效了" —— 极难定位。

> **教训**：**权限失败必须大声报错**，绝不能静默降级。

### 3.4 第三个坑：报文长度

- 键盘报文 callback 拿到 **8 字节**（`mods + reserved + 6×keycode`）
- 厂商报文拿到 **63 字节**（不含 report ID）
- 但描述符里声明的是 `0x55` + 63 字节

IOKit 在注册了 report callback 后，**会剥掉 report ID**（取决于注册方式）。
实测 `len=63`，前 63 字节就是密文，直接解密即可。

---

## 4. 关键突破：TEA 密钥

### 4.1 怎么找到的

搜密钥相关的全局符号：

```bash
nm -arch arm64 kwdm.dylib | grep -i "encrypt\|key\|crypt"
# → _gaui_custom_encrypt_keys
```

定位到 `__DATA,__data+0x4a580`（arm64），dump 出 16 字节：

```
ca ba a5 ca 6d 8a 2a bc ba 9e 5a ca ca 8b b8 9b
```

### 4.2 怎么确认是 TEA

反汇编加解密函数：

```asm
_encode:                          ; 0x27790
  mov  w8, #0x79b9
  movk w8, #0x9e37, lsl #16       ; delta = 0x9E3779B9  ← TEA 签名
  mov  w13, #0x20                 ; 32 轮
  ldp  w9, w10, [x0]              ; v0, v1
  ldp  w11, w12, [x1]             ; k0, k1
  ldp  w15, w16, [x1, #0x8]       ; k2, k3
  ...

_decode:                          ; 0x277f4
  mov  w12, #0x3720
  movk w12, #0xc6ef, lsl #16      ; sum 起始 = 0xC6EF3720  ← TEA 解密
  mov  w14, #0x8647
  movk w14, #0x61c8, lsl #16      ; -delta = 0x61C88647
```

`0x9E3779B9` / `0xC6EF3720` 是 TEA 的教科书常量。**但注意不是 XTEA**
（没有 `>> 11` 那一步）。

### 4.3 ⭐ 决定性验证

抓到的报文尾部永远跟着一串 **一模一样的字节**：

```
... 38 90 c4 99 a3 60 aa ad  38 90 c4 99 a3 60 aa ad ...
```

一开始以为是"固定尾巴"或某种 magic。直到试了一个猜想：

```python
TEA_ECB_Enc(b"\x00"*8, key)  ==  b"\x38\x90\xc4\x99\xa3\x60\xaa\xad"   # ✅
```

**那串"神秘常量"就是全零分组的密文。** 明文帧后半段全是 0，所以密文重复。

> **这一刻整个协议就通了。** 之前所有"奇怪的不变字节"全都解释得通了。
>
> **方法论**：遇到"奇怪的固定字节"，先怀疑**它是已知输入的加密结果**，
> 而不是去找它作为常量的含义。

### 4.4 ECB 的副作用

因为是 ECB（无 IV、无链式），**相同的明文块产生相同的密文块**。
这也是我们能一眼看出明文里有大段 0 的原因 —— 对分析其实是**好事**。

### 4.5 63 vs 64 的推导

结构体 64 字节，加密 64 字节 = 8 个分组。
但报文只有 64 字节（含 1 字节 report ID）。

```
线上 63 字节 = ct[0..62] = 7 个完整分组 + 第 8 分组的前 7 字节
```

**结论**：解密只解 7 个分组（56 字节），末 7 字节是不可解填充。

**验证**：解出来的明文帧头 `81 0b 89 11 …` 完全合理，尾部 7 字节无意义。✅

---

## 5. 关键突破：控件映射

这是**方法论上最有价值**的一段 —— 因为它是纯实验设计出来的。

### 5.1 失败的做法

对着设备乱按，然后看抓到什么。**结果：完全对不上。**

原因：有 6 个控件、多个键码，随机按无法建立对应关系。
而且我一度按"4 个键 + 旋钮"的模型推理，**方向就是错的**（实际是 3 键）。

> 💡 **用户的现场信息不可替代**。是用户告诉我"只有三个键，上下排列"，
> 之前所有推断才对上。

### 5.2 成功的做法：受控顺序实验

设计一个**严格有序、每步间隔**的操作序列：

> 按下旋钮 → 键1 → 键2 → 键3 → 右拧×3 → 左拧×3 → 长按旋钮

然后按时间轴做 **1:1 对齐**：

| 时间 | 你的动作 | 设备发出 |
|---|---|---|
| 13:29:20.180 | 按下旋钮 | `0x46` (300ms) |
| 13:29:21.095 | 键 1 | `0x01` (320ms) |
| 13:29:21.980 | 键 2 | `0x28` (400ms) |
| 13:29:22.760 | 键 3 | `0x29` (260ms) |
| 13:29:26.079/444/985 | 右拧 ×3 | `0x4F` ×3 |
| 13:29:29.414/831/30.215 | 左拧 ×3 | `0x2A` ×3 |
| 13:29:34.459 | 长按旋钮 | `0x46` (1220ms) |

**7 个动作、7 个事件、顺序与数量完全吻合。** 至此映射无可争议。

### 5.3 意外收获：时长分类

对齐过程中发现：

```
0x2A → 4ms, 7ms, 6ms, 7ms, 6ms, 4ms …     ← 旋钮转动
0x28 → 126ms, 105ms, 99ms, 140ms …        ← 人手按压
```

**旋钮转动是瞬时脉冲（<10ms），按键是人手按压（>80ms）。**

这条规律让程序可以**在不知道映射的情况下**自动分类事件 —— 现在写进了
`vibekey.py` 的 `INSTANT_MS = 25` 阈值。

> **方法论**：物理特性（时长、频率、时序）往往比数据内容更容易区分来源。

### 5.4 反向确认

拿到映射后，又从设备里读出了**官方配置表**（见下节），
`index 0..5` 的值是 `01 28 29 46 4f 2a` —— **和实验推出的完全一致**。

**双向验证通过。**

---

## 6. 关键突破：可编程按键表

### 6.1 切入点：用户的猜想

用户提出：

> "在 Studio 里可以调整这些 key 的功能。我估计是在这个时候，它改了发送的 HID。"

这个猜想**直接指对了方向**，省掉大量盲目搜索。

### 6.2 静态分析定位

从命令表里找到：

```
getDeviceButtonShortcutFunctionMessage:      01 06 50 01
setDeviceButtonShortcutFunctionMessage:…     (提取失败，需手工)
```

手工 lldb 反汇编 setter，读出**逐字节的组帧逻辑**：

```asm
mov    w8, #0x601
movk   w8, #0x450, lsl #16     ; 0x04500601 → 01 06 50 04
str    w8, [sp, #0x48]
strb   w2, [sp, #0x4c]         ; frame[4] = index
strb   w8=1, [sp, #0x4d]       ; frame[5] = 1（常量）
strb   w3, [sp, #0x4e]         ; frame[6] = num
loop:
  ldrb   w10, [x4], #1         ; page  = *pages++
  ldrb   w11, [x5], #1         ; value = *values++
  strb   w11, [x9]             ; frame[8+2i]   = value
  ldrb   w11, [x6], #1         ; sign  = *signs++
  bfi    w10, w11, #7, #25     ; page |= (sign & 1) << 7
  sturb  w10, [x9, #-0x1]      ; frame[7+2i]   = page | sign<<7
  add    x9, x9, #2
```

> **注意 `sturb w10, [x9, #-0x1]`** —— 写的是 `frame[7]`，不是 `frame[8]`。
> 这个偏移量如果不仔细看，整个格式就会错位一字节。

### 6.3 从设备反查真实格式

与其猜，不如**直接问设备**：

```python
for i in range(8):
    send_frame(hs, bytes([0x01,0x06,0x50,0x01,i]))   # 读 index i
```

回复：

```
index 0 → 81 06 50 11 | 00 | 01 01 02 01
index 1 → 81 06 50 11 | 01 | 01 01 02 28
index 2 → 81 06 50 11 | 02 | 01 01 02 29
index 3 → 81 06 50 11 | 03 | 01 01 02 46
index 4 → 81 06 50 11 | 04 | 01 01 02 4f
index 5 → 81 06 50 11 | 05 | 01 01 02 2a
index 6 → 81 06 50 11 | 06 | 00 …            ← 未使用
```

**静态分析与设备回复逐字节吻合。** 两路独立证据交叉确认。

### 6.4 端到端闭环验证

**这是最有说服力的一步** —— 不满足于"写进去了"，要证明"设备真的照新配置发键了"：

| 步骤 | 结果 |
|---|---|
| 1. 读原值 | `[0x02, 0x01]` |
| 2. 写 `01 06 50 04 00 01 01 02 68` | 回复 `81 06 50 14 …` （access `0x14` = 写确认） |
| 3. 读回 | `[0x02, 0x68]` ✅ 持久化 |
| 4. **用户按真键** | **设备发出 `0x68` = F13** ✅✅ |

**选择改 `index 0` 的理由**：它原本是无效码 `0x01`，改了**不可能损坏任何功能**，
是最安全的试验目标。改完立即还原。

> **方法论**：验证写操作时，**优先选"改坏了也没关系"的目标**，
> 并且**必须能一键还原**。

### 6.5 顺带确认了 TEA

反汇编 `_encode` / `_decode`（0x27790 / 0x277f4）时，
`delta = 0x9E3779B9`、`sum = 0xC6EF3720`、32 轮 —— **和从密文反推的结论完全一致**。

---

## 7. 方法论总结

### 7.1 有效的手段（按性价比排序）

| 手段 | 为什么有效 |
|---|---|
| **读符号表** | 二进制未 strip + ObjC ⇒ 方法名直接告诉你它在干什么 |
| **找随包源码** | 厂商常常把第三方库源码一起打包（mars 就是） |
| **解日志** | 明文日志 = 免费的产品文档 + 数据字典 |
| **交叉验证** | 静态 + 动态 + 设备回复，三者一致才下结论 |
| **问设备** | 能读就问。比反汇编猜快 10 倍 |
| **受控顺序实验** | 建立"动作 ↔ 数据"映射的唯一可靠方法 |
| **端到端闭环** | "写成功"≠"生效"。要观察最终行为 |

### 7.2 关键思维

1. **"奇怪的常量"往往是已知输入的加密结果** —— 全零分组的密文破解了整个协议
2. **物理特性（时长/频率）比内容更好分类** —— 旋钮 vs 按键
3. **失败要大声** —— 权限失败静默降级会浪费几个小时
4. **用户是传感器** —— "只有三个键"这条信息价值超过一堆反汇编
5. **选安全的试验目标** —— 改一个本来就是废的键
6. **死代码会骗人** —— `device-direct` HTTP 路径看着很真，其实是遗留垃圾

### 7.3 判断证据强度

第一期报告的标注约定值得沿用：

| 标注 | 含义 |
|---|---|
| **[CONFIRMED]** | 有直接证据：实测、二进制字面量、或设备回复 |
| **[INFERRED]** | 由间接证据推断，**待验证** |

**永远不要把自己的推断写成结论。** 第一期里 `device-direct` 就是被当成结论写下来、
后来又被推翻的。

---

## 8. 踩过的坑（完整清单）

| # | 坑 | 现象 | 真相 |
|---|---|---|---|
| 1 | `IOHIDManagerOpen` 全有全无 | `0xE00002C5` | 是**我自己的抓包进程**占着设备 |
| 2 | 输入监控权限 | 按键生效但抓不到 | `0xE00002E2`，不是"被占用" |
| 3 | 静默跳过失败接口 | "按了没反应" | 必须大声报错 |
| 4 | xlog 解压参数 | `invalid header` | 要 `zlib.decompressobj(-15)`（raw） |
| 5 | 日志 JSON 转义 | 正则 0 命中 | 实际是 `\"index\"` |
| 6 | `objdump` 地址区间 | 输出全量 | 改用 `lldb disassemble -n <symbol>` |
| 7 | 提取脚本漏 opcode | setter 显示 `01 00 00 00` | 手工反汇编补回 |
| 8 | 帧偏移看错 | 格式错位一字节 | `sturb w10, [x9, #-0x1]` 写的是 `frame[7]` |
| 9 | 按键模型错 | 映射一直对不上 | 实际是 **3 键**不是 4 键 |
| 10 | 终端回显 | 输出被按键冲乱 | `stty -echo` + 写日志文件 |
| 11 | macOS 没有 `timeout` | 脚本报错 | 用 Python 的 socket 超时 / 自己 sleep |
| 12 | 62 MB 日志用 `grep` | `maximum repetition exceeds 255` | 用 Python `re` |
| 13 | 事后对日志与抓包 | 时间对不上 | xlog 是**延迟 flush** 的，别指望实时对齐 |
| 14 | 按键注入焦点窗口 | 编辑器被乱敲 | 保持终端在前台，或改键为 F13+ |
| 15 | **ctypes 回调里抛的异常会被静默吞掉** | `--probe` 报"设备离线"，但 `--keys` 照样能读 | 在 `@staticmethod` 里写了 `self.xxx` → `NameError`。ctypes 只打一行 `Exception ignored` 就继续跑，**症状和真·设备关机一模一样** |
| 16 | 判断"是否离线"只看有没有回复 | 会把代码 bug 误诊成硬件问题 | 必须看**原始明文**：真离线是 `06 03 0a 11` **`00`**（status=0x00）；代码 bug 则**一行都不打印** |

---

## 9. 复现指南

想从零重来一遍：

```bash
# ── 准备 ──
mkdir -p ~/ulanzi-re/{raw,findings,tools}

# ── 1. 静态分析 ──
nm -arch arm64 "/Applications/Ulanzi Studio.app/Contents/MacOS/UlanziDeck" > raw/symbols.txt
nm -arch arm64 "/Applications/Ulanzi Studio.app/Contents/Frameworks/kwdm.dylib" > raw/kwdm_symbols.txt
otool -arch arm64 -ov "/Applications/Ulanzi Studio.app/Contents/Frameworks/kwdm.dylib" > raw/kwdm_objc.txt

# ── 2. 精确定位某个方法 ──
lldb -b -o "target create --arch arm64 \
  '/Applications/Ulanzi Studio.app/Contents/Frameworks/kwdm.dylib'" \
  -o "disassemble -n '+[MessageHelper getDeviceAllButtonFuncMessage]'" -o quit

# ── 3. 找 TEA 密钥 ──
#    nm | grep encrypt  →  _gaui_custom_encrypt_keys
#    objdump -s --section=__data kwdm.dylib  → 偏移 0x4a580 起 16 字节

# ── 4. 解 xlog ──
#    见 ~/Library/Application Support/Ulanzi/ 下的 mars_* 源码
#    header 73 字节，0x09 → zlib.decompressobj(-15)

# ── 5. 抓 HID ──
python3 vibekey.py --learn --raw -t 30

# ── 6. 建立映射（受控实验）──
#    按固定顺序操作，与事件流做时间对齐
```

### 本次逆向的产物

| 内容 | 路径 |
|---|---|
| 主程序符号（64,681 条） | `~/ulanzi-re/raw/symbols.txt` |
| kwdm 符号 / ObjC / 反汇编 | `~/ulanzi-re/raw/kwdm_*` |
| **命令表（85 条）** | `~/ulanzi-re/raw/kwdm_message_builders.txt` |
| 结构体布局（109 条） | `~/ulanzi-re/raw/kwdm_struct_layout.txt` |
| **解码后的 62 MB 日志** | `~/ulanzi-re/raw/logs_decoded.txt` |
| kwdm 协议报告 | `~/ulanzi-re/findings/kwdm-protocol.md` |
| 主程序能力面 | `~/ulanzi-re/findings/binary-surface.md` |
| ustudio-cli 分析 | `~/ulanzi-re/findings/ustudio-cli.md` |
| TEA 参考实现 | `~/ulanzi-re/tools/tea_kwdm.py` |
| opcode 提取脚本 | `~/ulanzi-re/tools/extract_opcodes.py` |
