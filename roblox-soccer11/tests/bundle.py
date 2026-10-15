#!/usr/bin/env python3
"""Config + Locale + Match + spec を 1 つの Luau ファイルに束ねる。

Roblox の `require(script.Parent.X)` は luau CLI では解決できないため、
各モジュールを関数で包み、依存はグローバル経由で渡す。
"""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])


def module_body(relative: str) -> str:
    source = (root / relative).read_text(encoding="utf-8")
    source = re.sub(r"^export type", "type", source, flags=re.MULTILINE)
    source = re.sub(r"^local \w+ = require\(.*\)$", "", source, flags=re.MULTILINE)
    source = re.sub(r"^--!\w+$", "", source, flags=re.MULTILINE)
    return source


parts = ["--!nocheck"]
for name, relative in (
    ("Config", "src/shared/Config.luau"),
    ("Locale", "src/shared/Locale.luau"),
    ("Match", "src/shared/Match.luau"),
):
    parts.append(f"{name} = (function()\n{module_body(relative)}\nend)()")

spec = sys.argv[2] if len(sys.argv) > 2 else "tests/spec.luau"
parts.append((root / spec).read_text(encoding="utf-8"))
print("\n\n".join(parts))
