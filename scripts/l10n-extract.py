#!/usr/bin/env python3
"""Collect every (Italian, English) UI string pair and every L10n.tr English
fallback from the Swift sources, and list per language which English
templates still need a translation. Interpolations become {0}, {1}…

Usage: scripts/l10n-extract.py OUT.json   (prints a coverage summary)
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LANGS = ["de", "es", "ptBR", "ko", "fr", "it", "ja", "ru", "tr", "fa", "zhHans", "zhHant"]
DICT = {"de": "germanFallbacks", "es": "spanishFallbacks", "ptBR": "brazilianPortugueseFallbacks",
        "ko": "koreanFallbacks", "fr": "frenchFallbacks", "it": "italianFallbacks", "ja": "japaneseFallbacks",
        "ru": "russianFallbacks", "tr": "turkishFallbacks", "fa": "persianFallbacks", "zhHant": "traditionalChineseFallbacks"}


def parse_literal(s, i):
    """s[i] == '"'. Returns (template, has_interp, end) or None for raw/multiline."""
    if s.startswith('"""', i):
        return None
    j, out, n, interp = i + 1, [], 0, False
    while j < len(s):
        c = s[j]
        if c == '"':
            return "".join(out), interp, j + 1
        if c == "\\":
            nxt = s[j + 1]
            if nxt == "(":
                depth, k = 1, j + 2
                while k < len(s) and depth:
                    if s[k] == '"':
                        r = parse_literal(s, k)
                        k = r[2] if r else k + 1
                        continue
                    depth += {"(": 1, ")": -1}.get(s[k], 0)
                    k += 1
                out.append("{%d}" % n); n += 1; interp = True; j = k
                continue
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(nxt, "\\" + nxt)); j += 2
            continue
        if c == "\n":
            return None
        out.append(c); j += 1
    return None


def literals_after(s, i, count):
    res = []
    for _ in range(count):
        while i < len(s) and s[i] in " \t\n": i += 1
        if i >= len(s) or s[i] != '"':
            break
        r = parse_literal(s, i)
        if not r:
            break
        res.append(r); i = r[2]
        while i < len(s) and s[i] in " \t\n": i += 1
        if i < len(s) and s[i] == ",":
            i += 1
        else:
            break
    return res


def main():
    out_path = sys.argv[1]
    loc = (ROOT / "Sources/MacCleanerKit/Localization.swift").read_text()
    dicts = {}
    for lang, name in DICT.items():
        m = re.search(r"static let %s[^=]*=\s*\[(.*?)\n    \]" % name, loc, re.S)
        dicts[lang] = set(re.findall(r'^\s*"((?:[^"\\]|\\.)*)"\s*:', m.group(1), re.M)) if m else set()
    pairs, trs = {}, {}
    for f in sorted((ROOT / "Sources").rglob("*.swift")):
        if f.name == "Localization.swift" or "/Strings/" in str(f):
            continue
        s = f.read_text()
        rel = str(f.relative_to(ROOT))
        menu = "/MacCleanerMenu/" in rel
        call = r"(?:KMR\.t|UIText\.t%s)\(" % (r"|(?<![\w.])t" if menu else "")
        for m in re.finditer(call, s):
            lits = literals_after(s, m.end(), 2)
            if len(lits) == 2:
                it, en = lits[0][0], lits[1][0]
                line = s.count("\n", 0, m.start()) + 1
                pairs.setdefault(en, {"it": it, "where": f"{rel}:{line}"})
        for m in re.finditer(r"L10n\.tr\(", s):
            lits = literals_after(s, m.end(), 3)
            if len(lits) >= 2:
                zh, zh_interp, _ = lits[0]
                en = lits[1][0]
                line = s.count("\n", 0, m.start()) + 1
                e = trs.setdefault(en, {"zh": zh, "interp": zh_interp, "ru_inline": len(lits) == 3, "where": f"{rel}:{line}"})
    need = {lang: {} for lang in LANGS}
    for en, info in pairs.items():
        for lang in LANGS:
            if lang == "it":
                continue
            need[lang][en] = {"it": info["it"], "where": info["where"]}
    for en, info in trs.items():
        for lang in LANGS:
            if lang == "zhHans" or (lang == "ru" and info["ru_inline"]):
                continue
            if info["interp"] or info["zh"] not in dicts.get(lang, set()):
                need[lang].setdefault(en, {"zh": info["zh"], "where": info["where"]})
    # Drop what already has a translation.
    for lang in LANGS:
        f = ROOT / f"Sources/MacCleanerKit/Strings/UIStrings+{lang}.swift"
        have = set(re.findall(r'^\s*"((?:[^"\\]|\\.)*)"\s*:', f.read_text(), re.M)) if f.exists() else set()
        have = {re.sub(r'\\(.)', lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), h) for h in have}
        need[lang] = {k: v for k, v in need[lang].items() if k not in have and k.strip() and re.search(r"[A-Za-z]", k)}
    json.dump(need, open(out_path, "w"), ensure_ascii=False, indent=1)
    print(f"pairs={len(pairs)} l10n.tr={len(trs)}")
    for lang in LANGS:
        print(f"  {lang:7} missing {len(need[lang])}")


main()
