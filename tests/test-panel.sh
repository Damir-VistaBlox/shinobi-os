#!/usr/bin/env bash
# The desktop panel: a drop-down under the status bar that shows the engagement, which LLM the
# agent would use, the approvals waiting for a human, and what the agent's tools last did.
#
# The panel is somewhere to look, not somewhere to decide, and that is what most of this holds:
#
#   * `shinobi panel status --json` (the one report the panel reads) in every state an engagement
#     can be in, including the ones where showing a list of targets would be a lie: a scope file
#     the gate would refuse (writable by others, a link, bad YAML, no file), a window that has
#     ended or never began. It must not write anything, must not put an approval's arguments or a
#     log record's arguments and detail on a screen, and must not follow a link out of the
#     engagement directory to read a "log";
#   * the panel's logic (PanelModel.js), run with node against the real report: a report it
#     cannot read is shown as unavailable and never as an empty, reassuring section;
#   * the wiring: the key, the IPC route `shinobi shellctl toggle-panel` takes into the shell, the
#     files the desktop check requires, and the colours the panel asks for in every theme.
#
# Quickshell itself needs a compositor and is not run here; the layout was looked at on a booted
# image. Needs node for the logic half (skipped, loudly, without it).
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
QS="$ROOT/packaging/shinobi-desktop/usr/share/shinobi-dotfiles/etc/skel/.config/quickshell"
umask 022

failures=0
checks=0
check() {
  checks=$((checks + 1))
  if [[ "$2" == "$3" ]]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$3" "$2"
    failures=$((failures + 1))
  fi
}
section() { printf '\n== %s ==\n' "$1"; }

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
# Everything the commands touch is this test's own. SHINOBI_ENGAGEMENTS_DIR matters most: without
# it `shinobi engagement new` writes into the checkout it runs from.
export HOME="$work/home" XDG_CONFIG_HOME="$work/config" XDG_STATE_HOME="$work/state" XDG_DATA_HOME="$work/data" \
  XDG_RUNTIME_DIR="$work/run" SHINOBI_ENGAGEMENTS_DIR="$work/engagements" SHINOBI_PROVIDERS_DIR="$ROOT/providers" \
  SHINOBI_SYSTEM_CONFIG="$work/etc" SHINOBI_DEFAULTS_DIR="$work/share"
unset SHINOBI_ENGAGEMENT SHINOBI_ENGAGEMENT_DIR SHINOBI_STATE_FILE SHINOBI_AUDIT_FILE
mkdir -p "$HOME" "$XDG_CONFIG_HOME/shinobi" "$XDG_STATE_HOME/shinobi" "$XDG_DATA_HOME" "$SHINOBI_ENGAGEMENTS_DIR" \
  "$SHINOBI_SYSTEM_CONFIG" "$SHINOBI_DEFAULTS_DIR" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
export PATH="$ROOT/bin:$PATH"
export PYTHONPATH="$ROOT/libexec/shinobi${PYTHONPATH:+:$PYTHONPATH}"

state="$XDG_STATE_HOME/shinobi"
eng="$SHINOBI_ENGAGEMENTS_DIR"
# jq_py <expr>: a Python expression over the JSON on stdin, as `d`.
jq_py() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
report() { shinobi-panel status --json; }
today="$(date +%F)"

use() { printf '%s' "$1" >"$state/current-engagement"; }
scope() { # scope <name> <window start> <window end> <targets as a YAML flow list>
  mkdir -p "$eng/$1"
  printf 'window:\n  start: "%s"\n  end: "%s"\ntargets: %s\n' "$2" "$3" "$4" >"$eng/$1/scope.yaml"
  chmod 600 "$eng/$1/scope.yaml"
}
log_record() { # log_record <engagement> <call id> <phase> <tool> <target> <verdict> [ts]
  python3 - "$eng/$1/log.jsonl" "$2" "$3" "$4" "$5" "$6" "${7:-2026-10-21T10:00:00+00:00}" <<'PYEOF'
import json, sys
path, call_id, phase, tool, target, verdict, ts = sys.argv[1:8]
with open(path, "a") as f:
    f.write(json.dumps({"ts": ts, "call_id": call_id, "phase": phase, "tool": tool, "target": target,
                        "args": ["-sV", "SECRET-ARG"], "verdict": verdict, "detail": "SECRET-DETAIL"}) + "\n")
PYEOF
}
approval_file() { # approval_file <id> <state> <seconds until expiry> [created]
  python3 - "$state/approvals" "$1" "$2" "$3" "${4:-2026-10-21T09:00:00+00:00}" <<'PYEOF'
import datetime as dt, json, os, sys
root, ident, st, secs, created = sys.argv[1:6]
os.makedirs(root, mode=0o700, exist_ok=True)
expires = dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=int(secs))
rec = {"approval_id": ident, "capability": "nmap.scan", "arguments": {"target": "SECRET-ARGUMENT"},
       "profile": "operator", "reason": "scan " + ident, "state": st, "live_mode": False,
       "created_at": created, "expires_at": expires.isoformat()}
with open(os.path.join(root, ident + ".json"), "w") as f:
    json.dump(rec, f)
os.chmod(os.path.join(root, ident + ".json"), 0o600)
PYEOF
}

section "no engagement"
check "the report says so, and is one line of JSON" "$(report | wc -l)" "1"
check "state none, nothing listed" "$(report | jq_py '(d["engagement"]["state"], d["engagement"]["name"], d["engagement"]["targets"], d["approvals"]["pending_count"], d["activity"])')" \
  "('none', None, [], 0, [])"
check "the session is an observer until it is told otherwise" "$(report | jq_py 'd["profile"]')" "observer"
check "the text form says how to start one" "$(shinobi-panel status | head -1)" "engagement: none (shinobi engagement use <name>)"

section "an engagement whose scope can be used"
scope acme 2020-01-01 2099-12-31 '["10.0.0.0/24", "example.com", "*.lab.example.com"]'
use acme
check "ready, with its name" "$(report | jq_py '(d["engagement"]["state"], d["engagement"]["name"])')" "('ready', 'acme')"
check "the window is active and says when it ends" "$(report | jq_py '(d["engagement"]["window"]["state"], d["engagement"]["window"]["end"])')" "('active', '2099-12-31')"
check "its targets, in the order the file lists them" "$(report | jq_py 'd["engagement"]["targets"]')" "['10.0.0.0/24', 'example.com', '*.lab.example.com']"
check "and how many there are" "$(report | jq_py 'd["engagement"]["target_count"]')" "3"
scope acme 2020-01-01 2099-12-31 '["a.example","b.example","c.example","d.example","e.example","f.example","g.example","h.example"]'
check "a long target list is cut to what fits, and the count stays honest" \
  "$(report | jq_py '(len(d["engagement"]["targets"]), d["engagement"]["target_count"])')" "(6, 8)"
printf 'window:\n  start: %s\n  end: 2099-12-31\ntargets: [x.example]\n' "2020-01-01" >"$eng/acme/scope.yaml"
check "dates written without quotes (YAML reads them as dates) are still a window" \
  "$(report | jq_py 'd["engagement"]["window"]["state"]')" "active"
scope acme 2020-01-01 2020-02-01 '["x.example"]'
check "a window that has ended is expired, not active" "$(report | jq_py 'd["engagement"]["window"]["state"]')" "expired"
scope acme 2999-01-01 2999-02-01 '["x.example"]'
check "one that has not begun is upcoming" "$(report | jq_py 'd["engagement"]["window"]["state"]')" "upcoming"
scope acme "CHANGE ME" "CHANGE ME" '["x.example"]'
check "the template's placeholder is invalid (the gate refuses it too)" "$(report | jq_py 'd["engagement"]["window"]["state"]')" "invalid"
printf 'targets: [x.example]\n' >"$eng/acme/scope.yaml"
check "no window at all is invalid" "$(report | jq_py 'd["engagement"]["window"]["state"]')" "invalid"
printf 'window: {start: "%s", end: "2099-12-31"}\n' "$today" >"$eng/acme/scope.yaml"
check "no targets is a count of zero, not an error" "$(report | jq_py '(d["engagement"]["state"], d["engagement"]["target_count"])')" "('ready', 0)"
printf 'window: {start: "%s", end: "2099-12-31"}\ntargets: not-a-list\n' "$today" >"$eng/acme/scope.yaml"
check "targets that are not a list are counted as none" "$(report | jq_py 'd["engagement"]["target_count"]')" "0"

section "a scope the gate would refuse is shown as a problem, not as targets"
scope acme 2020-01-01 2099-12-31 '["10.0.0.0/24"]'
chmod 666 "$eng/acme/scope.yaml"
check "a file other users can write" "$(report | jq_py '(d["engagement"]["state"], d["engagement"]["targets"])')" "('problem', [])"
check "in the gate's own words, which say how to fix it" "$(report | jq_py '"writable by group or other" in d["engagement"]["problem"] and "chmod go-w" in d["engagement"]["problem"]')" "True"
chmod 600 "$eng/acme/scope.yaml"
mv "$eng/acme/scope.yaml" "$work/elsewhere.yaml"
ln -s "$work/elsewhere.yaml" "$eng/acme/scope.yaml"
check "a link to another file" "$(report | jq_py 'd["engagement"]["state"]')" "problem"
rm "$eng/acme/scope.yaml"
printf 'window: [unclosed\n' >"$eng/acme/scope.yaml"
chmod 600 "$eng/acme/scope.yaml"
check "YAML that does not parse" "$(report | jq_py 'd["engagement"]["state"]')" "problem"
rm "$eng/acme/scope.yaml"
check "no scope file" "$(report | jq_py '(d["engagement"]["state"], "no scope file" in d["engagement"]["problem"])')" "('problem', True)"
use "../escape"
check "an engagement name that is a path" "$(report | jq_py 'd["engagement"]["state"]')" "problem"
use ghost
check "one that has no directory" "$(report | jq_py '(d["engagement"]["state"], d["engagement"]["name"])')" "('problem', 'ghost')"
check "and what is wrong never lists targets or activity" "$(report | jq_py '(d["engagement"]["targets"], d["activity"])')" "([], [])"
scope acme 2020-01-01 2099-12-31 '["10.0.0.0/24"]'
use acme

section "the session profile"
printf 'operator' >"$state/profile"
check "an operator session says so" "$(report | jq_py 'd["profile"]')" "operator"
printf 'root-of-all-things' >"$state/profile"
check "a profile nobody defined is read as observer, as the gate reads it" "$(report | jq_py 'd["profile"]')" "observer"
rm -f "$state/profile"

section "approvals waiting for a human"
check "none to begin with" "$(report | jq_py 'd["approvals"]')" "{'pending': [], 'pending_count': 0}"
approval_file aaaa1111 pending 600 2026-10-21T09:00:01+00:00
approval_file bbbb2222 pending 600 2026-10-21T09:00:00+00:00
approval_file cccc3333 approved 600
approval_file dddd4444 denied 600
approval_file eeee5555 consumed 600
approval_file ffff6666 pending -60
check "only the pending ones that have not expired, oldest request first" \
  "$(report | jq_py '[a["approval_id"] for a in d["approvals"]["pending"]]')" "['bbbb2222', 'aaaa1111']"
check "and counted" "$(report | jq_py 'd["approvals"]["pending_count"]')" "2"
check "each carries what is being asked for and why" \
  "$(report | jq_py '(d["approvals"]["pending"][0]["capability"], d["approvals"]["pending"][0]["reason"])')" "('nmap.scan', 'scan bbbb2222')"
check "but never the arguments, which are one 'shinobi approval show' away" \
  "$(report | grep -c 'SECRET-ARGUMENT' || true)" "0"
for i in 1 2 3 4 5 6 7; do approval_file "seven000$i" pending 600 "2026-10-21T08:00:0$i+00:00"; done
check "more than fit are cut, and the count stays honest" "$(report | jq_py '(len(d["approvals"]["pending"]), d["approvals"]["pending_count"])')" "(5, 9)"
printf 'not json' >"$state/approvals/broken.json"
check "a record that is not JSON is skipped, not an error" "$(shinobi-panel status --json >/dev/null 2>&1; echo $?)" "0"
rm -rf "$state/approvals"

section "what the agent's tools last did"
check "an engagement with an empty log has nothing yet" "$(report | jq_py 'd["activity"]')" "[]"
: >"$eng/acme/log.jsonl"
log_record acme c1 intent dns_lookup example.com "" 2026-10-21T10:00:01+00:00
log_record acme c1 result dns_lookup example.com allowed 2026-10-21T10:00:02+00:00
log_record acme c2 intent nmap_scan 10.0.0.5 "" 2026-10-21T10:00:03+00:00
log_record acme c2 result nmap_scan 10.0.0.5 refused 2026-10-21T10:00:04+00:00
log_record acme c3 intent whatweb_scan example.com "" 2026-10-21T10:00:05+00:00
check "one row per call, newest first" "$(report | jq_py '[r["tool"] for r in d["activity"]]')" "['whatweb_scan', 'nmap_scan', 'dns_lookup']"
check "a call's result replaces its intent" "$(report | jq_py '[r["verdict"] for r in d["activity"]]')" "['started', 'refused', 'allowed']"
check "a call with an intent and no result is shown as started, not left out" "$(report | jq_py 'd["activity"][0]["verdict"]')" "started"
check "rows carry only the tool, the target, the verdict and the time" "$(report | jq_py 'sorted(d["activity"][0].keys())')" "['target', 'time', 'tool', 'verdict']"
check "never the arguments or the detail text" "$(report | grep -cE 'SECRET-ARG|SECRET-DETAIL' || true)" "0"
printf 'this line is not json\n{"no":"tool"}\n[1,2]\n' >>"$eng/acme/log.jsonl"
check "lines that are not records are skipped" "$(report | jq_py 'len(d["activity"])')" "3"
python3 - "$eng/acme/log.jsonl" <<'PYEOF'
import json, sys
with open(sys.argv[1], "a") as f:
    for i in range(20):
        f.write(json.dumps({"ts": "2026-10-21T11:00:%02d+00:00" % i, "call_id": "n%d" % i, "phase": "result", "tool": "http_headers", "target": "t%d.example" % i, "verdict": "allowed"}) + "\n")
PYEOF
check "at most eight rows, the newest" "$(report | jq_py '(len(d["activity"]), d["activity"][0]["target"])')" "(8, 't19.example')"
log_record acme esc result "tool$(printf '\033[31m')x" "$(printf 'a%.0s' {1..300})" allowed
check "control characters and very long values cannot reach the screen" \
  "$(report | jq_py '(d["activity"][0]["tool"], len(d["activity"][0]["target"]) <= 80)')" "('tool [31mx', True)"
# A log of several megabytes is read from its end, not whole.
python3 - "$eng/acme/log.jsonl" <<'PYEOF'
import json, sys
with open(sys.argv[1], "a") as f:
    for i in range(30000):
        f.write(json.dumps({"ts": "2026-10-21T12:00:00+00:00", "call_id": "big%d" % i, "phase": "result", "tool": "whatweb_scan", "target": "big.example", "verdict": "allowed", "detail": "x" * 60}) + "\n")
    f.write(json.dumps({"ts": "2026-10-21T13:00:00+00:00", "call_id": "last", "phase": "result", "tool": "nmap_scan", "target": "last.example", "verdict": "refused"}) + "\n")
PYEOF
started="$(date +%s)"
check "a log of several megabytes still ends with its newest record" "$(report | jq_py 'd["activity"][0]["target"]')" "last.example"
check "and is answered in a moment, not after reading all of it" "$(((($(date +%s) - started) < 5)) && echo yes || echo no)" "yes"
mv "$eng/acme/log.jsonl" "$work/real-log.jsonl"
ln -s "$work/real-log.jsonl" "$eng/acme/log.jsonl"
check "a log that is a link is not followed" "$(report | jq_py 'd["activity"]')" "[]"
rm "$eng/acme/log.jsonl"

section "it only reads"
snapshot() { (cd "$work" && find home config state data engagements -type f -printf '%p %s %T@\n' | sort | md5sum); }
log_record acme r1 result dns_lookup example.com allowed
approval_file readonly1 pending 600
before="$(snapshot)"
report >/dev/null
shinobi-panel status >/dev/null
after="$(snapshot)"
check "two runs changed no file and created none" "$([[ $before == "$after" ]] && echo unchanged || echo changed)" "unchanged"
check "no audit record is written for looking" "$([[ -e $state/audit.jsonl ]] && echo written || echo none)" "none"
check "an approval is still pending afterwards (looking never consumes one)" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$state/approvals/readonly1.json")" "pending"
rm -rf "$state/approvals"

section "the command"
check "help exits 0" "$(shinobi-panel help >/dev/null 2>&1; echo $?)" "0"
check "an unknown action is refused" "$(shinobi-panel nonsense >/dev/null 2>&1; echo $?)" "2"
check "the dispatcher routes 'shinobi panel' to it" "$("$ROOT/bin/shinobi" panel help 2>&1 | head -1)" "Usage: shinobi panel status [--json]"

section "the wiring"
shell="$QS/shell.qml"
panel_qml="$QS/Panel.qml"
check "the panel's helper files are plain JavaScript that QML loads as libraries" \
  "$(head -n 1 "$QS/PanelModel.js")" ".pragma library"
check "shell.qml imports the model" "$(grep -c '^import "PanelModel.js" as PanelModel$' "$shell" || true)" "1"
check "and builds the panel from the status report and the provider rows" \
  "$(grep -c 'PanelModel.build(root.panelStatusText, ProviderStatus.rows(root.readinessText), Date.now())' "$shell" || true)" "1"
check "it asks for the status report, not for a guess" "$(grep -c 'shinobi panel status --json' "$shell" || true)" "1"
check "the probe's last byte is a newline, so the line parser hands it over (and an empty one means no answer)" \
  "$(sh -c "$(python3 - "$shell" <<'PYEOF'
import json, re, sys
text = open(sys.argv[1]).read()
block = text[text.index("id: panelProbe"):]
print(json.loads(re.search(r'command:\s*(\[[^\]]*\])', block).group(1))[2].replace("shinobi panel status --json", "printf '{}'"))
PYEOF
)" | tail -c 1 | od -An -c | tr -d ' \n')" '\n'
check "a failed probe is shown as unavailable (the exit handler), not left as the last answer" \
  "$(grep -c 'onExited:.*root.panelAnswered.*updatePanel("")' "$shell" || true)" "1"
check "the shell answers the IPC route the key uses" "$(grep -c 'target: "panel"' "$shell" || true)" "1"
for fn in toggle open close; do
  check "and has $fn" "$(grep -c "function $fn(): void" "$shell" || true)" "1"
done
check "the panel is shown only while open" "$(grep -c 'visible: root.panelOpen' "$shell" || true)" "1"
check "and refreshed only while open (a closed panel costs nothing)" "$(grep -c 'running: root.panelOpen' "$shell" || true)" "1"
check "the SHINOBI pill and the engagement pill open it" "$(grep -c 'onActivated: root.setPanel(!root.panelOpen)' "$shell" || true)" "2"
check "Panel.qml floats over windows instead of reflowing them" "$(grep -c 'exclusionMode: ExclusionMode.Ignore' "$panel_qml" || true)" "1"
check "takes the keyboard only when clicked" "$(grep -c 'keyboardFocus: WlrKeyboardFocus.OnDemand' "$panel_qml" || true)" "1"
check "and closes on Escape" "$(grep -c 'sequence: "Escape"' "$panel_qml" || true)" "1"
check "its colours are a property called colors (a property named after the id it is bound to binds to itself)" \
  "$(grep -c 'colors: theme' "$shell" || true)" "1"

section "the key and the route to the shell"
hypr="$ROOT/packaging/shinobi-desktop/usr/share/shinobi-dotfiles/etc/skel/.config/hypr/hyprland.conf"
check "SUPER+A toggles the panel" "$(grep -c '^bind = SUPER, A, exec, shinobi-shellctl toggle-panel$' "$hypr" || true)" "1"
check "and nothing else is on SUPER+A" "$(grep -cE '^bind[a-z]* *= *SUPER, *A,' "$hypr" || true)" "1"
mkdir -p "$work/fakebin"
cat >"$work/fakebin/quickshell" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$FAKE_QS_LOG"
EOF
chmod +x "$work/fakebin/quickshell"
for action in toggle open close; do
  FAKE_QS_LOG="$work/qs.log" PATH="$work/fakebin:$PATH" "$ROOT/bin/shinobi-shellctl" "$action-panel"
  check "shellctl ${action}-panel calls the shell's IPC with exactly that function" \
    "$(cat "$work/qs.log")" "ipc --path $XDG_CONFIG_HOME/quickshell call panel $action"
done
check "and says so, rather than doing nothing, when there is no Quickshell" \
  "$(PATH="/usr/bin-none:/bin-none" /bin/bash "$ROOT/bin/shinobi-shellctl" toggle-panel 2>&1 | head -1)" "shinobi-shellctl: quickshell is not installed"

section "the files the desktop needs, and the colours it asks for"
for needed in Panel.qml PanelModel.js; do
  check "the desktop check requires $needed" "$(grep -c "\.config/quickshell/$needed" "$ROOT/packaging/shinobi-desktop/usr/lib/shinobi/shinobi-desktop-check" || true)" "1"
done
used="$( { grep -oE 'theme\.[A-Za-z]+' "$shell"; grep -oE 'panel\.colors\.[A-Za-z]+' "$panel_qml"; } | sed -E 's/^(panel\.colors|theme)\.//' | sort -u)"
check "the panel uses colours (the check below would pass on an empty list)" "$([[ -n $used ]] && echo yes || echo no)" "yes"
for theme_file in "$QS/Theme.qml" "$ROOT"/themes/*/quickshell.qml; do
  missing=""
  for token in $used; do
    grep -qE "^[[:space:]]*readonly property color $token:" "$theme_file" || missing+="$token "
  done
  check "${theme_file#"$ROOT"/} defines all of them" "${missing:-none}" "none"
done

# --- the panel's logic ---------------------------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo
  echo "  skip: node is not installed, so the panel's logic was not run."
  echo "        The report, the wiring and the colour checks above ran; the report-to-rows checks did not."
  printf '\n%d/%d checks passed\n' "$((checks - failures))" "$checks"
  ((failures == 0)) && echo "panel-test: PASS (logic skipped)" && exit 0
  echo "panel-test: FAIL"
  exit 1
fi

section "what the panel makes of the real reports"
model() { node "$ROOT/tests/panel-model-summary.js" "$QS/PanelModel.js" "$QS/ProviderStatus.js" "$1" "$2" "$3"; }
# One clock for the fixtures and for the panel: the approval and the log records are built
# relative to it, and the model is told it is that moment, so "4m left" and "30s ago" are exact.
now_s="$(date +%s)"
now_ms="${now_s}000"
iso_at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S+00:00; }
printf 'ollama' >"$XDG_CONFIG_HOME/shinobi/default-provider"
use acme
scope acme 2020-01-01 2099-12-31 '["10.0.0.0/24", "example.com"]'
: >"$eng/acme/log.jsonl"
# A log is appended to, so the older call is written first.
log_record acme p2 intent nmap_scan 10.0.0.5 "" "$(iso_at $((now_s - 540)))"
log_record acme p2 result nmap_scan 10.0.0.5 refused "$(iso_at $((now_s - 480)))"
log_record acme p1 intent dns_lookup example.com "" "$(iso_at $((now_s - 31)))"
log_record acme p1 result dns_lookup example.com allowed "$(iso_at $((now_s - 30)))"
python3 - "$state/approvals" "$now_ms" <<'PYEOF'
import datetime as dt, json, os, sys
root, now_ms = sys.argv[1], int(sys.argv[2])
os.makedirs(root, mode=0o700, exist_ok=True)
expires = dt.datetime.fromtimestamp(now_ms / 1000 + 4 * 60 + 30, dt.timezone.utc)
rec = {"approval_id": "abcdef0123456789", "capability": "nmap.scan", "arguments": {}, "profile": "operator",
       "reason": "scan 10.0.0.5", "state": "pending", "live_mode": False,
       "created_at": "2026-10-21T10:05:00+00:00", "expires_at": expires.isoformat()}
json.dump(rec, open(os.path.join(root, "abcdef0123456789.json"), "w"))
PYEOF
report >"$work/status.json"
shinobi-provider readiness --json >"$work/readiness.json"
panel_view() { model "$work/status.json" "$work/readiness.json" "$now_ms"; }
check "four sections, in the order an operator reads them" "$(panel_view | jq_py '[s["title"] for s in d["sections"]]')" "['ENGAGEMENT', 'LLM', 'APPROVALS', 'ACTIVITY']"
check "the engagement section names it, the window and the targets" \
  "$(panel_view | jq_py '[(r["left"], r["right"]) for r in d["sections"][0]["rows"]][:3]')" \
  "[('acme', 'profile observer'), ('window', 'active · ends 2099-12-31'), ('targets', '2')]"
check "the LLM section puts the default first, with where it runs and whether it can be used" \
  "$(panel_view | jq_py '(d["sections"][1]["rows"][0]["left"], d["sections"][1]["rows"][0]["right"])')" "('● ollama', 'local · ready')"
check "every installed provider is a row" "$(panel_view | jq_py 'len(d["sections"][1]["rows"])')" "$(ls "$ROOT"/providers/*.toml | wc -l)"
check "a click on the LLM section opens the provider menu, and nothing else is clickable" \
  "$(panel_view | jq_py '[(s["title"], s["command"]) for s in d["sections"] if s["command"]]')" "[('LLM', 'shinobi-menu provider')]"
check "an approval shows what it is for, how long is left, and the id to act on" \
  "$(panel_view | jq_py '[(r["left"], r["right"]) for r in d["sections"][2]["rows"]][:2]')" \
  "[('nmap.scan', '4m left'), ('  scan 10.0.0.5 (abcdef01)', '')]"
check "activity is newest first, with how long ago" \
  "$(panel_view | jq_py '[(r["left"], r["right"]) for r in d["sections"][3]["rows"]]')" \
  "[('dns_lookup example.com', 'allowed · 30s ago'), ('nmap_scan 10.0.0.5', 'refused · 8m ago')]"
check "allowed is good, refused is a warning" "$(panel_view | jq_py '[r["tone"] for r in d["sections"][3]["rows"]]')" "['good', 'warn']"
check "the window's colour follows its state" "$(panel_view | jq_py 'd["sections"][0]["rows"][1]["tone"]')" "good"

scope acme 2020-01-01 2020-02-01 '["x.example"]'
report >"$work/status.json"
check "an expired window is a warning, in words" "$(panel_view | jq_py '(d["sections"][0]["rows"][1]["right"], d["sections"][0]["rows"][1]["tone"])')" "('expired 2020-02-01', 'warn')"
chmod 666 "$eng/acme/scope.yaml"
report >"$work/status.json"
check "a scope the gate would refuse: the name, the problem and no targets" \
  "$(panel_view | jq_py '(d["sections"][0]["rows"][0]["right"], d["sections"][0]["rows"][0]["tone"], len(d["sections"][0]["rows"]))')" "('cannot be used', 'warn', 2)"
chmod 600 "$eng/acme/scope.yaml"
rm -f "$XDG_STATE_HOME/shinobi/current-engagement"
report >"$work/status.json"
check "no engagement: says how to start one" "$(panel_view | jq_py '[r["left"] for r in d["sections"][0]["rows"]]')" "['none active', 'shinobi engagement use <name>']"
rm -rf "$state/approvals"
report >"$work/status.json"
check "no approvals waiting is said, not left blank" "$(panel_view | jq_py 'd["sections"][2]["rows"][0]["left"]')" "none waiting"

section "what it makes of reports it cannot read"
printf '' >"$work/empty"
printf 'not json' >"$work/garbage"
printf '{"version":2,"engagement":{},"approvals":{},"activity":[]}' >"$work/other-version"
printf '{"version":1,"engagement":{},"approvals":{}}' >"$work/no-activity"
for what in empty garbage other-version no-activity; do
  check "a status report that is $what: unavailable, and no section that would look reassuring" \
    "$(model "$work/$what" "$work/readiness.json" "$now_ms" | jq_py '([s["title"] for s in d["sections"]], d["sections"][0]["rows"][0]["tone"])')" "(['ENGAGEMENT', 'LLM'], 'warn')"
done
check "a provider report that cannot be read is unavailable too, not an empty list" \
  "$(model "$work/status.json" "$work/garbage" "$now_ms" | jq_py '(d["sections"][1]["rows"][0]["left"], d["sections"][1]["rows"][0]["tone"])')" "('provider report unavailable', 'warn')"
printf '{"default":{"id":null},"providers":[]}' >"$work/no-providers"
check "a readable report with no providers says so" \
  "$(model "$work/status.json" "$work/no-providers" "$now_ms" | jq_py 'd["sections"][1]["rows"][0]["left"]')" "no providers installed"

printf '\n'
if ((failures > 0)); then
  printf 'panel-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\npanel-test: PASS\n' "$checks" "$checks"
