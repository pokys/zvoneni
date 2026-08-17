#!/bin/bash
set -e

echo "[install] installing updater"

cat > /usr/local/bin/zvoneni-update <<'EOF'
#!/bin/bash
# Update the appliance from its git remote.
#
# Config files are never overwritten: 02-layout.sh and 04-amp.sh only
# create schedule.txt and amp.conf when they are missing. Settings that a
# new version introduces are appended with their defaults, existing values
# are left alone.
set -uo pipefail

REPO=/opt/zvoneni
CONF="$REPO/amp.conf"
STAMP="$REPO/.update-previous"
SELF=/run/zvoneni-update.running
SOUNDS_BAK=/run/zvoneni-sounds-stash

# Fail here rather than deep inside a git operation half way through.
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run as root, e.g. sudo zvoneni-update ${1:-status}" >&2
  exit 1
fi

# The installer rewrites /usr/local/bin/zvoneni-update while we are running
# it, and bash reads a script by file offset - it would carry on in the
# middle of the new file. Run from a copy in /run instead.
#
# The copy is handed to bash rather than executed directly: /run is often
# mounted noexec, which blocks execve() no matter what the mode bits say.
# Reading a script is not affected by that.
if [ "${ZVONENI_UPDATE_RELAUNCHED:-0}" != "1" ]; then
  if ! cp -f "$0" "$SELF" 2>/dev/null; then
    echo "ERROR: cannot stage the updater at $SELF" >&2
    exit 1
  fi
  export ZVONENI_UPDATE_RELAUNCHED=1
  exec bash "$SELF" "$@"
fi

say() { echo "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
git_repo() { git -C "$REPO" "$@"; }

overlay_active() {
  findmnt -n -o FSTYPE / 2>/dev/null | grep -q overlay
}

preflight() {
  [ "$(id -u)" -eq 0 ] || die "run as root"
  command -v git >/dev/null 2>&1 || die "git is not installed"
  [ -d "$REPO/.git" ] || die "$REPO is not a git checkout - this install cannot update itself"

  # With the overlay on, everything an update writes lives in RAM and is
  # silently reverted by the next reboot. Refusing beats pretending.
  if overlay_active; then
    die "the root filesystem is an overlay, so the update would not survive a reboot.

Turn it off first:
  raspi-config -> Performance Options -> Overlay File System
  reboot, run the update, then turn the overlay back on."
  fi

  if [ -n "$(tracked_changes)" ]; then
    die "$REPO has local changes to tracked files - refusing to update.
Look at them with:  git -C $REPO status
Discard them with: git -C $REPO checkout -- ."
  fi
}

# Tracked files that really differ in content.
#
# Untracked files are expected here: schedule.txt and amp.conf live in this
# directory without being part of the repository. sounds/ is skipped too -
# it is the live sound library, and older versions tracked it, so a school
# that replaced a stock bell would otherwise be locked out of updates.
#
# Mode-only differences are skipped as well. The install instructions say
# to chmod +x the install scripts, and git tracks the executable bit, so
# following them left the checkout permanently dirty and blocked every
# update that touched an install script.
tracked_changes() {
  local line path
  git_repo status --porcelain --untracked-files=no \
    | grep -v '^.. sounds/' \
    | while IFS= read -r line; do
        # porcelain lines are "XY path"; IFS= keeps the leading status
        # column, without it read would strip it and shift the offset
        path=${line:3}
        if [ -n "$(git_repo diff HEAD --numstat -- "$path" 2>/dev/null \
                   | grep -v '^0[[:space:]]0[[:space:]]')" ]; then
          echo "$line"
        fi
      done
}

branch_name() {
  local b
  if b=$(git_repo symbolic-ref --short -q HEAD); then
    echo "$b"
    return
  fi
  # Detached HEAD, e.g. right after a rollback: use the recorded branch.
  b=$(sed -n 's/^PREV_BRANCH=//p' "$STAMP" 2>/dev/null)
  echo "${b:-main}"
}

fetch_remote() {
  say "Fetching from $(git_repo remote get-url origin 2>/dev/null || echo origin) ..."
  git_repo fetch --quiet origin 2>/dev/null || die "cannot reach the remote - is the network up?"
}

# The sound library sits inside the git working tree, and older versions
# tracked it, so a checkout or a merge could refuse to run over a
# customised bell - or quietly replace it. Move the library aside before
# touching git and put it back afterwards. What is on the appliance always
# wins; stock sounds only ever fill in what is missing.
stash_sounds() {
  [ -d "$REPO/sounds" ] || return 0

  rm -rf "$SOUNDS_BAK"
  mkdir -p "$SOUNDS_BAK" || return 0
  cp -a "$REPO/sounds/." "$SOUNDS_BAK/" 2>/dev/null || true
  rm -rf "$REPO/sounds"

  # Put back whatever this commit tracks, so git sees an unmodified tree.
  git_repo checkout -- sounds 2>/dev/null || true
}

restore_sounds() {
  [ -d "$SOUNDS_BAK" ] || return 0

  mkdir -p "$REPO/sounds"
  cp -a "$SOUNDS_BAK/." "$REPO/sounds/" 2>/dev/null || true
  rm -rf "$SOUNDS_BAK"

  say "Sound library kept: $(find "$REPO/sounds" -name '*.wav' 2>/dev/null | wc -l) file(s)."
}

# Add settings introduced by the new version, keeping existing values.
migrate_config() {
  [ -f "$CONF" ] || return 0
  command -v zvoneni-amp >/dev/null 2>&1 || return 0

  local added=0 key value
  while IFS='=' read -r key value; do
    [ -n "$key" ] || continue
    if ! grep -qE "^[[:space:]]*${key}=" "$CONF"; then
      if [ "$added" -eq 0 ]; then
        say ""
        say "This version adds new settings, appending them to amp.conf:"
        printf '\n# added by zvoneni-update\n' >> "$CONF"
        added=1
      fi
      say "  ${key}=${value}"
      printf '%s=%s\n' "$key" "$value" >> "$CONF"
    fi
  done < <(zvoneni-amp config 2>/dev/null)
}

run_install() {
  say ""
  say "Running the installer ..."
  bash "$REPO/install/install.sh" || die "the installer failed - the system may be half updated.
Try 'zvoneni-update apply' again, or 'zvoneni-update rollback'.
Any stashed sounds are in $SOUNDS_BAK"

  restore_sounds
  migrate_config

  # install.sh never runs the generator, so without this the old units stay
  # on disk until the next boot - and their format may have changed.
  say ""
  say "Regenerating timers ..."
  /usr/local/bin/generate-timers.sh || say "WARNING: generate-timers.sh failed - check the schedule"

  say ""
  say "Done. Now running: $(git_repo log -1 --format='%h %s')"
}

cmd_check() {
  preflight
  fetch_remote

  local br cur rem count
  br=$(branch_name)
  cur=$(git_repo rev-parse HEAD)
  rem=$(git_repo rev-parse "origin/$br" 2>/dev/null) || die "the remote has no branch '$br'"

  say ""
  say "Branch:  $br"
  say "Local:   $(git_repo log -1 --format='%h %ad  %s' --date=short HEAD)"
  say "Remote:  $(git_repo log -1 --format='%h %ad  %s' --date=short "origin/$br")"
  say ""

  if [ "$cur" = "$rem" ]; then
    say "Up to date."
    return 0
  fi

  count=$(git_repo rev-list --count "HEAD..origin/$br" 2>/dev/null || echo 0)
  if [ "$count" -eq 0 ]; then
    say "The local checkout is ahead of the remote - nothing to install."
    return 0
  fi

  say "$count new commit(s):"
  say ""
  git_repo log --format='  %h %ad  %s' --date=short "HEAD..origin/$br"
  say ""
  say "Install from the Update menu in zvoneni-tui, or with: zvoneni-update apply"
  return 10
}

cmd_apply() {
  preflight
  fetch_remote

  local br cur rem count
  br=$(branch_name)
  cur=$(git_repo rev-parse HEAD)
  rem=$(git_repo rev-parse "origin/$br" 2>/dev/null) || die "the remote has no branch '$br'"

  if [ "$cur" = "$rem" ]; then
    say ""
    say "Already up to date - nothing to do."
    return 0
  fi

  count=$(git_repo rev-list --count "HEAD..origin/$br" 2>/dev/null || echo 0)
  [ "$count" -gt 0 ] || die "the local checkout has diverged from origin/$br - resolve it by hand"

  printf 'PREV_BRANCH=%s\nPREV_COMMIT=%s\n' "$br" "$cur" > "$STAMP"

  say ""
  say "Updating $br: $(git_repo rev-parse --short HEAD) -> $(git_repo rev-parse --short "origin/$br") ($count commit(s))"

  stash_sounds
  git_repo checkout --quiet -B "$br" "$cur" || die "cannot switch to branch $br"
  git_repo merge --quiet --ff-only "origin/$br" || die "cannot fast-forward to origin/$br"

  run_install
}

cmd_rollback() {
  preflight

  [ -f "$STAMP" ] || die "no previous version recorded - there is nothing to roll back to"

  local pb pc
  pb=$(sed -n 's/^PREV_BRANCH=//p' "$STAMP")
  pc=$(sed -n 's/^PREV_COMMIT=//p' "$STAMP")
  [ -n "$pc" ] || die "the recorded previous version is unreadable"

  git_repo cat-file -e "${pc}^{commit}" 2>/dev/null || die "commit $pc is no longer in the repository"

  if [ "$(git_repo rev-parse HEAD)" = "$pc" ]; then
    say "Already running the recorded previous version - nothing to do."
    return 0
  fi

  say "Rolling back to: $(git_repo log -1 --format='%h %ad  %s' --date=short "$pc")"
  stash_sounds
  git_repo checkout --quiet -B "${pb:-main}" "$pc" || die "cannot check out $pc"

  run_install
}

cmd_status() {
  [ -d "$REPO/.git" ] || { echo "$REPO is not a git checkout"; return 1; }

  echo "Repository:  $REPO"
  echo "Remote:      $(git_repo remote get-url origin 2>/dev/null || echo '-')"
  echo "Branch:      $(branch_name)"
  echo "Installed:   $(git_repo log -1 --format='%h %ad  %s' --date=short)"

  if [ -f "$STAMP" ]; then
    local pc
    pc=$(sed -n 's/^PREV_COMMIT=//p' "$STAMP")
    echo "Previous:    $(git_repo log -1 --format='%h %ad  %s' --date=short "$pc" 2>/dev/null || echo "$pc")"
  else
    echo "Previous:    (none recorded)"
  fi

  if overlay_active; then
    echo
    echo "NOTE: the overlay filesystem is ON, so updates cannot be made permanent."
  fi
}

case "${1:-}" in
  check)    cmd_check ;;
  apply)    cmd_apply ;;
  rollback) cmd_rollback ;;
  status)   cmd_status ;;
  *)
    cat >&2 <<USAGE
usage: zvoneni-update <command>

  check     see whether a newer version is available
  apply     install it (schedule and settings are kept)
  rollback  go back to the version installed before the last update
  status    show the installed version

Normally driven from the Update menu in zvoneni-tui.
USAGE
    exit 2
    ;;
esac
EOF

chmod +x /usr/local/bin/zvoneni-update
