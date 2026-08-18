#!/bin/bash
set -e

echo "[install] installing TUI"

cat > /usr/local/bin/zvoneni-tui <<'EOF'
#!/bin/bash

# Everything in here manages root-owned state (systemd units, /opt files,
# GPIO). Without this guard a non-root run fails piecemeal deep inside -
# nano opening the schedule read-only, amp settings failing to save -
# instead of saying what is actually wrong. Same guard as zvoneni-update.
if [ "${ZVONENI_TUI_TEST:-0}" != "1" ] && [ "$(id -u)" -ne 0 ]; then
  echo "zvoneni-tui: run as root, e.g. sudo zvoneni-tui" >&2
  exit 1
fi

# ---------------- terminal-aware sizing ----------------

# Prefer stty (reads the tty ioctl directly, works even if TERM is unset
# or wrong); tput as fallback; a hardcoded 80x24 as a last resort so a
# detached/non-interactive run never breaks the arithmetic below.
term_size() {
  local rc
  rc=$(stty size 2>/dev/null) || rc=""
  if [ -n "$rc" ]; then
    read -r TERM_LINES TERM_COLS <<< "$rc"
  else
    TERM_LINES=$(tput lines 2>/dev/null)
    TERM_COLS=$(tput cols 2>/dev/null)
  fi
  [[ "$TERM_LINES" =~ ^[0-9]+$ ]] || TERM_LINES=24
  [[ "$TERM_COLS"  =~ ^[0-9]+$ ]] || TERM_COLS=80
}

# box_size <h_pct> <w_pct> <h_min> <w_min> <h_max> <w_max>
# Percent-of-terminal box size, clamped to [min,max] and then to the
# terminal itself (leaves a small margin). Sets BH/BW.
#
# Deliberately not dialog's own "0 0" auto-size: that fits tightly to
# content only and can't be told to fill more of a big console - on the
# appliance's physical 1920x1080 / 240x67-character console, fixed small
# boxes render as a tiny island on a sea of black. Explicit computed and
# clamped sizing (same idea raspi-config uses) fixes that while still
# fitting a small SSH window.
box_size() {
  local hp=$1 wp=$2 hmin=$3 wmin=$4 hmax=$5 wmax=$6
  BH=$(( TERM_LINES * hp / 100 ))
  BW=$(( TERM_COLS  * wp / 100 ))
  (( BH < hmin )) && BH=$hmin
  (( BW < wmin )) && BW=$wmin
  (( BH > hmax )) && BH=$hmax
  (( BW > wmax )) && BW=$wmax
  (( BH > TERM_LINES - 1 )) && BH=$(( TERM_LINES - 1 ))
  (( BW > TERM_COLS  - 2 )) && BW=$(( TERM_COLS  - 2 ))
}

pause() {
  box_size 20 55 8 55 14 80
  dialog --msgbox "$1" "$BH" "$BW"
}

# Run a command with its raw output visible directly in the terminal (not
# inside a dialog box), then wait for Enter and return to the menu. For
# anything whose output is worth watching live - a schedule apply, an
# update - rather than summarized afterward in a --textbox.
#
# exec, not just `bash -c '...'; zvoneni-tui`: the installer can rewrite
# this very script (/usr/local/bin/zvoneni-tui) while it is running - e.g.
# during an update - and bash reads a running script by file offset, so
# continuing without exec would resume reading the OLD file from a stale
# position. exec cleanly restarts, reading the current file from the top.
run_and_return() {  # $* = the command to run
  clear
  # Callers pass literal command strings only - never user input; the
  # restart uses an absolute path so it cannot be hijacked via PATH.
  exec bash -c "$* ; echo; read -rp 'Press Enter to return to the menu... '; exec /usr/local/bin/zvoneni-tui"
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

# Same one-liner as overlay_active() in install/11-update.sh - kept
# duplicated rather than shared, since this file is a standalone script
# with no include mechanism.
overlay_active() {
  findmnt -n -o FSTYPE / 2>/dev/null | grep -q overlay
}

# Single source of truth for the dashboard header shown at the top of the
# main menu. Runs on every main-loop iteration, so it is never stale.
get_status() {
  term_size
  TIME=$(date '+%Y-%m-%d %H:%M:%S')
  GATE=$([ -f /run/clock-ok ] && echo OK || echo WAIT)
  systemctl is-active zvoneni.target >/dev/null 2>&1 && STATE="RUNNING" || STATE="STOPPED"
  OVERLAY=$(overlay_active && echo ON || echo OFF)

  IP=$(ip -4 a 2>/dev/null | awk '/scope global/ {print $2}' | cut -d/ -f1 | head -1)
  [ -z "$IP" ] && IP="(none)"

  NEXT_BELL=$(zvoneni-next-bell 2>/dev/null || echo "-")
  amp_summary

  HEADER="SYSTEM STATE: $STATE
Next bell:    $NEXT_BELL

Time:         $TIME
Clock gate:   $GATE
IP address:   $IP
Overlay FS:   $OVERLAY
Amplifier:    $AMP_INFO
Button:       $BTN_INFO"
}

apply_schedule() {
  # A deliberately temporary change is a legitimate thing to want, so this
  # warns rather than refuses (unlike zvoneni-update, where a silently
  # reverted update would leave the appliance a version behind with no
  # trace). Only appears when the overlay is actually on.
  if overlay_active; then
    # box_size needs TERM_LINES/TERM_COLS; every current caller happens to
    # have run term_size already, but do not rely on that from here.
    term_size
    box_size 35 55 13 64 18 84
    dialog --yes-label "Yes, apply" --no-label "Cancel" \
      --yesno "Overlay filesystem is ON.\n\nThis will work now, but the schedule and the generated timers live in RAM and are LOST on the next reboot.\n\nTo keep it: raspi-config -> Performance Options -> Overlay File System -> off, reboot, apply again, then turn the overlay back on." "$BH" "$BW" || return
  fi

  run_and_return "generate-timers.sh 2>&1 | tee /run/zvoneni-last-apply.log"
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

  box_size 80 90 20 80 200 200
  dialog --title "Active timers (systemctl list-timers)" --textbox "$TMP" "$BH" "$BW"
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

  box_size 75 85 18 70 200 200
  dialog --title "System information" --textbox "$TMP" "$BH" "$BW"
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

  box_size 85 90 24 80 200 200
  dialog --title "Debug information" --textbox "$TMP" "$BH" "$BW"
  rm -f "$TMP"
}

show_help() {
  box_size 65 70 22 70 30 90
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

MENU MAP:
- Schedule:  timers, edit + apply schedule, test bell
- Amplifier: GPIO switching, button, test, force off
- System:    system info, start/stop, audio mixer, Debug
- Update:    check / install / roll back from GitHub

DEBUG (under System):
- real timers on filesystem
- systemd timers
- last apply output
- amplifier state and recent logs
" "$BH" "$BW"
}

show_admin_guide() {
  if [ -f /opt/zvoneni/admin.md ]; then
    box_size 90 90 24 80 200 200
    dialog --title "Admin guide (/opt/zvoneni/admin.md)" --textbox /opt/zvoneni/admin.md "$BH" "$BW"
  else
    pause "admin.md not found in /opt/zvoneni"
  fi
}

help_menu() {
  local choice

  while true; do
    term_size
    box_size 30 50 11 55 16 80

    choice=$(dialog --clear --title "Help" --menu "
Quick help explains the flow; the admin guide is the full
documentation, always matching the installed version.
" "$BH" "$BW" 3 \
      1 "How the bell system works" \
      2 "Admin guide (admin.md)" \
      0 "Back" 3>&1 1>&2 2>&3) || return

    case $choice in
      1) show_help ;;
      2) show_admin_guide ;;
      0|"") return ;;
    esac
  done
}

toggle_system() {
  if [ "$STATE" = "RUNNING" ]; then
    box_size 25 40 7 40 10 55
    dialog --yes-label "Yes, stop" --no-label "Cancel" \
      --yesno "Stop bell system?" "$BH" "$BW" || return
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
    box_size 22 45 7 50 10 60
    dialog --msgbox "No sounds found in /opt/zvoneni/sounds" "$BH" "$BW"
    return
  fi

  box_size 45 55 15 60 26 90
  CHOICE=$(dialog --title "Select sound to play" \
    --menu "Choose sound:" "$BH" "$BW" 10 \
    "${SOUNDS[@]}" 3>&1 1>&2 2>&3)

  [ -z "$CHOICE" ] && return

  amp_load
  if [ "$AMP_ENABLED" -eq 1 ]; then
    box_size 20 45 7 58 10 65
    dialog --infobox "Ringing '$CHOICE' ...\n\nAmplifier on, sound starts in ${AMP_PRE_SECONDS}s." "$BH" "$BW"
  else
    box_size 15 35 5 45 8 55
    dialog --infobox "Ringing '$CHOICE' ..." "$BH" "$BW"
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
    box_size 45 55 18 68 26 90
    out=$(dialog --title "Amplifier settings" --form "
GPIO pin        BCM number, 0-27
Seconds before  power-up lead time, 0-300
Seconds after   hold time once the sound ends, 0-300
Active high     1 = HIGH switches the amp on, 0 = LOW does
" "$BH" "$BW" 4 \
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

    box_size 28 45 10 60 16 75
    dialog --title "Invalid values" --msgbox "$err" "$BH" "$BW"
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
    box_size 40 55 16 76 24 95
    out=$(dialog --title "Button settings" --form "
GPIO pin     BCM number, 0-27, must differ from the amplifier pin ($AMP_GPIO)
Active low   1 = pressed reads LOW (button to GND, internal pull-up)
             0 = pressed reads HIGH (button to 3V3, internal pull-down)
" "$BH" "$BW" 2 \
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

    box_size 28 48 10 66 16 80
    dialog --title "Invalid values" --msgbox "$err" "$BH" "$BW"
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

  box_size 15 40 5 55 8 65
  dialog --infobox "Amplifier ON for 5 seconds (GPIO $AMP_GPIO) ..." "$BH" "$BW"
  zvoneni-amp test 5 >/dev/null 2>&1
  pause "Test finished. GPIO $AMP_GPIO is back OFF."
}

amp_status_box() {
  TMP=$(mktemp)
  zvoneni-amp status > "$TMP" 2>&1
  box_size 55 70 18 78 200 200
  dialog --title "Amplifier status" --textbox "$TMP" "$BH" "$BW"
  rm -f "$TMP"
}

amp_menu() {
  local choice

  while true; do
    term_size
    amp_summary
    box_size 55 58 23 72 32 100

    choice=$(dialog --clear --title "Amplifier" --menu "
Amplifier switching: $AMP_INFO
Hold-to-talk button: $BTN_INFO

The bell still rings exactly on time - the timer is moved
earlier by the pre-roll so the amplifier can warm up first.
The button keeps the amplifier on while it is held down.
" "$BH" "$BW" 8 \
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
        box_size 28 45 10 62 14 75
        dialog --yes-label "Yes, force off" --no-label "Cancel" \
          --yesno "Force the amplifier OFF now?\n\nThis drops any bell or button currently holding it on." "$BH" "$BW" || continue
        zvoneni-amp reset >/dev/null 2>&1
        pause "Amplifier forced OFF."
        ;;
      0|"") return ;;
    esac
  done
}

# ---------------- update ----------------

update_check() {
  TMP=$(mktemp)
  box_size 15 30 5 40 8 50
  dialog --infobox "Contacting GitHub ..." "$BH" "$BW"
  zvoneni-update check > "$TMP" 2>&1
  box_size 80 88 24 92 200 200
  dialog --title "Update check" --textbox "$TMP" "$BH" "$BW"
  rm -f "$TMP"
}

update_status() {
  TMP=$(mktemp)
  zvoneni-update status > "$TMP" 2>&1
  box_size 55 75 16 86 200 200
  dialog --title "Installed version" --textbox "$TMP" "$BH" "$BW"
  rm -f "$TMP"
}

update_run() {  # $1 = apply|rollback
  run_and_return "zvoneni-update $1"
}

update_menu() {
  local choice

  while true; do
    term_size
    box_size 50 55 20 70 28 95

    choice=$(dialog --clear --title "Update" --menu "
Checks GitHub for a newer version and installs it.

The schedule and the amplifier settings are kept; settings
added by a new version get their defaults.
" "$BH" "$BW" 5 \
      1 "Check for updates" \
      2 "Install update" \
      3 "Roll back to the previous version" \
      4 "Installed version" \
      0 "Back" 3>&1 1>&2 2>&3) || return

    case $choice in
      1) update_check ;;
      2)
        box_size 35 50 13 66 18 80
        dialog --yes-label "Yes, install" --no-label "Cancel" \
          --yesno "Install the update now?\n\nThe menu closes, the update runs in the terminal, then the menu comes back.\n\nSchedule and settings are kept." "$BH" "$BW" || continue
        update_run apply
        ;;
      3)
        box_size 25 45 8 62 12 75
        dialog --yes-label "Yes, roll back" --no-label "Cancel" \
          --yesno "Roll back to the version installed before the last update?" "$BH" "$BW" || continue
        update_run rollback
        ;;
      4) update_status ;;
      0|"") return ;;
    esac
  done
}

# ---------------- schedule ----------------

schedule_menu() {
  local choice

  while true; do
    term_size
    NEXT_BELL=$(zvoneni-next-bell 2>/dev/null || echo "-")
    box_size 45 55 16 65 24 90

    choice=$(dialog --clear --title "Schedule" --menu "
Next bell: $NEXT_BELL

Edit changes /opt/zvoneni/schedule.txt directly (nano).
Apply regenerates the systemd timers from it.
" "$BH" "$BW" 5 \
      1 "Show active timers" \
      2 "Edit schedule" \
      3 "Apply schedule" \
      4 "Test bell (select sound)" \
      0 "Back" 3>&1 1>&2 2>&3) || return

    case $choice in
      1) show_timers ;;
      2) nano /opt/zvoneni/schedule.txt ;;
      3)
        box_size 25 40 7 40 10 55
        dialog --yes-label "Yes, apply" --no-label "Cancel" \
          --yesno "Apply new schedule?" "$BH" "$BW" || continue
        apply_schedule
        ;;
      4) test_sound ;;
      0|"") return ;;
    esac
  done
}

# ---------------- system ----------------

system_menu() {
  local choice

  while true; do
    get_status
    box_size 40 55 15 60 22 90

    choice=$(dialog --clear --title "System" --menu "
SYSTEM STATE: $STATE
Clock gate:   $GATE
IP address:   $IP
Overlay FS:   $OVERLAY
" "$BH" "$BW" 5 \
      1 "System information" \
      2 "Toggle bell system (START/STOP)" \
      3 "Audio mixer (alsamixer)" \
      4 "Debug" \
      0 "Back" 3>&1 1>&2 2>&3) || return

    case $choice in
      1) system_info ;;
      2) toggle_system ;;
      3) open_mixer ;;
      4) show_debug ;;
      0|"") return ;;
    esac
  done
}

# ---------------- main ----------------

# Guarded so this file can be `source`d (e.g. by a test harness) without
# immediately blocking on the real interactive loop. Unset/anything other
# than "1" behaves exactly as before - this changes nothing in production.
if [ "${ZVONENI_TUI_TEST:-0}" != "1" ]; then
while true; do
  get_status
  box_size 55 60 23 70 34 110

  choice=$(dialog --clear \
    --title "School Bell System" \
    --menu "
$HEADER
" "$BH" "$BW" 7 \
    1 "Refresh" \
    2 "Schedule" \
    3 "Amplifier" \
    4 "System" \
    5 "Update" \
    6 "Help" \
    0 "Exit" 3>&1 1>&2 2>&3)

  case $choice in
    1) : ;;
    2) schedule_menu ;;
    3) amp_menu ;;
    4) system_menu ;;
    5) update_menu ;;
    6) help_menu ;;
    0) clear; exit ;;
  esac
done
fi
EOF

chmod +x /usr/local/bin/zvoneni-tui
