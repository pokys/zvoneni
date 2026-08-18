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
# The stash lives beside the checkout, not in /run: it must survive a
# reboot that interrupts a half-finished update, and staying on the same
# filesystem makes mv an atomic rename instead of a copy.
SOUNDS_BAK="$REPO/.sounds-stash"
# Written before git is touched, removed only after a successful install:
# if the installer fails after the fast-forward, HEAD already matches the
# remote and a plain re-apply would say "up to date" without ever
# finishing the installation.
INCOMPLETE="$REPO/.update-incomplete"

CMD="${1:-}"

# status only reads; everything else mutates root-owned state. The guard
# sits after command parsing so `zvoneni-update status` (and the usage
# text) stay usable without sudo.
case "$CMD" in
  check|apply|rollback)
    if [ "$(id -u)" -ne 0 ]; then
      echo "ERROR: run as root, e.g. sudo zvoneni-update $CMD" >&2
      exit 1
    fi

    # One updater at a time: concurrent runs would overwrite the staged
    # copy mid-read and fight over the stash. The lock fd survives the
    # exec below, so the relaunched copy keeps holding it.
    if [ "${ZVONENI_UPDATE_RELAUNCHED:-0}" != "1" ]; then
      exec 8>/run/zvoneni-update.lock
      flock -n 8 || { echo "ERROR: another zvoneni-update is already running" >&2; exit 1; }
    fi
    ;;
esac

# The installer rewrites /usr/local/bin/zvoneni-update while we are running
# it, and bash reads a script by file offset - it would carry on in the
# middle of the new file. Run from a copy in /run instead.
#
# The copy is handed to bash rather than executed directly: /run is often
# mounted noexec, which blocks execve() no matter what the mode bits say.
# Reading a script is not affected by that. status skips the staging - it
# is read-only, quick, and must work without root (no /run writes).
if [ "${ZVONENI_UPDATE_RELAUNCHED:-0}" != "1" ] && [ "$CMD" != "status" ] && [ -n "$CMD" ]; then
  if ! cp -f "$0" "$SELF" 2>/dev/null; then
    echo "ERROR: cannot stage the updater at $SELF" >&2
    exit 1
  fi
  export ZVONENI_UPDATE_RELAUNCHED=1
  exec bash "$SELF" "$@"
fi

say() { echo "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
# safe.directory inline: a non-root `status` would otherwise trip git's
# dubious-ownership check on the root-owned checkout.
git_repo() { git -c safe.directory="$REPO" -C "$REPO" "$@"; }

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
  local entry status path
  # -z: NUL-delimited and unquoted. The line-based porcelain quotes paths
  # with spaces ("name with spaces.txt" incl. the quotes), so the
  # extracted path matched nothing, the content diff came back empty and
  # a real modification was misread as mode-only. Renames emit a second
  # NUL-terminated field (the origin path) - swallowed below.
  while IFS= read -r -d '' entry; do
    status=${entry:0:2}
    path=${entry:3}

    # rename/copy: consume the origin-path field and treat as a content
    # change outright - it is never a mode-only difference.
    case "$status" in
      *R*|*C*)
        IFS= read -r -d '' _ || true
        printf '%s\n' "$entry"
        continue
        ;;
    esac

    case "$path" in sounds/*) continue ;; esac

    if [ -n "$(git_repo diff HEAD --numstat -- "$path" 2>/dev/null \
               | grep -v '^0[[:space:]]0[[:space:]]')" ]; then
      printf '%s\n' "$entry"
    fi
  done < <(git_repo status --porcelain -z --untracked-files=no)
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
  # --prune: without it a branch deleted upstream keeps its stale
  # remote-tracking ref here, and rev-parse origin/BRANCH would carry on
  # succeeding against a commit that no longer exists upstream.
  git_repo fetch --quiet --prune origin 2>/dev/null || die "cannot reach the remote - is the network up?"
}

# The sound library sits inside the git working tree, and older versions
# tracked it, so a checkout or a merge could refuse to run over a
# customised bell - or quietly replace it. Move the library aside before
# touching git and put it back afterwards. What is on the appliance always
# wins; stock sounds only ever fill in what is missing.
#
# The library is the school's own recordings - the one thing an update
# must never lose. Hence: mv (atomic rename, same filesystem, no
# copy-then-delete window), a stash that survives reboots, recovery of a
# stash left by an interrupted earlier run, and on restore failure the
# stash stays on disk rather than being cleaned up.
stash_sounds() {
  # An existing stash means an earlier run was interrupted between stash
  # and restore. Never discard it - fold it into the live library first,
  # then stash the result. The stash wins name collisions: the live copy may
  # merely be a stock sound seeded by the interrupted installer, while the
  # stash is the school's original customised file.
  if [ -d "$SOUNDS_BAK" ]; then
    say "Recovering sound stash from an interrupted update ..."
    mkdir -p "$REPO/sounds" || die "cannot recreate $REPO/sounds - your sounds are safe in $SOUNDS_BAK"
    local f base
    local -a saved=()
    shopt -s nullglob dotglob
    saved=("$SOUNDS_BAK"/*)
    shopt -u nullglob dotglob
    for f in "${saved[@]}"; do
      base=${f##*/}
      rm -f "$REPO/sounds/$base" || die "cannot replace $REPO/sounds/$base - your original is safe in $SOUNDS_BAK"
      mv "$f" "$REPO/sounds/$base" || die "cannot recover $base from $SOUNDS_BAK"
    done
    rmdir "$SOUNDS_BAK" || die "cannot finish recovery - unexpected files remain in $SOUNDS_BAK"
  fi

  [ -d "$REPO/sounds" ] || return 0

  mv "$REPO/sounds" "$SOUNDS_BAK" || die "cannot stash the sound library (mv to $SOUNDS_BAK failed)"

  # Put back whatever this commit tracks, so git sees an unmodified tree.
  git_repo checkout -- sounds 2>/dev/null || true
}

restore_sounds() {
  [ -d "$SOUNDS_BAK" ] || return 0

  mkdir -p "$REPO/sounds" || return 1

  # Per-file move, appliance copy wins over freshly checked-out stock. Use
  # dotglob as well: a hidden recording is still user data and must not be
  # deleted when the stash directory is cleaned up.
  local f base fail=0
  local -a saved=()
  shopt -s nullglob dotglob
  saved=("$SOUNDS_BAK"/*)
  shopt -u nullglob dotglob
  for f in "${saved[@]}"; do
    base=${f##*/}
    if ! rm -f "$REPO/sounds/$base"; then
      fail=1
      continue
    fi
    mv "$f" "$REPO/sounds/$base" || fail=1
  done

  if [ "$fail" -ne 0 ]; then
    say "WARNING: some sounds could not be restored - they remain in $SOUNDS_BAK"
    return 1
  fi

  rmdir "$SOUNDS_BAK" || {
    say "WARNING: unexpected files remain in $SOUNDS_BAK"
    return 1
  }

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
  if ! bash "$REPO/install/install.sh"; then
    # Do not leave the appliance using newly seeded stock sounds merely
    # because a later installer step failed. Best-effort restoration keeps
    # the original library available while the incomplete marker requests a
    # retry of the software installation.
    restore_sounds || die "the installer failed and some sounds could not be restored.
The system may be half updated. Your remaining sounds are safe in $SOUNDS_BAK
Try 'zvoneni-update apply' again after correcting the error."
    die "the installer failed - the system may be half updated.
Try 'zvoneni-update apply' again, or 'zvoneni-update rollback'.
Your sound library has been restored."
  fi

  restore_sounds || die "some sounds could not be restored.
The update remains marked incomplete and the originals are safe in $SOUNDS_BAK
Correct the error, then run 'zvoneni-update apply' again."
  migrate_config

  # install.sh never runs the generator, so without this the old units stay
  # on disk until the next boot - and their format may have changed.
  say ""
  say "Regenerating timers ..."
  /usr/local/bin/generate-timers.sh || die "generate-timers.sh failed.
The update remains marked incomplete. Check the schedule and systemd, then
run 'zvoneni-update apply' again."

  # Every required step, including sound restoration and timer generation,
  # succeeded. Only now is it safe to report the transaction complete.
  rm -f "$INCOMPLETE"

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
    # An incomplete marker with HEAD already at the remote means a
    # previous apply fast-forwarded and then failed in the installer.
    # Without this, the recommended "run apply again" would report
    # "up to date" and never finish the installation.
    if [ -f "$INCOMPLETE" ]; then
      say ""
      say "A previous update did not finish installing - resuming."
      run_install
      return 0
    fi
    say ""
    say "Already up to date - nothing to do."
    return 0
  fi

  count=$(git_repo rev-list --count "HEAD..origin/$br" 2>/dev/null || echo 0)
  [ "$count" -gt 0 ] || die "the local checkout has diverged from origin/$br - resolve it by hand"

  printf 'PREV_BRANCH=%s\nPREV_COMMIT=%s\n' "$br" "$cur" > "$STAMP"
  printf 'TARGET=%s\n' "$rem" > "$INCOMPLETE"

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
    if [ -f "$INCOMPLETE" ]; then
      say "A previous rollback did not finish installing - resuming."
      run_install
      return 0
    fi
    say "Already running the recorded previous version - nothing to do."
    return 0
  fi

  say "Rolling back to: $(git_repo log -1 --format='%h %ad  %s' --date=short "$pc")"
  printf 'TARGET=%s\n' "$pc" > "$INCOMPLETE"
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

  if [ -f "$INCOMPLETE" ]; then
    echo
    echo "WARNING: the last update/rollback did not finish installing."
    echo "Run 'sudo zvoneni-update apply' to resume."
  fi

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
