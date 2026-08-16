#!/bin/bash
set -e

echo "[install] installing TUI"

cat > /usr/local/bin/zvoneni-tui <<'EOF'
#!/bin/bash

pause() {
  dialog --msgbox "$1" 8 70
}

AMP_CONF=/opt/zvoneni/amp.conf

amp_load() {
  AMP_ENABLED=0
  AMP_GPIO=17
  AMP_ACTIVE_HIGH=1
  AMP_PRE_SECONDS=10
  AMP_POST_SECONDS=2

  if command -v zvoneni-amp >/dev/null 2>&1; then
    eval "$(zvoneni-amp config 2>/dev/null)"
  fi
}

amp_summary() {
  amp_load
  if [ "$AMP_ENABLED" -eq 1 ]; then
    AMP_INFO="ON  (GPIO $AMP_GPIO, -${AMP_PRE_SECONDS}s / +${AMP_POST_SECONDS}s)"
  else
    AMP_INFO="OFF"
  fi
}

get_status() {
  TIME=$(date '+%Y-%m-%d %H:%M:%S')
  GATE=$([ -f /run/clock-ok ] && echo OK || echo WAIT)
  systemctl is-active zvoneni.target >/dev/null 2>&1 && STATE="RUNNING" || STATE="STOPPED"
  amp_summary
}

apply_schedule() {
  generate-timers.sh 2>&1 | tee /run/zvoneni-last-apply.log
  RC=${PIPESTATUS[0]}

  if [ $RC -ne 0 ]; then
    dialog --title "Schedule error" --textbox /run/zvoneni-last-apply.log 25 80
  else
    dialog --title "Schedule applied" --textbox /run/zvoneni-last-apply.log 25 80
  fi
}

show_timers() {
  TMP=$(mktemp)

  systemctl list-timers --all --no-pager \
    | grep -i zvoneni \
    > "$TMP"

  if [ ! -s "$TMP" ]; then
    echo "(none)" > "$TMP"
  fi

  dialog --title "Active timers (systemctl list-timers)" --textbox "$TMP" 25 100
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
    ip -4 a | grep "scope global"
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
    echo "=== AMPLIFIER ==="
    if command -v zvoneni-amp >/dev/null 2>&1; then
      zvoneni-amp status 2>&1
      echo
      echo "--- $AMP_CONF ---"
      cat "$AMP_CONF" 2>/dev/null || echo "(missing)"
      echo
      systemctl is-enabled zvoneni-amp-reset.service 2>&1 \
        | sed 's/^/zvoneni-amp-reset.service: /'
    else
      echo "(zvoneni-amp not installed)"
    fi
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
schedule.txt → generate-timers.sh → systemd timers → zvoneni.target → zvoneni@.service → zvoneni-ring → sound

AMPLIFIER (optional):
- timer fires PRE seconds early, amplifier is switched on
- the sound still starts exactly at the scheduled time
- amplifier goes off POST seconds after the sound ends

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

  amp_load
  if [ "$AMP_ENABLED" -eq 1 ]; then
    dialog --infobox "Ringing '$CHOICE' ...\n\nAmplifier on, sound starts in ${AMP_PRE_SECONDS}s." 7 58
  else
    dialog --infobox "Ringing '$CHOICE' ..." 5 45
  fi

  systemctl start "zvoneni@${CHOICE}.service"
  pause "Played sound: $CHOICE"
}

open_mixer() {
  alsamixer
}

# ---------------- amplifier ----------------

amp_valid() {  # value min max
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

amp_save() {  # enabled gpio active_high pre post
  local tmp
  tmp=$(mktemp /opt/zvoneni/.amp.conf.XXXXXX) || return 1

  cat > "$tmp" <<AMPCONF
# Amplifier switching for the school bell system.
# Managed by zvoneni-tui -> Amplifier. Rewritten wholesale on every save.
AMP_ENABLED=$1
AMP_GPIO=$2
AMP_ACTIVE_HIGH=$3
AMP_PRE_SECONDS=$4
AMP_POST_SECONDS=$5
AMPCONF

  chmod 644 "$tmp"
  mv -f "$tmp" "$AMP_CONF"
}

amp_form() {
  amp_load
  local g="$AMP_GPIO" pre="$AMP_PRE_SECONDS" post="$AMP_POST_SECONDS" ah="$AMP_ACTIVE_HIGH"
  local out err

  while true; do
    out=$(dialog --title "Amplifier settings" --form "
GPIO pin        BCM number, 0-27
Seconds before  power-up lead time, 0-300
Seconds after   hold time once the sound ends, 0-300
Active high     1 = HIGH switches the amp on, 0 = LOW does
" 18 68 4 \
      "GPIO pin:"       1 1 "$g"    1 20 8 4 \
      "Seconds before:" 2 1 "$pre"  2 20 8 4 \
      "Seconds after:"  3 1 "$post" 3 20 8 4 \
      "Active high:"    4 1 "$ah"   4 20 8 4 \
      3>&1 1>&2 2>&3) || return

    { read -r g; read -r pre; read -r post; read -r ah; } <<< "$out"

    err=""
    amp_valid "$g"    0 27  || err="${err}GPIO pin must be a number 0-27."$'\n'
    amp_valid "$pre"  0 300 || err="${err}Seconds before must be 0-300."$'\n'
    amp_valid "$post" 0 300 || err="${err}Seconds after must be 0-300."$'\n'
    amp_valid "$ah"   0 1   || err="${err}Active high must be 0 or 1."$'\n'

    if [ -z "$err" ]; then
      # canonical decimal, so a typed "08" never reaches an arithmetic context
      g=$((10#$g)); pre=$((10#$pre)); post=$((10#$post)); ah=$((10#$ah))
      break
    fi

    dialog --title "Invalid values" --msgbox "$err" 10 60
  done

  if ! amp_save "$AMP_ENABLED" "$g" "$ah" "$pre" "$post"; then
    pause "Cannot write $AMP_CONF (read-only filesystem?)"
    return
  fi

  # Timer offsets depend on the pre-roll, so the schedule has to be reapplied.
  apply_schedule
}

amp_toggle() {
  amp_load

  local new=0
  [ "$AMP_ENABLED" -eq 1 ] || new=1

  if ! amp_save "$new" "$AMP_GPIO" "$AMP_ACTIVE_HIGH" "$AMP_PRE_SECONDS" "$AMP_POST_SECONDS"; then
    pause "Cannot write $AMP_CONF (read-only filesystem?)"
    return
  fi

  apply_schedule
}

amp_test_output() {
  amp_load

  if [ "$AMP_ENABLED" -ne 1 ]; then
    pause "Amplifier switching is disabled. Enable it first."
    return
  fi

  dialog --infobox "Amplifier ON for 5 seconds (GPIO $AMP_GPIO) ..." 5 55
  zvoneni-amp test 5 >/dev/null 2>&1
  pause "Test finished. GPIO $AMP_GPIO is back OFF."
}

amp_status_box() {
  TMP=$(mktemp)
  zvoneni-amp status > "$TMP" 2>&1
  dialog --title "Amplifier status" --textbox "$TMP" 18 78
  rm -f "$TMP"
}

amp_menu() {
  local choice

  while true; do
    amp_summary

    choice=$(dialog --clear --title "Amplifier" --menu "
Amplifier switching: $AMP_INFO

The bell still rings exactly on time - the timer is moved
earlier by the pre-roll so the amplifier can warm up first.
" 20 72 6 \
      1 "Enable / disable amplifier switching" \
      2 "Settings (GPIO, timing, polarity)" \
      3 "Test amplifier (on for 5 s)" \
      4 "Amplifier status" \
      5 "Force amplifier OFF (reset)" \
      0 "Back" 3>&1 1>&2 2>&3) || return

    case $choice in
      1) amp_toggle ;;
      2) amp_form ;;
      3) amp_test_output ;;
      4) amp_status_box ;;
      5)
        zvoneni-amp reset >/dev/null 2>&1
        pause "Amplifier forced OFF."
        ;;
      0|"") return ;;
    esac
  done
}

while true; do
  get_status

  choice=$(dialog --clear \
    --title "School Bell System" \
    --menu "
SYSTEM STATE: $STATE

Time:        $TIME
Clock gate:  $GATE
Amplifier:   $AMP_INFO
" 24 75 13 \
    1 "Refresh status" \
    2 "Show active timers" \
    3 "System information" \
    4 "Edit schedule" \
    5 "Apply schedule" \
    6 "Test bell (select sound)" \
    7 "Toggle bell system (START/STOP)" \
    8 "Audio mixer (alsamixer)" \
    9 "Debug" \
    10 "Help" \
    11 "Amplifier (GPIO switching)" \
    0 "Exit" 3>&1 1>&2 2>&3)

  case $choice in
    1) : ;;
    2) show_timers ;;
    3) system_info ;;
    4) nano /opt/zvoneni/schedule.txt ;;
    5)
      dialog --yesno "Apply new schedule?" 7 40 || continue
      apply_schedule
      ;;
    6) test_sound ;;
    7) toggle_system ;;
    8) open_mixer ;;
    9) show_debug ;;
    10) show_help ;;
    11) amp_menu ;;
    0) clear; exit ;;
  esac
done
EOF

chmod +x /usr/local/bin/zvoneni-tui
