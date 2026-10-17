#!/usr/bin/env bash
# Tests that no command in bin/ lets the directory it is run from decide what code
# it runs.
#
# `python3 -m module`, `python3 -c code` and `python3 - <<script` all put the
# current directory first on sys.path, ahead of PYTHONPATH and the standard
# library. Only `python3 file` puts the file's own directory there. These wrappers
# are run by an operator who routinely stands in directories they did not write (a
# cloned repository, something extracted from a target), and they run before any
# prompt, in the process that holds approvals and stored keys: a `json.py` in the
# current directory would be imported there, as the operator.
#
# `python3 -P` (3.11+) switches that off and still honours PYTHONPATH. This test
# checks it two ways: statically, that no bin/ script takes its code from -m, -c or
# stdin without it, so a new wrapper written in the old style fails here; and by
# behaviour, by running the read-only ones from a directory full of planted
# lookalikes of standard modules and checking that none was imported. A control
# that runs Python without -P in the same directory proves the plants work, so a
# clean result means something.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'; then
  echo "wrapper-cwd-test: SKIP (python3 -P needs Python 3.11 or newer)"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

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

export HOME="$work/home" XDG_CONFIG_HOME="$work/config" XDG_STATE_HOME="$work/state" \
  XDG_DATA_HOME="$work/data" XDG_RUNTIME_DIR="$work/run" SHINOBI_ENGAGEMENTS_DIR="$work/engagements" \
  LC_ALL=C
unset SHINOBI_ENGAGEMENT SHINOBI_ENGAGEMENT_DIR SHINOBI_AUDIT_FILE SHINOBI_STATE_FILE
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME/shinobi" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR" \
  "$SHINOBI_ENGAGEMENTS_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

echo "== no bin/ script takes its Python code from the current directory =="
problems="$(python3 - bin/* <<'PYEOF'
import re, shlex, sys
bad = []
for path in sys.argv[1:]:
    try:
        text = open(path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        continue
    for number, line in enumerate(text.splitlines(), 1):
        code = line.split("#", 1)[0] if not line.lstrip().startswith("#") else ""
        for match in re.finditer(r"(?<![\w./-])python3(?=\s)", code):
            tail = code[match.end():]
            try:
                tokens = shlex.split(tail, comments=False, posix=True)
            except ValueError:
                tokens = tail.split()
            flags = []
            for token in tokens:
                if token.startswith("-") and not token.startswith("--"):
                    flags.append(token)
                else:
                    break
            # A short option is "-" followed by letters; a lone "-" means "read the
            # program from stdin", which is a source of code like -m and -c.
            def letters(flag):
                return set(flag[1:]) if flag != "-" else set()
            reads_cwd = any(f == "-" or letters(f) & set("mc") for f in flags)
            safe = any(letters(f) & set("PI") for f in flags)
            if reads_cwd and not safe:
                bad.append(f"{path}:{number}: {code.strip()}")
print("\n".join(bad) if bad else "none")
PYEOF
)"
check "every python3 -m, -c or stdin invocation in bin/ has -P" "$problems" "none"

echo "== a planted lookalike is not imported =="
# Lookalikes of standard modules that the commands import and Python's own startup
# does not. Each one records that it was imported, then fails the import.
evil="$work/evil"
marks="$work/marks"
mkdir -p "$evil" "$marks"
for module in json shutil subprocess tempfile argparse pathlib datetime hashlib secrets textwrap \
  dataclasses socket uuid fnmatch shlex; do
  cat >"$evil/$module.py" <<'EOF'
import os as _os
open(_os.path.join(_os.environ["MARK_DIR"], __name__), "w").close()
raise ImportError("planted by the test")
EOF
done
export MARK_DIR="$marks"
export PYTHONPATH="$ROOT/libexec/shinobi"

# Control: the same directory, Python without -P. If this imports nothing, the plants
# are not working and every clean result below would be meaningless.
(cd "$evil" && python3 -c 'import json' >/dev/null 2>&1) || true
# (Python's own startup may import another of the lookalikes too, so this checks that
# json is among them rather than that it is the only one.)
check "control: plain python3 -c in that directory imports the planted json" "$([[ -e $marks/json ]] && echo imported || echo clean)" "imported"
rm -f "$marks"/*
(cd "$evil" && python3 -P -c 'import json; print(json.dumps(1))' >/dev/null 2>&1)
check "control: python3 -P in the same directory does not" "$(ls "$marks" | wc -l)" "0"

# The read-only action of each command that runs Python.
run_from_evil() {
  # run_from_evil <command> <args...>: stdout+stderr in $out, status in $rc.
  rc=0
  out="$(cd "$evil" && timeout 120 "$ROOT/bin/$1" "${@:2}" 2>&1)" || rc=$?
}
for spec in "shinobi-provider list" "shinobi-mcp support claude" "shinobi-plugin list" "shinobi-webapp list" \
  "shinobi-evidence list" "shinobi-approval list" "shinobi-egress show" "shinobi-event recent" "shinobi-doctor"; do
  # shellcheck disable=SC2086
  set -- $spec
  rm -f "$marks"/*
  run_from_evil "$@"
  check "$spec: nothing planted was imported" "$(ls "$marks" | tr '\n' ' ')|$(grep -c 'planted by the test' <<<"$out" || true)" "|0"
  check "$spec: it ran and was not stopped at the door (status is not 126 or 127)" "$([[ $rc -ne 126 && $rc -ne 127 ]] && echo yes || echo no)" "yes"
done

echo "== the wrappers still honour PYTHONPATH =="
run_from_evil shinobi-provider list
check "shinobi-provider still finds its module and lists the shipped providers" \
  "$rc|$(grep -cE '^[ !]openai +' <<<"$out" || true)|$(grep -cE '^[ !]ollama +' <<<"$out" || true)" "0|1|1"

echo
if [[ $failures -eq 0 ]]; then
  echo "wrapper-cwd-test: PASS ($checks checks)"
else
  echo "wrapper-cwd-test: FAIL ($failures of $checks checks)"
  exit 1
fi
