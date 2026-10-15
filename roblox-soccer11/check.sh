#!/bin/sh
# Luau の構文チェック (Roblox の型定義は含まないため構文のみ)
cd "$(dirname "$0")" || exit 1
fail=0
for f in $(find src -name '*.luau' | sort); do
  out=$(luau-compile --binary -O0 "$f" 2>&1 >/dev/null)
  if [ -n "$out" ]; then
    echo "✗ $f"
    echo "$out" | head -10
    fail=1
  else
    echo "✓ $f"
  fi
done
exit $fail
