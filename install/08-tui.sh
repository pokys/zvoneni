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
  BUTTON_ENABLED=0
  BUTTON_GPIO=27
  BUTTON_ACTIVE_LOW=1

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

  if [ "$BUTTON_ENABLED" -eq 1 ]; then
    BTN_INFO="ON  (GPIO $BUTTON_GPIO, active $([ "$BUTTON_ACTIVE_LOW" -eq 1 ] && echo low || echo high))"
  else
    BTN_INFO="OFF"
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

  {
    echo "Next bell: $(zvoneni-next-bell 2>/dev/null || echo '-')"
    echo

    amp_load
    if [ "$AMP_ENABLED" -eq 1 ] && [ "$AMP_PRE_SECONDS" -gt 0 ]; then
      echo "NOTE: timers fire ${AMP_PRE_SECONDS}s early so the amplifier can warm up,"
      echo "      so the NEXT column below is ${AMP_PRE_SECONDS}s before the bell itself."
      echo
    fi

    systemctl list-timers --all --no-pager | grep -i zvoneni || echo "(none)"
  } > "$TMP"

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
    journalctl -u zvoneni@* -u zvoneni.target -u clock-watch \
      -u zvoneni-amp-button --no-pager -n 25 || true
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

BUTTON (optional):
- holding it keeps the amplifier on
- needs amplifier switching enabled
- a bell ending will not cut it off while it is held

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

# Writes whatever amp_load put in the globals, so callers do
# amp_load -> change a variable -> amp_save.
amp_save() {
  local tmp
  tmp=$(mktemp /opt/zvoneni/.amp.conf.XXXXXX) || return 1

  cat > "$tmp" <<AMPCONF
# Amplifier switching for the school bell system.
# Managed by zvoneni-tui -> Amplifier. Rewritten wholesale on every save.
AMP_ENABLED=$AMP_ENABLED
AMP_GPIO=$AMP_GPIO
AMP_ACTIVE_HIGH=$AMP_ACTIVE_HIGH
AMP_PRE_SECONDS=$AMP_PRE_SECONDS
AMP_POST_SECONDS=$AMP_POST_SECONDS
BUTTON_ENABLED=$BUTTON_ENABLED
BUTTON_GPIO=$BUTTON_GPIO
BUTTON_ACTIVE_LOW=$BUTTON_ACTIVE_LOW
AMPCONF

  chmod 644 "$tmp"
  mv -f "$tmp" "$AMP_CONF"
}

# The unit is always enabled and decides from amp.conf whether to run,
# so a restart is all that is ever needed after a config change.
button_sync() {
  systemctl restart zvoneni-amp-button.service >/dev/null 2>&1
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

  AMP_GPIO=$g
  AMP_PRE_SECONDS=$pre
  AMP_POST_SECONDS=$post
  AMP_ACTIVE_HIGH=$ah

  if ! amp_save; then
    pause "Cannot write $AMP_CONF (read-only filesystem?)"
    return
  fi

  # Timer offsets depend on the pre-roll, so the schedule has to be reapplied.
  apply_schedule
}

amp_toggle() {
  amp_load

  if [ "$AMP_ENABLED" -eq 1 ]; then
    AMP_ENABLED=0
  else
    AMP_ENABLED=1
  fi

  if ! amp_save; then
    pause "Cannot write $AMP_CONF (read-only filesystem?)"
    return
  fi

  apply_schedule
}

button_toggle() {
  amp_load

  if [ "$BUTTON_ENABLED" -eq 1 ]; then
    BUTTON_ENABLED=0
  else
    BUTTON_ENABLED=1
  fi

  if ! amp_save; then
    pause "Cannot write $AMP_CONF (read-only filesystem?)"
    return
  fi

  button_sync

  if [ "$BUTTON_ENABLED" -eq 1 ] && [ "$AMP_ENABLED" -ne 1 ]; then
    pause "Button enabled, but amplifier switching is OFF - the button will do nothing until you enable it."
  fi
}

button_form() {
  amp_load
  local g="$BUTTON_GPIO" al="$BUTTON_ACTIVE_LOW"
  local out err

  while true; do
    out=$(dialog --title "Button settings" --form "
GPIO pin     BCM number, 0-27, must differ from the amplifier pin ($AMP_GPIO)
Active low   1 = pressed reads LOW (button to GND, internal pull-up)
             0 = pressed reads HIGH (button to 3V3, internal pull-down)
" 16 76 2 \
      "GPIO pin:"   1 1 "$g"  1 16 8 4 \
      "Active low:" 2 1 "$al" 2 16 8 4 \
      3>&1 1>&2 2>&3) || return

    { read -r g; read -r al; } <<< "$out"

    err=""
    amp_valid "$g"  0 27 || err="${err}GPIO pin must be a number 0-27."$'\n'
    amp_valid "$al" 0 1  || err="${err}Active low must be 0 or 1."$'\n'

    if [ -z "$err" ] && [ "$((10#$g))" -eq "$AMP_GPIO" ]; then
      err="GPIO pin must differ from the amplifier pin ($AMP_GPIO)."$'\n'
    fi

    if [ -z "$err" ]; then
      g=$((10#$g)); al=$((10#$al))
      break
    fi

    dialog --title "Invalid values" --msgbox "$err" 10 66
  done

  BUTTON_GPIO=$g
  BUTTON_ACTIVE_LOW=$al

  if ! amp_save; then
    pause "Cannot write $AMP_CONF (read-only filesystem?)"
    return
  fi

  button_sync
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
Hold-to-talk button: $BTN_INFO

The bell still rings exactly on time - the timer is moved
earlier by the pre-roll so the amplifier can warm up first.
The button keeps the amplifier on while it is held down.
" 23 72 8 \
      1 "Enable / disable amplifier switching" \
      2 "Amplifier settings (GPIO, timing, polarity)" \
      3 "Test amplifier (on for 5 s)" \
      4 "Enable / disable the button" \
      5 "Button settings (GPIO, polarity)" \
      6 "Amplifier status" \
      7 "Force amplifier OFF (reset)" \
      0 "Back" 3>&1 1>&2 2>&3) || return

    case $choice in
      1) amp_toggle ;;
      2) amp_form ;;
      3) amp_test_output ;;
      4) button_toggle ;;
      5) button_form ;;
      6) amp_status_box ;;
      7)
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
