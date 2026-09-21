import test from "node:test";
import assert from "node:assert/strict";
import {
  KEYCODES,
  DEFAULT_CODES,
  parseProfile,
  validCode,
} from "../web/keycodes.js";
const profile = () => ({
  version: 1,
  device: "AU05",
  keys: DEFAULT_CODES.map((code, index) => ({ index, code })),
});
test("键码表没有重复，并严格限制已知键盘 usage", () => {
  assert.equal(new Set(KEYCODES.map((k) => k.code)).size, KEYCODES.length);
  const allowed = [
    0,
    1,
    ...Array.from({ length: 96 }, (_, i) => i + 4),
    101,
    ...Array.from({ length: 12 }, (_, i) => i + 104),
    ...Array.from({ length: 8 }, (_, i) => i + 224),
  ];
  assert.deepEqual(
    KEYCODES.map((k) => k.code).sort((a, b) => a - b),
    allowed,
  );
  for (const code of [-1, 2, 3, 100, 102, 116, 255, 256, "104", null, NaN])
    assert.equal(validCode(code), false);
});
test("配置导入按控件索引排序且不修改原文件", () => {
  const value = profile();
  value.keys.reverse();
  assert.deepEqual(parseProfile(value), DEFAULT_CODES);
  assert.equal(value.keys[0].index, 5);
});
test("畸形配置、重复控件、媒体码、版本漂移一律拒绝", () => {
  for (const value of [
    null,
    [],
    {},
    { ...profile(), version: 2 },
    { ...profile(), device: "other" },
    { ...profile(), keys: profile().keys.slice(1) },
  ])
    assert.throws(() => parseProfile(value));
  for (const bad of [
    { index: 0, code: 104 },
    { index: 6, code: 104 },
    { index: "5", code: 104 },
    { index: 5, code: 256 },
    { index: 5, code: "104" },
    { index: 5, code: 116 },
    null,
  ]) {
    const value = profile();
    value.keys[5] = bad;
    assert.throws(() => parseProfile(value));
  }
});
