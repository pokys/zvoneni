#!/bin/bash
set -e

echo "[install] installing TUI"

cat > /usr/local/bin/zvoneni-tui <<'EOF'
#!/bin/bash

pause() {
  dialog --msgbox "$1" 8 70
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

show_debug() {
  TMP=$(mktemp)

  {
    echo "=== FILESYSTEM TIMERS ==="
    ls -1 /etc/systemd/system/zvoneni-*.timer 2>/dev/null || echo "(none)"
    echo
    echo "=== TARGET WANTS ==="
    ls -1 /etc/systemd/system/zvoneni.target.wants/ 2>/dev/null || echo "(none)"
    echo
    echo "=== SYSTEMD TIMERS ==="
    systemctl list-timers --no-pager | grep zvoneni || echo "(none)"
    echo
    echo "=== LAST APPLY OUTPUT ==="
    [ -f /run/zvoneni-last-apply.log ] && cat /run/zvoneni-last-apply.log || echo "(none)"
    echo
    echo "=== LAST 25 LOG LINES ==="
    journalctl -u zvoneni@* -u zvoneni.target -u clock-watch --no-pager -n 25 || true
  } > "$TMP"

  dialog --title "Debug information" --textbox "$TMP" 30 100
  rm -f "$TMP"
}

show_help() {
  dialog --title "How the bell system works" --msgbox "
FLOW:
schedule.txt → generate-timers.sh → systemd timers → zvoneni.target → zvoneni@.service → sound

CLOCK GATE:
- waits for NTP at boot (max 3 min)
- then allows bells even without internet
- never blocks again

DEBUG:
Debug menu shows:
- real timers on filesystem
- systemd timers
- last apply output
- recent logs
" 22 70
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

test_sound() {
  SOUNDS=()
  for f in /opt/zvoneni/sounds/*.wav; do
    [ -e "$f" ] || continue
    name=$(basename "$f" .wav)
    SOUNDS+=("$name" "$f")
  done

  if [ ${#SOUNDS[@]} -eq 0 ]; then
    dialog --msgbox "No sounds found in /opt/zvoneni/sounds" 7 50
    return
  fi

  CHOICE=$(dialog --title "Select sound to play" \
    --menu "Choose sound:" 15 60 10 \
    "${SOUNDS[@]}" 3>&1 1>&2 2>&3)

  [ -z "$CHOICE" ] && return

  systemctl start "zvoneni@${CHOICE}.service"
  pause "Played sound: $CHOICE"
}

while true; do
  get_status

  choice=$(dialog --clear \
    --title "School Bell System" \
    --menu "
SYSTEM STATE: $STATE

Time:        $TIME
Clock gate:  $GATE
" 22 75 12 \
    1 "Refresh status" \
    2 "Show active timers" \
    3 "System information" \
    4 "Edit schedule" \
    5 "Apply schedule" \
    6 "Test bell (select sound)" \
    7 "Toggle bell system (START/STOP)" \
    8 "Debug" \
    9 "Help" \
    0 "Exit" 3>&1 1>&2 2>&3)

  case $choice in
    1) : ;;
    2) show_timers ;;
    3) system_info ;;
    4) nano /opt/zvoneni/schedule.txt ;;
    5)
      dialog --yesno "Apply new schedule?" 7 40 || continue

      generate-timers.sh 2>&1 | tee /run/zvoneni-last-apply.log
      RC=${PIPESTATUS[0]}

      if [ $RC -ne 0 ]; then
        dialog --title "Schedule error" --textbox /run/zvoneni-last-apply.log 25 80
      else
        dialog --title "Schedule applied" --textbox /run/zvoneni-last-apply.log 25 80
      fi
      ;;
    6) test_sound ;;
    7) toggle_system ;;
    8) show_debug ;;
    9) show_help ;;
    0) clear; exit ;;
  esac
done
EOF

chmod +x /usr/local/bin/zvoneni-tui
