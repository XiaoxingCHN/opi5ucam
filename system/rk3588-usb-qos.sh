#!/bin/bash
# rk3588-usb-qos.sh — 提升 USB3/MMU600PHP DMA 路径的 DDR QOS 优先级（RK3588）
# 修复：USB3 设备在系统内存带宽争用下静默死亡（DMA 被饿死）。
# 寄存器语义见 TRM Part2 "QoS Generator"（P1@bits[10:8]=READ, P0@bits[2:0]=WRITE，3 位）
# MMU600PHP TBU/TCU 出厂 urgency=0（全系统最低）——USB3 DMA 端口的隐性瓶颈。
set -e
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
write() { python3 "/home/xiaoxingchn/harness/qos_write.py" "$1" 0x80000707; }
# USB3 OTG 控制器 ×2（Bus6/Bus8 的 SS 口）
write 0xfdf3e200
write 0xfdf3e000
# USB2 host 控制器 ×2
write 0xfdf3e400
write 0xfdf3e600
# MMU600PHP TBU/TCU（USB3 DMA 的 SMMU 端口——关键瓶颈）
write 0xfdf3a600
write 0xfdf3a800
echo "QOS priorities applied"
