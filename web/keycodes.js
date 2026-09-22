// 键码保持与已验证的 HID Keyboard usage 和 vibekey.py 一致。
const key = (code, label, category = "basic", aliases = "") => ({
  code,
  label,
  category,
  aliases,
});
export const KEYCODES = [
  key(0x00, "无按键", "special", "none disabled"),
  key(0x01, "Mac Fn", "modifier", "function globe 地球键 自定义 ErrorRollOver 出厂 未配置"),
  ...Array.from({ length: 26 }, (_, i) =>
    key(4 + i, String.fromCharCode(65 + i)),
  ),
  ...Array.from({ length: 10 }, (_, i) => key(0x1e + i, String((i + 1) % 10))),
  key(0x28, "Enter", "basic", "回车 return"),
  key(0x29, "Esc", "basic", "退出 escape"),
  key(0x2a, "Backspace", "basic", "退格"),
  key(0x2b, "Tab", "basic", "制表"),
  key(0x2c, "Space", "basic", "空格"),
  ...["−", "=", "[", "]", "\\", "#", ";", "'", "`", ",", ".", "/"].map(
    (label, i) => key(0x2d + i, label),
  ),
  key(0x39, "Caps Lock", "basic", "大写 capslock"),
  ...Array.from({ length: 12 }, (_, i) =>
    key(0x3a + i, `F${i + 1}`, "function"),
  ),
  ...Array.from({ length: 12 }, (_, i) =>
    key(0x68 + i, `F${i + 13}`, "function"),
  ),
  ...[
    "Print Screen",
    "Scroll Lock",
    "Pause",
    "Insert",
    "Home",
    "Page Up",
    "Delete",
    "End",
    "Page Down",
    "→",
    "←",
    "↓",
    "↑",
  ].map((label, i) =>
    key(
      0x46 + i,
      label,
      "navigation",
      [
        "截图 printscreen",
        "scrolllock",
        "暂停",
        "插入",
        "行首",
        "上页 pageup",
        "删除",
        "行尾",
        "下页 pagedown",
        "右 right",
        "左 left",
        "下 down",
        "上 up",
      ][i],
    ),
  ),
  ...[
    "Num Lock",
    "Num /",
    "Num *",
    "Num −",
    "Num +",
    "Num Enter",
    "Num 1",
    "Num 2",
    "Num 3",
    "Num 4",
    "Num 5",
    "Num 6",
    "Num 7",
    "Num 8",
    "Num 9",
    "Num 0",
    "Num .",
  ].map((label, i) => key(0x53 + i, label, "numpad", "小键盘")),
  key(0x65, "Menu", "special", "菜单 application"),
  ...[
    "L Ctrl",
    "L Shift",
    "L Option",
    "L Command",
    "R Ctrl",
    "R Shift",
    "R Option",
    "R Command",
  ].map((label, i) =>
    key(0xe0 + i, label, "modifier", "修饰 ctrl shift alt cmd"),
  ),
];
export const CATEGORIES = [
  ["basic", "基础键"],
  ["function", "功能键"],
  ["navigation", "导航键"],
  ["modifier", "修饰键"],
  ["numpad", "数字键盘"],
  ["special", "其他"],
];
export const DEFAULT_CODES = [1, 0x28, 0x29, 0x46, 0x4f, 0x2a];
export const CONTROLS = [
  "按键 1 · 上",
  "按键 2 · 中",
  "按键 3 · 下",
  "旋钮 · 按下",
  "旋钮 · 右转",
  "旋钮 · 左转",
];
export const labelFor = (code) =>
  KEYCODES.find((k) => k.code === code)?.label ??
  (code == null ? "自定义配置" : `0x${code.toString(16).toUpperCase()}`);
export const hex = (code) =>
  code == null ? "—" : `0x${code.toString(16).toUpperCase().padStart(2, "0")}`;
export const validCode = (code) =>
  Number.isInteger(code) && KEYCODES.some((k) => k.code === code);

export function parseProfile(value) {
  if (
    !value ||
    value.version !== 1 ||
    value.device !== "AU05" ||
    !Array.isArray(value.keys) ||
    value.keys.length !== 6
  ) {
    throw new Error("这不是有效的 AU05 配置文件（需要版本 1 和六个控件）。");
  }
  const seen = new Set();
  for (const entry of value.keys) {
    if (
      !entry ||
      !Number.isInteger(entry.index) ||
      entry.index < 0 ||
      entry.index > 5 ||
      seen.has(entry.index) ||
      !validCode(entry.code)
    ) {
      throw new Error("配置中存在重复控件或不支持的键码，未导入。");
    }
    seen.add(entry.index);
  }
  return value.keys
    .slice()
    .sort((a, b) => a.index - b.index)
    .map((k) => k.code);
}
