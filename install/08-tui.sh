#!/bin/bash
set -e

echo "[install] installing TUI"

cat > /usr/local/bin/zvoneni-tui <<'EOF'
#!/bin/bash

pause() {
  dialog --msgbox "$1" 8 60
}

get_status() {
  TIME=$(date '+%Y-%m-%d %H:%M:%S')
  GATE=$([ -f /run/clock-ok ] && echo OK || echo WAIT)
  systemctl is-active zvoneni.target >/dev/null 2>&1 && STATE="RUNNING" || STATE="STOPPED"
}

show_timers() {
  TMP=$(mktemp)

  systemctl list-timers --no-pager --no-legend \
    | grep zvoneni \
    | awk '{printf "%-25s %-10s %s\n", $1" "$2, $3, $NF}' \
    > "$TMP"

  dialog --title "Active timers (NEXT / IN / UNIT)" --textbox "$TMP" 25 80
  rm -f "$TMP"
}

system_info() {
  TMP=$(mktemp)

  {
    echo "Hostname: $(hostname)"
    echo "Time:     $(date)"
    echo
    echo "Uptime:"
    uptime
    echo
    echo "IP addresses:"
    ip -4 a | grep inet
  } > "$TMP"

  dialog --title "System information" --textbox "$TMP" 22 80
  rm -f "$TMP"
}

show_help() {
  dialog --title "How the bell system works" --msgbox "
=== OVERVIEW ===
This system uses systemd timers (not cron).

FLOW:
schedule.txt
 → generate-timers.sh
 → systemd timers
 → zvoneni.target
 → zvoneni@.service
 → aplay (sound output)

TIME SAFETY:
clock-watch.service creates /run/clock-ok
Only then bells are allowed to ring.

FILES:
Schedule: /opt/zvoneni/schedule.txt
Sounds:   /opt/zvoneni/sounds/
TUI:      /usr/local/bin/zvoneni-tui

SERVICES:
clock-watch.service  (time gate)
zvoneni@.service     (player)
zvoneni.target       (master switch)

Overlay FS (optional):
Enable via raspi-config for production
" 25 75
}

toggle_system() {
  if [ "$STATE" = "RUNNING" ]; then
    dialog --yesno "Stop bell system?" 7 40 || return
    systemctl stop zvoneni.target
    pause "Bell system STOPPED"
  else
    systemctl start zvoneni.target
    pause "Bell system STARTED"
  fi
}

while true; do
  get_status

  choice=$(dialog --clear \
    --title "School Bell System" \
    --menu "
SYSTEM STATE: $STATE

Time:        $TIME
Clock gate:  $GATE
" 20 70 10 \
    1 "Refresh status" \
    2 "Show active timers" \
    3 "System information" \
    4 "Edit schedule" \
    5 "Apply schedule" \
    6 "Test bell" \
    7 "Toggle bell system (START/STOP)" \
    8 "Help" \
    9 "Exit" 3>&1 1>&2 2>&3)

  case $choice in
    1) : ;;
    2) show_timers ;;
    3) system_info ;;
    4) nano /opt/zvoneni/schedule.txt ;;
    5)
      dialog --yesno "Apply new schedule?" 7 40 && \
      generate-timers.sh && pause "Schedule applied"
      ;;
    6)
      systemctl start zvoneni@normal.service
      pause "Test bell played"
      ;;
    7) toggle_system ;;
    8) show_help ;;
    9) clear; exit ;;
  esac
done
EOF

chmod +x /usr/local/bin/zvoneni-tui
