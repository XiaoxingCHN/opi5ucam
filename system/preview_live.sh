#!/bin/bash
# preview_live.sh — self-healing color preview window for MindVision SUA133GC.
# Run AS ROOT. Shows an ffplay window in the desktop user's Wayland session.
#
# Design:
#  - ffplay reads from a FIFO whose write-end is held open by this daemon
#    (keepalive), so link deaths never close the window — the picture just
#    freezes for a few seconds while recovery runs, then resumes.
#  - feeder = arv_grab in SEG_DUR-second chunks. A stalled byte counter
#    (/proc/<pid>/io wchar — the "zombie stream" failure mode) or early exit
#    triggers: kill feeder -> VBUS power cycle (electrical replug) -> next chunk.
#  - Stop: close the ffplay window, or `touch /tmp/preview.stop`.
#    On exit, camera-soak.service is restored automatically.

SEG_DUR=300
POLL=3
STALL_POLLS=3
FIFO=/tmp/preview.fifo
STOP=/tmp/preview.stop
LOG=/tmp/preview_live.log
ARV_DIR=/home/USER/aravis
VID=f622

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
on_bus() { lsusb 2>/dev/null | grep -q "$VID"; }
wait_enum() { local i; for i in $(seq 1 "$1"); do on_bus && return 0; sleep 1; done; on_bus; }

vbus_recover() {
    local ctl=fc400000.usb led=vbus-host d
    d=$(ls /sys/bus/usb/devices/*/idVendor 2>/dev/null | while read -r f; do
           [ "$(cat "$f" 2>/dev/null)" = "$VID" ] && dirname "$f" && break
       done)
    if [ -n "$d" ]; then
        ctl=$(readlink -f "$d" | sed -n 's#.*/platform/\(fc[0-9a-f]*\.usb\)/.*#\1#p')
        [ -n "$ctl" ] || ctl=fc400000.usb
        case "$ctl" in
            fc400000.usb) led=vbus-host ;;
            fc000000.usb) led=vbus-otg  ;;
        esac
    fi
    log "recover: VBUS cycle on $led"
    pkill -KILL -x arv_grab 2>/dev/null
    if [ -e "/sys/class/leds/$led/brightness" ]; then
        echo 0   > "/sys/class/leds/$led/brightness" 2>/dev/null
        sleep 3
        echo 255 > "/sys/class/leds/$led/brightness" 2>/dev/null
        wait_enum 25
    fi
    if ! on_bus && [ -d /sys/bus/platform/drivers/dwc3 ]; then
        log "recover: dwc3 rebind $ctl"
        echo "$ctl" > /sys/bus/platform/drivers/dwc3/unbind 2>/dev/null
        sleep 3
        echo "$ctl" > /sys/bus/platform/drivers/dwc3/bind 2>/dev/null
        wait_enum 10
    fi
    sleep 2
}

rm -f "$STOP" "$FIFO"
mkfifo "$FIFO"

su xiaoxingchn -c 'export WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 DISPLAY=:0 SDL_VIDEODRIVER=wayland; exec ffplay -f rawvideo -pixel_format rgb24 -video_size 1280x1024 -framerate 30 -fflags nobuffer -flags low_delay -probesize 32 -analyzeduration 0 -loglevel warning -i /tmp/preview.fifo -window_title "SUA133GC COLOR live"' &
ffpid=$!

# keepalive writer: holds the FIFO write end so ffplay never sees EOF
exec 3>>"$FIFO"

log "preview start (daemon $$, ffplay $ffpid, segment ${SEG_DUR}s)"
seg=0
while :; do
    [ -e "$STOP" ] && { log "stop file seen"; break; }
    kill -0 "$ffpid" 2>/dev/null || { log "ffplay window closed"; break; }

    seg=$((seg + 1))
    (cd "$ARV_DIR" && exec ./arv_grab "$SEG_DUR" dump >> "$FIFO" 2>> "$LOG") &
    fpid=$!
    log "seg#$seg feeder pid $fpid"

    last=-1; stall=0; dead=0; t0=$(date +%s)
    while kill -0 "$fpid" 2>/dev/null; do
        sleep "$POLL"
        kill -0 "$fpid" 2>/dev/null || break
        [ -e "$STOP" ] && break
        w=$(awk '/^wchar/{print $2}' "/proc/$fpid/io" 2>/dev/null)
        if [ -z "$w" ]; then dead=1; break; fi
        if [ "$w" = "$last" ]; then
            stall=$((stall + 1))
        else
            stall=0
        fi
        last=$w
        if [ "$stall" -ge "$STALL_POLLS" ]; then dead=1; break; fi
    done
    elapsed=$(( $(date +%s) - t0 ))
    kill -TERM "$fpid" 2>/dev/null; sleep 2
    kill -KILL "$fpid" 2>/dev/null
    wait "$fpid" 2>/dev/null

    if [ -e "$STOP" ]; then log "stop file seen"; break; fi
    kill -0 "$ffpid" 2>/dev/null || { log "ffplay window closed"; break; }

    if [ "$dead" -eq 1 ]; then
        log "seg#$seg stalled after ${elapsed}s (wchar=$last) — recovering"
        vbus_recover
    elif [ "$elapsed" -lt $((SEG_DUR - 15)) ]; then
        log "seg#$seg feeder exited early after ${elapsed}s — recovering"
        vbus_recover
    else
        log "seg#$seg completed OK (${elapsed}s)"
        sleep 1
    fi
done

pkill -KILL -x arv_grab 2>/dev/null
kill "$ffpid" 2>/dev/null
exec 3>&-
rm -f "$FIFO" "$STOP"
systemctl start camera-soak.service
log "preview end — camera-soak restored"
