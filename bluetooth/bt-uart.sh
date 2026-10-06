#!/bin/bash
# bt-uart.sh — AP6611S/SYN43711 蓝牙完整上电流程（补丁下载 + H4 attach 常驻）
BT=/dev/ttyS7
HCD=/lib/firmware/SYN43711A0.hcd
modprobe hci_uart 2>/dev/null
pkill -9 -x brcm_patchram_plus btattach 2>/dev/null
# 芯片断电复位（清掉之前可能的坏状态）
rfkill block bluetooth 2>/dev/null; sleep 5; rfkill unblock bluetooth 2>/dev/null; sleep 1
# 补丁下载（工具完成后退出；芯片保持补丁，电源不断）
brcm_patchram_plus --bd_addr_rand --enable_hci --no2bytes --use_baudrate_for_download \
  --tosleep 200000 --baudrate 1500000 --patchram $HCD $BT 2>&1 | tail -2
sleep 1
# H4 协议 attach 常驻（TIOCSETD + SETPROTO + 持 fd）
exec python3 -u /home/xiaoxingchn/harness/bt_attach_h4.py
