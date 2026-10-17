#!/usr/bin/env python3
"""スタブ + 全モジュール + シナリオを 1 ファイルに束ねる (Roblox API のスモークテスト用)。"""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
scenario = sys.argv[2]

MODULES = {
    "shared/Config": "src/shared/Config.luau",
    "shared/Locale": "src/shared/Locale.luau",
    "shared/Rewards": "src/shared/Rewards.luau",
    "shared/Match": "src/shared/Match.luau",
    "shared/Snapshot": "src/shared/Snapshot.luau",
    "shared/Bindings": "src/shared/Bindings.luau",
    "client/RemoteMatch": "src/client/RemoteMatch.luau",
    "client/Rig": "src/client/Rig.luau",
    "server/Services/Rooms": "src/server/Services/Rooms.luau",
    "client/init": "src/client/init.client.luau",
    "client/World": "src/client/World.luau",
    "client/Hud": "src/client/Hud.luau",
    "client/Input": "src/client/Input.luau",
    "client/Menu": "src/client/Menu.luau",
    "client/Sfx": "src/client/Sfx.luau",
    "server/init": "src/server/init.server.luau",
    "server/Services/Data": "src/server/Services/Data.luau",
    "server/Services/Store": "src/server/Services/Store.luau",
    "server/Services/Matches": "src/server/Services/Matches.luau",
    "server/Services/Monetization": "src/server/Services/Monetization.luau",
}


def body(rel: str) -> str:
    s = (root / rel).read_text(encoding="utf-8")
    s = re.sub(r"^--!\w+$", "", s, flags=re.MULTILINE)
    return s.replace("os.clock()", "FakeNow()")


parts = ["--!nocheck", (root / "tests/smoke/stubs.luau").read_text(encoding="utf-8"), "Modules = {}"]
for key, rel in MODULES.items():
    # モジュールは (script, require) を受け取る関数にする
    parts.append('Modules["' + key + '"] = function(script, require)\n' + body(rel) + "\nend")
parts.append((root / "tests/smoke/services.luau").read_text(encoding="utf-8"))
parts.append((root / scenario).read_text(encoding="utf-8"))
print("\n\n".join(parts))
