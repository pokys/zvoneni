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

  if [ -r "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF" 2>/dev/null || log "cannot read $CONF, using defaults"
  fi

  AMP_ENABLED=$(sane "${AMP_ENABLED:-0}" 0 0 1 AMP_ENABLED)
  AMP_GPIO=$(sane "${AMP_GPIO:-17}" 17 0 27 AMP_GPIO)
  AMP_ACTIVE_HIGH=$(sane "${AMP_ACTIVE_HIGH:-1}" 1 0 1 AMP_ACTIVE_HIGH)
  AMP_PRE_SECONDS=$(sane "${AMP_PRE_SECONDS:-10}" 10 0 300 AMP_PRE_SECONDS)
  AMP_POST_SECONDS=$(sane "${AMP_POST_SECONDS:-2}" 2 0 300 AMP_POST_SECONDS)
}

# ---- GPIO -------------------------------------------------------------

# pinctrl is used rather than libgpiod's gpioset because it latches the
# level: gpioset releases the line when it exits and the pin falls back.
have_pinctrl() { command -v pinctrl >/dev/null 2>&1; }

amp_write() {  # 1 = amplifier on, 0 = amplifier off
  local want="$1" level

  if [ "$AMP_ACTIVE_HIGH" -eq 1 ]; then
    [ "$want" -eq 1 ] && level=dh || level=dl
  else
    [ "$want" -eq 1 ] && level=dl || level=dh
  fi

  if ! have_pinctrl; then
    log "pinctrl not found - cannot drive GPIO $AMP_GPIO (install raspi-utils)"
    return 1
  fi

  if ! pinctrl set "$AMP_GPIO" op "$level" 2>/dev/null; then
    log "pinctrl set $AMP_GPIO op $level failed"
    return 1
  fi
}

pin_state() {
  if ! have_pinctrl; then
    echo "unknown (pinctrl not installed)"
    return
  fi

  local out level
  out=$(pinctrl get "$AMP_GPIO" 2>/dev/null) || { echo "unknown"; return; }
  level=$(echo "$out" | grep -o -E '\b(dh|dl|hi|lo)\b' | head -n1)

  case "$level" in
    dh|hi) [ "$AMP_ACTIVE_HIGH" -eq 1 ] && echo "ON  ($out)" || echo "OFF ($out)" ;;
    dl|lo) [ "$AMP_ACTIVE_HIGH" -eq 1 ] && echo "OFF ($out)" || echo "ON  ($out)" ;;
    *)     echo "unknown ($out)" ;;
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
load_config

case "$CMD" in
  on)
    [ $# -ge 2 ] || usage
    [ "$AMP_ENABLED" -eq 1 ] || exit 0
    HOLDER=$(clean_holder "$2")
    take_lock || exit 1
    touch "$STATE_DIR/$HOLDER"
    amp_write 1
    ;;

  off)
    [ $# -ge 2 ] || usage
    [ "$AMP_ENABLED" -eq 1 ] || exit 0
    HOLDER=$(clean_holder "$2")
    take_lock || exit 1
    rm -f "$STATE_DIR/$HOLDER"
    if [ "$(holder_count)" -eq 0 ]; then
      amp_write 0
    fi
    ;;

  reset)
    [ "$AMP_ENABLED" -eq 1 ] || exit 0
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
    echo "holders:      $(holder_count)"
    if [ -d "$STATE_DIR" ]; then
      find "$STATE_DIR" -maxdepth 1 -type f -printf '  - %f\n' 2>/dev/null
    fi
    ;;

  config)
    echo "AMP_ENABLED=$AMP_ENABLED"
    echo "AMP_GPIO=$AMP_GPIO"
    echo "AMP_ACTIVE_HIGH=$AMP_ACTIVE_HIGH"
    echo "AMP_PRE_SECONDS=$AMP_PRE_SECONDS"
    echo "AMP_POST_SECONDS=$AMP_POST_SECONDS"
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
  echo "usage: zvoneni-ring <sound>" >&2
  exit 2
fi

SOUND="/opt/zvoneni/sounds/${TYPE}.wav"
HOLDER="ring-${TYPE}"

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
