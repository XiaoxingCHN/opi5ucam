#!/bin/bash
# AP6611S (Synaptics SYN43711) BT bring-up, final: power-cycle + gated download + hci_uart daemon attach
BT=/dev/ttyS7
HCD=/lib/firmware/SYN43711A0.hcd
BTATTACH=/home/xiaoxingchn/aravis/btattach
modprobe hci_uart 2>/dev/null
for i in $(seq 1 15); do
  echo "[bt-start] attempt $i"
  pkill -9 -x brcm_patchram_plus 2>/dev/null
  pkill -9 -x btattach 2>/dev/null
  # BT core power cycle via rfkill (BT_REG_ON + RTS resequencing)
  rfkill block bluetooth 2>/dev/null; sleep 1; rfkill unblock bluetooth 2>/dev/null
  # firmware download over raw UART (wait for completion marker)
  OUT=$(timeout 30 brcm_patchram_plus --bd_addr_rand --enable_hci --no2bytes \
        --use_baudrate_for_download --tosleep 200000 --baudrate 1500000 \
        --patchram $HCD $BT 2>&1)
  echo "$OUT" | tail -1
  echo "$OUT" | grep -q "line discpline" || { echo "[bt-start] download incomplete"; sleep 2; continue; }
  # chip is now in HCI mode; attach hci_uart ldisc + H4 proto as a DAEMON (must hold the fd)
  nohup $BTATTACH $BT 5 1 >/tmp/btattach.log 2>&1 &
  sleep 5
  # bring up the UART hci
  DONE=""
  for h in $(hciconfig | grep '^hci' | cut -d: -f1); do
    BUS=$(hciconfig $h | grep 'Bus:' | awk '{print $4}')
    if [ "$BUS" = "UART" ]; then
      hciconfig $h up 2>/dev/null
      sleep 8
      ADDR=$(hciconfig $h | grep 'BD Address' | awk '{print $3}')
      if [ -n "$ADDR" ] && [ "$ADDR" != "00:00:00:00:00:00" ]; then
        echo "[bt-start] SUCCESS: $h up addr=$ADDR"
        DONE=1
      fi
    fi
  done
  [ -n "$DONE" ] && { echo "[bt-start] BT READY"; exit 0; }
  echo "[bt-start] hci up failed, retry"
  sleep 2
done
echo "[bt-start] FAILED"
exit 1
