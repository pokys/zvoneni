#!/bin/bash
set -e

echo "[install] installing amplifier control"

# ------------------------------------------------------------
# CONFIG (never overwrite an existing one)
# ------------------------------------------------------------
[ -f /opt/zvoneni/amp.conf ] || cat > /opt/zvoneni/amp.conf <<'EOF'
# Amplifier switching for the school bell system.
# Managed by zvoneni-tui -> Amplifier. Hand edits are allowed but the TUI
# rewrites this file wholesale, so comments below will not survive.

# 0/1 - master switch for the whole feature
AMP_ENABLED=0

# BCM pin number driving the amplifier (0-27)
AMP_GPIO=17

# 1 = GPIO HIGH switches the amplifier ON, 0 = LOW switches it ON
AMP_ACTIVE_HIGH=1

# seconds to power the amplifier up BEFORE the bell starts playing (0-300)
AMP_PRE_SECONDS=10

# seconds to keep it powered AFTER the sound has finished (0-300)
AMP_POST_SECONDS=2

# Hold-to-talk button: while it is held down the amplifier stays on.
# Requires AMP_ENABLED=1 - the button claims the amplifier, it does not
# bypass it.

# 0/1 - switch for the button
BUTTON_ENABLED=0

# BCM pin the button is wired to (0-27), must differ from AMP_GPIO
BUTTON_GPIO=27

# 1 = pressed reads LOW (button between the pin and GND, internal pull-up)
BUTTON_ACTIVE_LOW=1
EOF

# ------------------------------------------------------------
# zvoneni-amp - the only thing that touches the GPIO pin
# ------------------------------------------------------------
cat > /usr/local/bin/zvoneni-amp <<'EOF'
#!/bin/bash
# Amplifier GPIO control for the school bell system.
#
# Several things can need the amplifier at the same time (a bell ringing,
# a held button), so callers claim it by name and it is powered down only
# once the last holder lets go. Holder state lives in /run, which is a
# tmpfs: no SD card writes, and a holder orphaned by a crash or a reboot
# disappears on its own.
set -uo pipefail

CONF=/opt/zvoneni/amp.conf
STATE_DIR=/run/zvoneni-amp
LOCK=/run/zvoneni-amp.lock
# Set while the pin is energised by us. Without it, switching the feature
# off mid-ring would strand the amplifier on: the release would bail out
# on AMP_ENABLED=0 and nothing, not even `reset`, could bring it down.
# Lives outside STATE_DIR so it does not count as a holder, and in /run so
# a reboot clears it and the boot failsafe leaves foreign pins alone.
OWNED=/run/zvoneni-amp.owned

log() { echo "zvoneni-amp: $*" >&2; }

usage() {
  cat >&2 <<USAGE
usage: zvoneni-amp <command>

  on <holder>     claim the amplifier for <holder>
  off <holder>    release it; powers down when no holder is left
  reset           drop every holder and force the amplifier off
  status          show configuration, pin state and current holders
  test [seconds]  switch the amplifier on for a while (default 5)
  config          print the validated configuration as KEY=VALUE
USAGE
  exit 2
}

# ---- configuration ----------------------------------------------------

sane() {  # value default min max name
  local v="$1" d="$2" lo="$3" hi="$4" n="$5"
  if [[ ! "$v" =~ ^[0-9]+$ ]] || [ "$v" -lt "$lo" ] || [ "$v" -gt "$hi" ]; then
    log "invalid $n='$v', falling back to $d"
    printf '%s' "$d"
  else
    # 10# strips leading zeros: a value like 08 would otherwise blow up in
    # arithmetic contexts elsewhere ("value too great for base").
    printf '%s' "$((10#$v))"
  fi
}

load_config() {
  AMP_ENABLED=0
  AMP_GPIO=17
  AMP_ACTIVE_HIGH=1
  AMP_PRE_SECONDS=10
  AMP_POST_SECONDS=2
  BUTTON_ENABLED=0
  BUTTON_GPIO=27
  BUTTON_ACTIVE_LOW=1

  if [ -r "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF" 2>/dev/null || log "cannot read $CONF, using defaults"
  fi

  AMP_ENABLED=$(sane "${AMP_ENABLED:-0}" 0 0 1 AMP_ENABLED)
  AMP_GPIO=$(sane "${AMP_GPIO:-17}" 17 0 27 AMP_GPIO)
  AMP_ACTIVE_HIGH=$(sane "${AMP_ACTIVE_HIGH:-1}" 1 0 1 AMP_ACTIVE_HIGH)
  AMP_PRE_SECONDS=$(sane "${AMP_PRE_SECONDS:-10}" 10 0 300 AMP_PRE_SECONDS)
  AMP_POST_SECONDS=$(sane "${AMP_POST_SECONDS:-2}" 2 0 300 AMP_POST_SECONDS)
  BUTTON_ENABLED=$(sane "${BUTTON_ENABLED:-0}" 0 0 1 BUTTON_ENABLED)
  BUTTON_GPIO=$(sane "${BUTTON_GPIO:-27}" 27 0 27 BUTTON_GPIO)
  BUTTON_ACTIVE_LOW=$(sane "${BUTTON_ACTIVE_LOW:-1}" 1 0 1 BUTTON_ACTIVE_LOW)

  # One pin cannot be an output and an input at once. Rather than let the
  # button fight the amplifier for the pin, refuse the button.
  if [ "$BUTTON_ENABLED" -eq 1 ] && [ "$BUTTON_GPIO" -eq "$AMP_GPIO" ]; then
    log "BUTTON_GPIO $BUTTON_GPIO is also AMP_GPIO, disabling the button"
    BUTTON_ENABLED=0
  fi
}

# ---- GPIO -------------------------------------------------------------

# pinctrl is used rather than libgpiod's gpioset because it latches the
# level: gpioset releases the line when it exits and the pin falls back.
have_pinctrl() { command -v pinctrl >/dev/null 2>&1; }

amp_write() {  # 1 = amplifier on, 0 = amplifier off
  local want="$1" level gpio="$AMP_GPIO" ah="$AMP_ACTIVE_HIGH"

  # Switching OFF must undo the exact switch-on: if the admin changes
  # AMP_GPIO or the polarity while the amplifier is energised, releasing
  # with the NEW config would drive the wrong pin (or the wrong level)
  # and leave the old pin stuck on. The marker therefore records which
  # pin and polarity were used to switch on, and OFF replays those. All
  # of this runs under the flock every caller already holds.
  if [ "$want" -eq 0 ] && [ -s "$OWNED" ]; then
    read -r gpio ah < "$OWNED" 2>/dev/null || { gpio="$AMP_GPIO"; ah="$AMP_ACTIVE_HIGH"; }
    [[ "$gpio" =~ ^[0-9]+$ ]] || gpio="$AMP_GPIO"
    [[ "$ah"   =~ ^[01]$   ]] || ah="$AMP_ACTIVE_HIGH"
  fi

  if [ "$ah" -eq 1 ]; then
    [ "$want" -eq 1 ] && level=dh || level=dl
  else
    [ "$want" -eq 1 ] && level=dl || level=dh
  fi

  if ! have_pinctrl; then
    log "pinctrl not found - cannot drive GPIO $gpio (install raspi-utils)"
    return 1
  fi

  if ! pinctrl set "$gpio" op "$level" 2>/dev/null; then
    log "pinctrl set $gpio op $level failed"
    return 1
  fi

  if [ "$want" -eq 1 ]; then
    printf '%s %s\n' "$gpio" "$ah" > "$OWNED"
  else
    rm -f "$OWNED"
  fi
}

# True once we have energised the pin and not yet brought it down.
amp_owned() { [ -e "$OWNED" ]; }

# Releasing and resetting must work even after the feature has been
# switched off, otherwise the amplifier stays on for good. When we never
# touched the pin, stay away from it - it may serve something else now.
may_touch_pin() { [ "$AMP_ENABLED" -eq 1 ] || amp_owned; }

pin_state() {
  if ! have_pinctrl; then
    echo "unknown (pinctrl not installed)"
    return
  fi

  local out mode level
  out=$(pinctrl get "$AMP_GPIO" 2>/dev/null) || { echo "unknown"; return; }

  # An input pin still reports a level, but it is whatever the outside
  # world puts on it - claiming ON/OFF for a pin we do not drive is a lie.
  mode=$(echo "$out" | grep -o -E '\b(ip|op)\b' | head -n1)
  if [ "$mode" != "op" ]; then
    echo "not driven ($out)"
    return
  fi

  level=$(echo "$out" | grep -o -E '\b(dh|dl|hi|lo)\b' | head -n1)

  case "$level" in
    dh|hi) [ "$AMP_ACTIVE_HIGH" -eq 1 ] && echo "ON  ($out)" || echo "OFF ($out)" ;;
    dl|lo) [ "$AMP_ACTIVE_HIGH" -eq 1 ] && echo "OFF ($out)" || echo "ON  ($out)" ;;
    *)     echo "unknown ($out)" ;;
  esac
}

button_state() {
  if [ "$BUTTON_ENABLED" -ne 1 ]; then
    echo "disabled"
    return
  fi

  if ! have_pinctrl; then
    echo "unknown (pinctrl not installed)"
    return
  fi

  local out lvl
  out=$(pinctrl get "$BUTTON_GPIO" 2>/dev/null) || { echo "unknown"; return; }
  lvl=$(echo "$out" | grep -o -E '\b(hi|lo)\b' | head -n1)

  case "$lvl" in
    hi) [ "$BUTTON_ACTIVE_LOW" -eq 1 ] && echo "released ($out)" || echo "PRESSED ($out)" ;;
    lo) [ "$BUTTON_ACTIVE_LOW" -eq 1 ] && echo "PRESSED ($out)" || echo "released ($out)" ;;
    *)  echo "unknown ($out)" ;;
  esac
}

# ---- holders ----------------------------------------------------------

# Holder names end up as file names, so keep them boring.
clean_holder() { echo "${1//[^A-Za-z0-9_.-]/_}"; }

take_lock() {
  mkdir -p "$STATE_DIR"
  exec 9>"$LOCK" || return 1
  flock 9
}

holder_count() {
  local n
  n=$(find "$STATE_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
  echo "$n"
}

# ---- commands ---------------------------------------------------------

CMD="${1:-}"
[ -n "$CMD" ] || usage

# status/config only read; on/off/reset/test write to /run and the pin,
# both root-owned once anything has run as root - which is how the TUI,
# zvoneni-ring and the button daemon always call this. Without the check,
# calling one of these by hand without sudo failed on a raw "Permission
# denied" from the lock file, which pointed nowhere useful.
case "$CMD" in
  on|off|reset|test)
    [ "$(id -u)" -eq 0 ] || { echo "zvoneni-amp: run as root, e.g. sudo zvoneni-amp $CMD" >&2; exit 1; }
    ;;
esac

load_config

case "$CMD" in
  on)
    [ $# -ge 2 ] || usage
    [ "$AMP_ENABLED" -eq 1 ] || exit 0
    HOLDER=$(clean_holder "$2")
    take_lock || exit 1
    touch "$STATE_DIR/$HOLDER" || { log "cannot record holder '$HOLDER'"; exit 1; }

    # The pin is switched only on the first claim. In particular, do not
    # replay amp_write for a second holder: the config may have changed in
    # between, and doing so would energise the new GPIO and overwrite the
    # ownership marker while the original GPIO was still on. The marker is
    # the authoritative 0 -> 1 transition because it also covers recovery
    # from a process that died after energising the pin.
    if ! amp_owned; then
      if ! amp_write 1; then
        rm -f "$STATE_DIR/$HOLDER"
        exit 1
      fi
    fi
    ;;

  off)
    [ $# -ge 2 ] || usage
    may_touch_pin || exit 0
    HOLDER=$(clean_holder "$2")
    take_lock || exit 1
    rm -f "$STATE_DIR/$HOLDER"
    if [ "$(holder_count)" -eq 0 ]; then
      amp_write 0
    fi
    ;;

  reset)
    may_touch_pin || exit 0
    take_lock || exit 1
    rm -f "$STATE_DIR"/*
    amp_write 0
    ;;

  test)
    [ "$AMP_ENABLED" -eq 1 ] || { log "amplifier control is disabled"; exit 1; }
    SECS=$(sane "${2:-5}" 5 1 300 "test duration")
    "$0" on manual-test || exit 1
    sleep "$SECS"
    "$0" off manual-test
    ;;

  status)
    echo "enabled:      $AMP_ENABLED"
    echo "gpio:         $AMP_GPIO"
    echo "active high:  $AMP_ACTIVE_HIGH"
    echo "pre-roll:     ${AMP_PRE_SECONDS}s before the bell"
    echo "post-roll:    ${AMP_POST_SECONDS}s after the sound ends"
    echo "amplifier:    $(pin_state)"
    echo "driven by us: $(amp_owned && echo yes || echo no)"
    echo "holders:      $(holder_count)"
    if [ -d "$STATE_DIR" ]; then
      find "$STATE_DIR" -maxdepth 1 -type f -printf '  - %f\n' 2>/dev/null
    fi
    echo
    DAEMON=$(systemctl is-active zvoneni-amp-button.service 2>/dev/null)
    echo "button:       $BUTTON_ENABLED (gpio $BUTTON_GPIO, active low $BUTTON_ACTIVE_LOW)"
    echo "button pin:   $(button_state)"
    echo "button daemon: ${DAEMON:-unknown}"
    ;;

  config)
    echo "AMP_ENABLED=$AMP_ENABLED"
    echo "AMP_GPIO=$AMP_GPIO"
    echo "AMP_ACTIVE_HIGH=$AMP_ACTIVE_HIGH"
    echo "AMP_PRE_SECONDS=$AMP_PRE_SECONDS"
    echo "AMP_POST_SECONDS=$AMP_POST_SECONDS"
    echo "BUTTON_ENABLED=$BUTTON_ENABLED"
    echo "BUTTON_GPIO=$BUTTON_GPIO"
    echo "BUTTON_ACTIVE_LOW=$BUTTON_ACTIVE_LOW"
    ;;

  *)
    usage
    ;;
esac
EOF

chmod +x /usr/local/bin/zvoneni-amp

# ------------------------------------------------------------
# zvoneni-ring - one bell, amplifier included
# ------------------------------------------------------------
cat > /usr/local/bin/zvoneni-ring <<'EOF'
#!/bin/bash
# Play one bell sound, powering the amplifier up before and down after it.
#
# Deliberately no `set -e`: if aplay fails we still want the post-roll and
# the amplifier release to happen.
set -uo pipefail

AMP=/usr/local/bin/zvoneni-amp
TYPE="${1:-}"

if [ -z "$TYPE" ]; then
  echo "usage: zvoneni-ring <sound> [holder]" >&2
  exit 2
fi

SOUND="/opt/zvoneni/sounds/${TYPE}.wav"
# Generated per-slot units pass their own holder (ring-Mon-0800) so two
# overlapping bells of the same sound each hold the amplifier separately;
# the default keeps manual `zvoneni-ring normal` working as before.
HOLDER="${2:-ring-${TYPE}}"

# Single source of truth for defaults and validation lives in zvoneni-amp.
AMP_ENABLED=0
AMP_PRE_SECONDS=0
AMP_POST_SECONDS=0
if [ -x "$AMP" ]; then
  eval "$("$AMP" config 2>/dev/null)" || AMP_ENABLED=0
fi

release() {
  if [ "$AMP_ENABLED" -eq 1 ]; then
    "$AMP" off "$HOLDER" || true
  fi
}

# A signal trap that merely returns would let the script carry on to the
# next command - a bell stopped during the pre-roll would still play, with
# the amplifier already released. Exit from the signal and let the EXIT
# trap do the cleanup.
trap release EXIT
trap 'exit 143' INT TERM

if [ "$AMP_ENABLED" -eq 1 ]; then
  "$AMP" on "$HOLDER" || true
  if [ "$AMP_PRE_SECONDS" -gt 0 ]; then
    sleep "$AMP_PRE_SECONDS"
  fi
fi

/usr/bin/aplay -q "$SOUND"
RC=$?

if [ "$AMP_ENABLED" -eq 1 ] && [ "$AMP_POST_SECONDS" -gt 0 ]; then
  sleep "$AMP_POST_SECONDS"
fi

exit $RC
EOF

chmod +x /usr/local/bin/zvoneni-ring

# ------------------------------------------------------------
# zvoneni-amp-button - hold-to-talk button
# ------------------------------------------------------------
cat > /usr/local/bin/zvoneni-amp-button <<'EOF'
#!/bin/bash
# While the button is held down, the amplifier stays on.
#
# gpiomon is used purely as a wake-up source; the actual level is always
# read back with pinctrl. That way the daemon does not depend on how a
# given libgpiod version spells its event output, and a lost or spurious
# edge cannot leave the amplifier stuck on - every decision is made from
# the pin as it really is.
set -uo pipefail

AMP=/usr/local/bin/zvoneni-amp
HOLDER=button
POLL_INTERVAL=0.05
DEBOUNCE=0.03

log() { echo "zvoneni-amp-button: $*" >&2; }

BUTTON_ENABLED=0
BUTTON_GPIO=27
BUTTON_ACTIVE_LOW=1
eval "$("$AMP" config 2>/dev/null)" || true

if [ "$BUTTON_ENABLED" -ne 1 ]; then
  log "button is disabled in amp.conf, nothing to do"
  exit 0
fi

if ! command -v pinctrl >/dev/null 2>&1; then
  log "pinctrl not found - cannot read GPIO $BUTTON_GPIO (install raspi-utils)"
  exit 1
fi

if [ "$BUTTON_ACTIVE_LOW" -eq 1 ]; then
  PULL=pu
  BIAS=pull-up
else
  PULL=pd
  BIAS=pull-down
fi

if ! pinctrl set "$BUTTON_GPIO" ip "$PULL" 2>/dev/null; then
  log "cannot configure GPIO $BUTTON_GPIO as input"
  exit 1
fi

release() { "$AMP" off "$HOLDER" >/dev/null 2>&1 || true; }
trap release EXIT
trap 'exit 143' INT TERM

# -2 = unknown, so the very first successful read always syncs the
# holder. Starting at 0 meant a daemon restarted after SIGKILL (EXIT trap
# never ran, holder file left behind) saw "released == released" and
# never called off - the stale holder kept the amplifier on forever.
STATE=-2

read_button() {  # 1 = pressed, 0 = released, -1 = unreadable
  local out lvl
  out=$(pinctrl get "$BUTTON_GPIO" 2>/dev/null) || { echo -1; return; }
  lvl=$(echo "$out" | grep -o -E '\b(hi|lo)\b' | head -n1)

  case "$lvl" in
    hi) [ "$BUTTON_ACTIVE_LOW" -eq 1 ] && echo 0 || echo 1 ;;
    lo) [ "$BUTTON_ACTIVE_LOW" -eq 1 ] && echo 1 || echo 0 ;;
    *)  echo -1 ;;
  esac
}

apply() {  # take the pin as the truth and sync the amplifier to it
  local now="$1"
  [ "$now" -lt 0 ] && return
  [ "$now" -eq "$STATE" ] && return

  STATE="$now"
  if [ "$STATE" -eq 1 ]; then
    log "button pressed"
    "$AMP" on "$HOLDER"
  else
    log "button released"
    "$AMP" off "$HOLDER"
  fi
}

# libgpiod v1 and v2 take completely different arguments, and v2 can
# address a line by name, which avoids hardcoding a gpiochip (Pi 5 does
# not number them the same way as Pi 4).
build_gpiomon() {
  command -v gpiomon >/dev/null 2>&1 || return 1

  local ver found
  ver=$(gpiomon --version 2>/dev/null | head -n1)

  # Debian 13's libgpiod prints "gpiomon (libgpiod) v2.2.1" - note the "v"
  # right before the number. A pattern anchored on "<space>2." misses that
  # and falls through to the v1 branch, where gpiofind does not exist under
  # v2 and build_gpiomon fails outright - reported as "gpiomon unavailable"
  # even though it plainly is. Match the version loosely.
  case "$ver" in
    *\ v2.*|*\ 2.*)
      GPIOMON=(gpiomon --edges=both --bias="$BIAS" "GPIO$BUTTON_GPIO")
      ;;
    *)
      found=$(gpiofind "GPIO$BUTTON_GPIO" 2>/dev/null) || return 1
      [ -n "$found" ] || return 1
      # shellcheck disable=SC2206
      GPIOMON=(gpiomon --bias="$BIAS" $found)
      ;;
  esac
}

# a button already held when we start counts as pressed
apply "$(read_button)"

if build_gpiomon; then
  log "watching GPIO$BUTTON_GPIO via: ${GPIOMON[*]}"
  # Fixed path rather than mktemp: the daemon is usually killed while
  # blocked in the loop below, and a fresh temp file per start would pile
  # up in /run under a restart loop. Only ever one daemon runs.
  ERRLOG=/run/zvoneni-amp-button.err

  while read -r _; do
    sleep "$DEBOUNCE"
    apply "$(read_button)"
  done < <("${GPIOMON[@]}" 2>"$ERRLOG")

  log "gpiomon stopped - command was: ${GPIOMON[*]}"
  if [ -s "$ERRLOG" ]; then
    log "gpiomon said: $(head -n 3 "$ERRLOG" | tr '\n' ' ')"
  fi
else
  log "gpiomon unavailable (install the gpiod package)"
fi

# Either gpiomon is missing or it stopped. Polling is less elegant but it
# always works, and the log above says what to fix.
log "falling back to polling GPIO$BUTTON_GPIO every ${POLL_INTERVAL}s"

CAND=-2
COUNT=0
while true; do
  RAW=$(read_button)
  if [ "$RAW" -eq "$CAND" ]; then
    COUNT=$((COUNT + 1))
  else
    CAND="$RAW"
    COUNT=1
  fi

  # two identical samples in a row = debounced
  if [ "$COUNT" -ge 2 ]; then
    apply "$CAND"
  fi

  sleep "$POLL_INTERVAL"
done
EOF

chmod +x /usr/local/bin/zvoneni-amp-button

cat > /etc/systemd/system/zvoneni-amp-button.service <<'EOF'
[Unit]
Description=Amplifier hold-to-talk button
After=zvoneni-amp-reset.service

[Service]
Type=simple
ExecStart=/usr/local/bin/zvoneni-amp-button
# Belt and braces to the daemon's own EXIT trap: covers SIGKILL, where no
# trap runs and the button holder would otherwise be left keeping the
# amplifier on until reboot.
ExecStopPost=/usr/local/bin/zvoneni-amp off button
# A clean exit means the button is switched off in amp.conf, which is not
# a failure and must not be retried in a loop.
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ------------------------------------------------------------
# Boot failsafe
# ------------------------------------------------------------
# If the Pi loses power between amp-on and amp-off the pin stays latched.
# This must run before zvoneni.target, because Persistent=true timers fire
# missed bells immediately after boot.
cat > /etc/systemd/system/zvoneni-amp-reset.service <<'EOF'
[Unit]
Description=Force amplifier GPIO off at boot
Before=zvoneni-generator.service zvoneni.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zvoneni-amp reset

[Install]
WantedBy=multi-user.target
EOF
