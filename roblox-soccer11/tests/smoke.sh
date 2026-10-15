#!/bin/sh
# Roblox API を模したスタブ上で、クライアント / サーバーのコードを通しで実行する。
# 実行時エラー (nil 参照・API の誤用) を洗い出す用。見た目や物理は検証しない。
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
tmp="${TMPDIR:-/tmp}"
for scenario in client_smoke server_smoke; do
  python3 "$root/tests/smoke_bundle.py" "$root" "tests/smoke/$scenario.luau" > "$tmp/soccer11_$scenario.luau"
  luau "$tmp/soccer11_$scenario.luau"
done
