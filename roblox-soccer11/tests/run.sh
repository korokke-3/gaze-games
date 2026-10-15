#!/bin/sh
# Config / Locale / Match を Studio 無しで検証する (luau CLI が必要)。
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
out="${TMPDIR:-/tmp}/soccer11_spec.luau"
python3 "$root/tests/bundle.py" "$root" > "$out"
luau "$out"
