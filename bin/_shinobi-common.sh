# Shared helpers for shinobi's leaf commands (agent, engagement, scope,
# capture) — the engagement-state paths they all need. Not itself a
# shinobi-* executable: the leading underscore keeps it out of every
# `bin/shinobi*` glob (install.sh, the ISO hook, and shinobi's own
# command-discovery loop all use that glob), and it's never chmod +x'd,
# since it's sourced, not run.
#
# ${BASH_SOURCE[-1]} (bash's "outermost caller" index, stable through any
# depth of sourcing) is used instead of a plain dirname of $0 — a script
# reached via `ln -sf` onto $PATH, which is how install.sh and the ISO both
# install every shinobi-* command, sees its own path as the symlink's path,
# not its target, so BASH_SOURCE needs readlink -f before dirname'ing it.

shinobi_self_dir() {
  dirname -- "$(readlink -f -- "${BASH_SOURCE[-1]}")"
}

# Local-dev convenience: a script still living inside its git checkout (its
# own directory has an `../engagements` sibling — true when install.sh
# symlinks straight into the checkout, or when running bin/shinobi-* directly
# uninstalled) defaults there. Anywhere else (the built ISO, which copies
# shinobi into /opt/shinobi without engagements/) falls back to a per-user
# XDG data directory instead.
shinobi_engagements_dir() {
  if [[ -n "${SHINOBI_ENGAGEMENTS_DIR:-}" ]]; then
    echo "$SHINOBI_ENGAGEMENTS_DIR"
    return
  fi
  local sibling
  sibling="$(shinobi_self_dir)/../engagements"
  if [[ -d "$sibling" ]]; then
    (cd -- "$sibling" && pwd)
  else
    echo "${XDG_DATA_HOME:-$HOME/.local/share}/shinobi/engagements"
  fi
}

shinobi_state_file() {
  echo "${SHINOBI_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/shinobi/current-engagement}"
}

shinobi_current_engagement() {
  local f
  f="$(shinobi_state_file)"
  [[ -f "$f" ]] && cat "$f" || true
}
