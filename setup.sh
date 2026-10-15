#!/usr/bin/env bash
# Ubuntu 20.04 向けセットアップ: ./setup.sh && .venv/bin/python run_gaze.py
set -e
cd "$(dirname "$0")"
if ! python3 -m pip --version >/dev/null 2>&1 || ! python3 -c "import venv, ensurepip" 2>/dev/null; then
  echo "[setup] sudo apt install python3-venv python3-pip が必要です"
  sudo apt-get install -y python3-venv python3-pip
fi
python3 -m venv .venv
.venv/bin/pip install -U pip
.venv/bin/pip install -r requirements.txt
echo "[setup] done. 起動: .venv/bin/python run_gaze.py"
