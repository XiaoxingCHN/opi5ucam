#!/bin/bash
# usb_recover.sh — SUA133GC (f622:d132) link recovery for the ROS camera node.
# Called by the node via `sudo -n` (passwordless, see /etc/sudoers.d/usb-recover).
#
# Actions: VBUS power cycle (electrical replug, via DTB gpio-leds vbus-recover)
#          + dwc3 rebind fallback. Refuses (exit 3) when ANOTHER process holds
#          the camera's usbfs node — never yanks the camera out from a live app.
#
# Exit codes: 0 recovered/healthy · 1 device still absent after recovery ·
#             2 script error · 3 held by another process (no action taken)

VID=f622
log() { logger -t usb_recover "$*"; }
on_bus() { lsusb 2>/dev/null | grep -q "$VID"; }
wait_enum() { local i; for i in $(seq 1 "$1"); do on_bus && return 0; sleep 1; done; return 1; }

# --- device location ------------------------------------------------------
dev=""
for f in /sys/bus/usb/devices/*/idVendor; do
    if [ "$(cat "$f" 2>/dev/null)" = "$VID" ]; then dev=$(dirname "$f"); break; fi
done
if [ -z "$dev" ]; then
    log "device not on bus — nothing to recover (caller should wait for replug)"
    exit 1
fi
busnum=$(cat "$dev/busnum"); devnum=$(cat "$dev/devnum")
node=$(printf '/dev/bus/usb/%03d/%03d' "$busnum" "$devnum")

# --- holder guard: refuse when someone else owns the device ---------------
holders=$(python3 - "$node" <<'PY'
import glob, os, sys
target = sys.argv[1]
out = []
for fd in glob.glob('/proc/[0-9]*/fd/*'):
    try:
        if os.readlink(fd) == target:
            pid = fd.split('/')[2]
            comm = open('/proc/%s/comm' % pid).read().strip()
            out.append('%s(%s)' % (pid, comm))
    except OSError:
        pass
sys.stderr.write(' '.join(out) + '\n')
raise SystemExit(2 if out else 0)
PY
)
scan_rc=$?
if [ "$scan_rc" -ne 0 ]; then
    if [ "$scan_rc" -eq 2 ]; then
        log "refusing: device held by $holders"
        echo "HELD_BY: $holders"
        exit 3
    fi
    log "holder scan failed (rc=$scan_rc) — refusing to power cycle"
    exit 2
fi

# --- controller + VBUS led ------------------------------------------------
ctl=$(readlink -f "$dev" | sed -n 's#.*/platform/\(fc[0-9a-f]*\.usb\)/.*#\1#p')
ctl=${ctl:-fc400000.usb}
case "$ctl" in
    fc400000.usb) led=vbus-host ;;
    fc000000.usb) led=vbus-otg  ;;
    *)            led=vbus-host ;;
esac

# --- L: VBUS power cycle --------------------------------------------------
if [ -e "/sys/class/leds/$led/brightness" ]; then
    log "VBUS power cycle via $led ($node)"
    echo 0   > "/sys/class/leds/$led/brightness" 2>/dev/null
    sleep 3
    echo 255 > "/sys/class/leds/$led/brightness" 2>/dev/null
    wait_enum 25 || true
else
    log "no /sys/class/leds/$led — DTB vbus-recover missing"
    exit 2
fi

# --- L+: dwc3 rebind fallback --------------------------------------------
if ! on_bus && [ -d /sys/bus/platform/drivers/dwc3 ]; then
    log "no re-enum after VBUS restore — dwc3 rebind $ctl"
    echo "$ctl" > /sys/bus/platform/drivers/dwc3/unbind 2>/dev/null
    sleep 3
    echo "$ctl" > /sys/bus/platform/drivers/dwc3/bind 2>/dev/null
    wait_enum 10 || true
fi

if on_bus; then
    log "recovered: device present on bus"
    exit 0
fi
log "FAILED: device still absent"
exit 1
