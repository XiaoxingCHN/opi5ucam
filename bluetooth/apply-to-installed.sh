#!/bin/bash
# apply-to-installed.sh —— 在【已装好系统】的测试机上一键应用全部修复
# 用法：把整个 opi/ 目录拷到板上任意位置，然后：
#   sudo bash board-fixes/apply-to-installed.sh
# 适用：aarch64 + Orange Pi 5 Ultra/Max + 本项目镜像或官方镜像
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
[ "$(uname -m)" = "aarch64" ] || { echo "请在板子上运行"; exit 1; }

echo "== 1) 内核 5.10.209（已存在则跳过） =="
if [ -d /lib/modules/5.10.209 ]; then
  echo "   5.10.209 已安装，跳过内核部分"
else
  install -m644 "$DIR/artifacts/Image" /boot/vmlinuz-5.10.209
  install -m644 "$DIR/artifacts/System.map-5.10.209" /boot/System.map-5.10.209
  install -m644 "$DIR/artifacts/config-5.10.209" /boot/config-5.10.209
  tar -C / -xzf "$DIR/artifacts/modules-5.10.209.tar.gz"
  rm -f /lib/modules/5.10.209/build /lib/modules/5.10.209/source
  depmod -a 5.10.209
  DT=/lib/firmware/5.10.209/device-tree/rockchip
  mkdir -p "$DT"
  cp "$DIR"/artifacts/*.dtb "$DT"/
  echo "   内核文件已安装。引导切换（二选一）："
  echo "   A) 修改 /boot/extlinux/extlinux.conf 指向 /boot/vmlinuz-5.10.209"
  echo "   B) 直接重刷 opi/images/ 下的完整镜像"
fi

echo "== 2) 蓝牙修复（AP6611S / SYN43711，替换错误的 UART-only 服务） =="
install -m755 "$DIR/board-fixes/bt-start.sh" /usr/local/bin/bt-start.sh
install -m755 "$DIR/board-fixes/btattach" /usr/local/bin/btattach
install -m644 "$DIR/board-fixes/ap6611s-bt-fixed.service" /etc/systemd/system/
echo "blacklist btsdio" > /etc/modprobe.d/blacklist-btsdio.conf
systemctl disable ap6611s-bluetooth.service 2>/dev/null || true
systemctl unmask bluetooth.service 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now bluetooth.service 2>/dev/null || true
systemctl enable --now ap6611s-bt-fixed.service

echo "== 3) 验证 =="
sleep 5
systemctl --no-pager is-active ap6611s-bt-fixed.service bluetooth.service || true
hciconfig 2>/dev/null | grep -E '^hci|Bus|BD Address' | tr -s ' ' | head -8 || echo "(hci 尚未就绪，服务会自动重试 10 次)"
echo
echo "== 完成。已知项：WiFi 驱动(8821CS)与 Synaptics SDIO 设备不匹配属镜像原状，未在本次范围 =="
