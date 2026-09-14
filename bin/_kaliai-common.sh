# Shared helpers for kaliai's leaf commands (agent, engagement, scope,
# capture) — the engagement-state paths they all need. Not itself a
# kaliai-* executable: the leading underscore keeps it out of every
# `bin/kaliai*` glob (install.sh, the ISO hook, and kaliai's own
# command-discovery loop all use that glob), and it's never chmod +x'd,
# since it's sourced, not run.
#
# ${BASH_SOURCE[-1]} (bash's "outermost caller" index, stable through any
# depth of sourcing) is used instead of a plain dirname of $0 — a script
# reached via `ln -sf` onto $PATH, which is how install.sh and the ISO both
# install every kaliai-* command, sees its own path as the symlink's path,
# not its target, so BASH_SOURCE needs readlink -f before dirname'ing it.

kaliai_self_dir() {
  dirname -- "$(readlink -f -- "${BASH_SOURCE[-1]}")"
}

# Local-dev convenience: a script still living inside its git checkout (its
# own directory has an `../engagements` sibling — true when install.sh
# symlinks straight into the checkout, or when running bin/kaliai-* directly
# uninstalled) defaults there. Anywhere else (the built ISO, which copies
# kaliai into /opt/kaliai without engagements/) falls back to a per-user
# XDG data directory instead.
kaliai_engagements_dir() {
  if [[ -n "${KALIAI_ENGAGEMENTS_DIR:-}" ]]; then
    echo "$KALIAI_ENGAGEMENTS_DIR"
    return
  fi
  local sibling
  sibling="$(kaliai_self_dir)/../engagements"
  if [[ -d "$sibling" ]]; then
    (cd -- "$sibling" && pwd)
  else
    echo "${XDG_DATA_HOME:-$HOME/.local/share}/kaliai/engagements"
  fi
}

kaliai_state_file() {
  echo "${KALIAI_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/kaliai/current-engagement}"
}

kaliai_current_engagement() {
  local f
  f="$(kaliai_state_file)"
  [[ -f "$f" ]] && cat "$f" || true
}
