#!/bin/bash
set -e

cat > /usr/local/bin/zvoneni-tui <<'EOF'
#!/bin/bash

pause() {
  dialog --msgbox "$1" 8 60
}

get_status() {
  TIME=$(date '+%Y-%m-%d %H:%M:%S')
  GATE=$([ -f /run/clock-ok ] && echo OK || echo WAIT)

  if systemctl is-active zvoneni.target >/dev/null 2>&1; then
    STATE="RUNNING"
  else
    STATE="STOPPED"
  fi
}

show_timers() {
  systemctl list-timers --no-pager | grep zvoneni | \
    dialog --title "Active timers" --programbox 20 80
}

system_info() {
  {
    echo "Hostname: $(hostname)"
    echo "Time:     $(date)"
    echo
    echo "Uptime:"
    uptime
    echo
    echo "IP addresses:"
    ip -4 a | grep inet
    echo
  } | dialog --title "System information" --programbox 22 80
}

show_help() {
  dialog --title "How the bell system works" --msgbox "
=== OVERVIEW ===
This system uses systemd timers, not cron.

Flow:
  schedule.txt
      ↓
  generate-timers.sh
      ↓
  zvoneni-*.timer
      ↓
  zvoneni.target (ON/OFF switch)
      ↓
  zvoneni@.service
      ↓
  aplay (sound output)

=== TIME SAFETY ===
clock-watch.service monitors:
  - NTP sync OR
  - uptime > 5 minutes

Only when /run/clock-ok exists,
bells are allowed to ring.

=== FILES ===
Schedule:   /opt/zvoneni/schedule.txt
Sounds:     /opt/zvoneni/sounds/*.wav
TUI:        /usr/local/bin/zvoneni-tui
Generator:  /usr/local/bin/generate-timers.sh

=== SERVICES ===
clock-watch.service  → time gate
zvoneni@.service     → sound player
zvoneni.target       → master switch
zvoneni-*.timer      → individual bells

=== TIPS ===
• Edit schedule → Apply schedule
• Test bell anytime
• Start/Stop system with toggle
• For RO root enable overlay via raspi-config
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
      dialog --yesno "Apply new schedule and regenerate timers?" 8 60 && \
      generate-timers.sh && pause "Schedule applied"
      ;;
    6) systemctl start zvoneni@normal.service && pause "Test bell played" ;;
    7) toggle_system ;;
    8) show_help ;;
    9) clear; exit ;;
  esac
done
EOF

chmod +x /usr/local/bin/zvoneni-tui
