#!/bin/sh
# 安装 MID360 ACX750 上位机为 systemd 服务（开机自启、崩溃重启）。
# 用法：sudo sh install.sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
unit_name=mid360-host.service
unit_dir=/etc/systemd/system
env_dir=/etc/mid360
runner=mid360

if [ "$(id -u)" -ne 0 ]; then
  echo "需要 root 权限，请用：sudo sh install.sh" >&2
  exit 1
fi

# 1) 运行账号（不存在则创建系统账号，家目录即默认会话目录父级）
if ! id "$runner" >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/mid360-host --create-home \
    --shell /usr/sbin/nologin "$runner"
  echo "已创建系统账号 $runner。"
fi

# 2) 确保 shell 脚本可执行（从 Windows 同步过来可能丢失执行位）
chmod +x "$here/start_host.sh" "$here/install.sh"

# 3) 安装环境变量文件（已存在则不覆盖，避免抹掉现场配置）
install -d -m 0755 "$env_dir"
if [ -f "$env_dir/host.env" ]; then
  echo "$env_dir/host.env 已存在，保留现有配置，未覆盖。"
else
  install -m 0644 "$here/host.env" "$env_dir/host.env"
  echo "已安装 $env_dir/host.env，请按现场路径核对 MID360_* 变量。"
fi

# 4) 安装 systemd unit 并启用
install -d -m 0755 "$unit_dir"
install -m 0644 "$here/$unit_name" "$unit_dir/$unit_name"
systemctl daemon-reload
systemctl enable --now "$unit_name"

echo "安装完成。查看状态：systemctl status $unit_name"
echo "查看日志：journalctl -u $unit_name -f"