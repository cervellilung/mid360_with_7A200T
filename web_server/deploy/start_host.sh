#!/bin/sh
# MID360 ACX750 上位机启动脚本（由 systemd 或手工调用）。
# 所有路径与参数均可通过环境变量覆盖，不硬编码某台机器的绝对路径。
set -eu

repo=${MID360_REPO:-/opt/mid360_pc_fpga}
python=${MID360_PYTHON:-/usr/bin/python3}

bind=${MID360_HOST_BIND:-0.0.0.0}
port=${MID360_HOST_PORT:-46000}
web_bind=${MID360_HOST_WEB_BIND:-0.0.0.0}
web_port=${MID360_HOST_WEB_PORT:-8765}
session_dir=${MID360_SESSION_DIR:-$repo/sample/sessions_m3tl}
session=${MID360_SESSION:-}
config=${MID360_CONFIG:-}

cd "$repo/web_server"

set -- --bind "$bind" --port "$port" --web-bind "$web_bind" --web-port "$web_port" --session-dir "$session_dir"
if [ -n "$config" ]; then
  set -- "$@" --config "$config"
fi
if [ -n "$session" ]; then
  set -- "$@" --session "$session"
fi

exec "$python" server.py "$@"