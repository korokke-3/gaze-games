#!/usr/bin/env bash
# 視線でPCのマウスを動かす(Wayland/X11共通)には /dev/uinput への書き込み権限が必要。
# このスクリプトは sudo で以下を行う:
#   1. uinput カーネルモジュールを読み込み、起動時にも読み込む設定
#   2. ログイン中のユーザーに /dev/uinput へのアクセスを許可する udev ルールを追加
set -e
echo "[uinput] sudo が必要です"
sudo modprobe uinput
echo uinput | sudo tee /etc/modules-load.d/uinput.conf >/dev/null
echo 'KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"' \
  | sudo tee /etc/udev/rules.d/70-gazekit-uinput.rules >/dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=uinput
sleep 1
if [ -w /dev/uinput ]; then
  echo "[uinput] OK: /dev/uinput に書き込めます"
else
  echo "[uinput] まだ書き込めません。一度ログアウト/ログインするか、次のコマンドを実行してください:"
  echo "         sudo setfacl -m u:$USER:rw /dev/uinput"
fi
