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

shinobi_config_home() {
  echo "${XDG_CONFIG_HOME:-$HOME/.config}/shinobi"
}

shinobi_state_home() {
  echo "${XDG_STATE_HOME:-$HOME/.local/state}/shinobi"
}

shinobi_runtime_home() {
  echo "${XDG_RUNTIME_DIR:-/tmp}/shinobi"
}

shinobi_system_config_home() {
  echo "${SHINOBI_SYSTEM_CONFIG:-/etc/shinobi}"
}

shinobi_defaults_home() {
  echo "${SHINOBI_DEFAULTS_DIR:-/usr/share/shinobi/default}"
}

shinobi_is_live() {
  [[ -f /run/live/medium/live/filesystem.squashfs || -f /run/live/medium/live/filesystem.squashfs ]] \
    || [[ "${SHINOBI_LIVE_MODE:-}" == "1" ]]
}

shinobi_require_installed() {
  if shinobi_is_live; then
    echo "shinobi: this command is unavailable in the live preview; install Shinobi OS first" >&2
    return 78
  fi
}

shinobi_lock() {
  local name="${1:?lock name required}"
  local lock_dir="$(shinobi_runtime_home)/locks"
  mkdir -p "$lock_dir"
  exec 9>"$lock_dir/$name.lock"
  flock -n 9 || {
    echo "shinobi: another $name operation is already running" >&2
    return 75
  }
}

shinobi_emit_event() {
  local event="${1:?event name required}"
  local payload="${2:-{}}"
  command -v shinobi-event >/dev/null 2>&1 || return 0
  shinobi-event publish "$event" "$payload" >/dev/null 2>&1 || true
}

shinobi_transaction_dir() {
  echo "${XDG_STATE_HOME:-$HOME/.local/state}/shinobi/transactions"
}

shinobi_transaction_start() {
  local kind="${1:?transaction kind required}" detail="${2:-}"
  local id="$(date +%Y%m%d-%H%M%S)-$$"
  local dir
  dir="$(shinobi_transaction_dir)"
  mkdir -p "$dir"
  printf '{"id":"%s","kind":"%s","state":"running","started_at":"%s","detail":"%s"}\n' \
    "$id" "$kind" "$(date --iso-8601=seconds)" "$detail" >"$dir/$id.json"
  echo "$id"
}

shinobi_transaction_finish() {
  local id="${1:?transaction id required}" state="${2:?transaction state required}" detail="${3:-}"
  local path="$(shinobi_transaction_dir)/$id.json"
  [[ -f "$path" ]] || return 0
  printf '{"id":"%s","state":"%s","finished_at":"%s","detail":"%s"}\n' \
    "$id" "$state" "$(date --iso-8601=seconds)" "$detail" >"$path"
}
