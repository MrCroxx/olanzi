#!/usr/bin/env python3
"""文档双语一致性校验。

按 AGENTS.md §2 的约定检查：
  1. 每份中文文档都有对应的 .en.md
  2. 两版的 Markdown 结构一一对应（标题层级、代码块数、表格形状）
  3. 两版互相有语言切换链接
  4. 所有相对链接都能解析

用法:
    python3 tools/check_docs.py          # 从仓库根目录运行
    python3 tools/check_docs.py -v       # 打印每份文档的结构指纹
"""

import argparse
import collections
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIP_DIRS = {".git", "node_modules", ".venv", "__pycache__", "evidence"}

LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
H1_RE = re.compile(r"^#\s+(.*)$")
HEAD_RE = re.compile(r"^(#{1,6})\s")
FENCE_RE = re.compile(r"^\s*```")
# 十六进制字面量 或 连续的十六进制字节序列
HEX_RE = re.compile(r"\b(?:0[xX][0-9a-fA-F]+|[0-9a-fA-F]{2}(?:\s+[0-9a-fA-F]{2})+)\b")
CJK_RE = re.compile(r"[\u4e00-\u9fff]")
INLINE_CODE_RE = re.compile(r"`[^`]*`")


def hex_tokens(text):
    """提取数值 token 的多重集，用于检查翻译是否丢失/篡改了数值。"""
    c = collections.Counter()
    for m in HEX_RE.finditer(text):
        c[re.sub(r"\s+", " ", m.group(0)).lower()] += 1
    return c


def collect_docs():
    """返回 [(中文路径, 英文路径)]。"""
    zh = []
    for p in sorted(ROOT.rglob("*.md")):
        if any(part in SKIP_DIRS for part in p.parts):
            continue
        if p.name.endswith(".en.md"):
            continue
        if p.name in ("AGENTS.md", "CLAUDE.md"):
            continue                       # 项目记忆，不属于文档集
        zh.append(p)
    return [(p, p.with_name(p.stem + ".en.md")) for p in zh]


def strip_literals(text):
    """去掉围栏代码块 + 行内代码。

    行内代码里的中文是**对程序真实输出的引用**（vibekey.py 的输出就是中文），
    属于合法保留；只有散文里残留的中文才说明漏译。
    """
    out, inf = [], False
    for line in text.splitlines():
        if FENCE_RE.match(line):
            inf = not inf
            continue
        if not inf:
            out.append(INLINE_CODE_RE.sub("", line))
    return "\n".join(out)


def profile(text):
    """提取结构性指纹：标题层级序列、代码块数、表格形状。"""
    heads, fences, tables = [], 0, []
    in_fence, cur = False, None
    for line in text.splitlines():
        if FENCE_RE.match(line):
            fences += 1
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        m = HEAD_RE.match(line)
        if m:
            heads.append(len(m.group(1)))
        if line.strip().startswith("|") and line.count("|") >= 2:
            ncol = line.count("|") - 1
            if cur is None:
                cur = ncol
            elif ncol != cur:
                cur = max(cur, ncol)
        else:
            if cur is not None:
                tables.append(cur)
                cur = None
    if cur is not None:
        tables.append(cur)
    return {"heads": heads, "fences": fences, "tables": tables}


def check_links(md, problems):
    for m in LINK_RE.finditer(md.read_text(errors="ignore")):
        target = m.group(2)
        if target.startswith(("http", "#", "mailto")):
            continue
        path = (md.parent / target.split("#")[0]).resolve()
        if not path.exists():
            problems.append(f"失效链接 [{m.group(1)}]({target})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()

    pairs = collect_docs()
    if not pairs:
        print("没找到任何文档")
        return 1

    ok = True
    for zh, en in pairs:
        rel = zh.relative_to(ROOT)
        print(f"\n📄 {rel}")

        # 1. 英文版存在
        if not en.exists():
            print(f"   ❌ 缺少英文版 {en.name}")
            ok = False
            continue

        zt, et = zh.read_text(errors="ignore"), en.read_text(errors="ignore")
        zp, ep = profile(zt), profile(et)

        # 2. 结构一致
        diffs = []
        if zp["heads"] != ep["heads"]:
            diffs.append(f"标题层级 中={zp['heads']} 英={ep['heads']}")
        if zp["fences"] != ep["fences"]:
            diffs.append(f"代码块数 中={zp['fences']} 英={ep['fences']}")
        if zp["tables"] != ep["tables"]:
            diffs.append(f"表格形状 中={zp['tables']} 英={ep['tables']}")
        if diffs:
            for d in diffs:
                print(f"   ❌ 结构不一致: {d}")
            ok = False
        else:
            print(f"   ✅ 结构一致（{len(zp['heads'])} 个标题 / "
                  f"{zp['fences']} 个代码块 / {len(zp['tables'])} 个表格）")

        # 2.5 数值保真：十六进制 token 必须一一对应（不上不下）
        hz, he = hex_tokens(zt), hex_tokens(et)
        lost, gained = hz - he, he - hz
        if lost or gained:
            if lost:
                print(f"   ❌ 数值丢失 {sum(lost.values())} 个: {dict(lost)}")
            if gained:
                print(f"   ❌ 数值多出 {sum(gained.values())} 个: {dict(gained)}")
            ok = False
        else:
            print(f"   ✅ 数值保真（{sum(hz.values())} 个十六进制 token 完全一致）")

        # 3. 互链
        zh_title = H1_RE.search(zt)
        en_title = H1_RE.search(et)
        head_zh = zt[:zh_title.end() + 900] if zh_title else zt[:900]
        head_en = et[:en_title.end() + 900] if en_title else et[:900]
        if en.name not in head_zh:
            print(f"   ❌ 中文版头部缺少指向 {en.name} 的链接")
            ok = False
        if zh.name not in head_en:
            print(f"   ❌ 英文版头部缺少指向 {zh.name} 的链接")
            ok = False
        if en.name in head_zh and zh.name in head_en:
            print("   ✅ 中英互链正常")

        # 4. 文档集导航行（docs/ 下的文档强制）
        if zh.parent.name == "docs":
            miss = []
            if "📚" not in head_zh:
                miss.append("中文版")
            if "📚" not in head_en:
                miss.append("英文版")
            if miss:
                print(f"   ❌ 缺少文档集导航行（📚）：{'、'.join(miss)}")
                ok = False
            else:
                print("   ✅ 文档集导航行正常")

        # 5. 链接可解析
        problems = []
        check_links(zh, problems)
        check_links(en, problems)
        if problems:
            for p in problems:
                print(f"   ❌ {p}")
            ok = False
        else:
            print("   ✅ 所有相对链接有效")

        # 6. 英文版散文不应残留中文
        #    （围栏代码块 + 行内代码里的中文是合法引用，不算漏译）
        prose = strip_literals(et).replace("中文", "")
        leaked = [l.strip() for l in prose.splitlines() if CJK_RE.search(l)]
        if leaked:
            print(f"   ❌ 英文版**散文**残留中文 {len(leaked)} 行（行内代码引用不算）：")
            for l in leaked[:5]:
                print(f"        {l[:88]}")
            if len(leaked) > 5:
                print(f"        …另有 {len(leaked) - 5} 行")
            ok = False
        else:
            print("   ✅ 英文版散文无中文残留")

        if a.verbose:
            print(f"   ℹ️  中文 {len(zt.splitlines())} 行 / 英文 {len(et.splitlines())} 行")

    print()
    print("═" * 60)
    print("✅ 全部通过" if ok else "❌ 存在问题，见上方")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
