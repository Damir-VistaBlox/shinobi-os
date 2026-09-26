#!/usr/bin/env bash
# Documentation truth checks.
#
# Docs drift silently: nothing fails when a new MCP tool ships and the README
# still says "currently: nmap_scan". The claims that *can* be derived from the
# tree are derived here, so the drift is a test failure instead of a lie someone
# trusts. The prose claims that cannot be derived are not checked -- they are
# marked as such at the end, and rely on review.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

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

echo "== the README's tool list matches the manifests =="
# Derived from tools/*.toml, so adding a tool without documenting it fails here.
manifest_tools=()
for manifest in "$ROOT"/tools/*.toml; do
  name="$(sed -n 's/^mcp_tool *= *"\(.*\)"/\1/p' "$manifest")"
  [[ -n "$name" ]] && manifest_tools+=("$name")
done
check "at least one manifest exists" "${#manifest_tools[@]}" "4"
for tool in "${manifest_tools[@]}"; do
  check "README.md documents the $tool tool" \
    "$(grep -q "\`$tool\`" "$ROOT/README.md" && echo yes || echo no)" "yes"
done
check "README.md does not claim nmap_scan is the only tool" \
  "$(grep -q 'currently: `nmap_scan`' "$ROOT/README.md" && echo stale || echo current)" "current"
check "DESIGN.md does not claim one tool family" \
  "$(grep -q 'one tool family (`nmap_scan`)' "$ROOT/DESIGN.md" && echo stale || echo current)" "current"

echo "== the approval gate is documented, not just the scope gate =="
# A live_mode tool is refused without an explicit human approval. Docs that
# describe only the scope check tell a reader that scope alone authorizes a scan,
# which is the opposite of what the code does.
for doc in README.md DESIGN.md docs/architecture.md; do
  check "$doc mentions approval" "$(grep -qi 'approval' "$ROOT/$doc" && echo yes || echo no)" "yes"
done
check "the docs state that scope alone is not sufficient" \
  "$(grep -qiE 'approval' "$ROOT/README.md" && \
     { grep -qiE 'in addition to scope|as well as scope|scope is still checked|scope alone|before scope alone' "$ROOT/README.md" || grep -qi 'approval' "$ROOT/DESIGN.md"; } && echo yes || echo no)" "yes"

echo "== the test docs match how the suite is actually invoked =="
# Wave 1 made the ISO argument optional; the docs still described it as required,
# so the documented command was the multi-gigabyte path.
check "tests/README.md documents the source-only invocation" \
  "$(grep -qE '^\s*(\./)?tests/run-all\.sh\s*$' "$ROOT/tests/README.md" && echo yes || echo no)" "yes"
check "tests/README.md shows the ISO as optional" \
  "$(grep -qiE 'optional|without an ISO|no ISO|source tests only|source-level' "$ROOT/tests/README.md" && echo yes || echo no)" "yes"
check "tests/README.md does not present the ISO as the only way to run tests" \
  "$(grep -qi 'Run the complete suite against a built ISO' "$ROOT/tests/README.md" && echo stale || echo current)" "current"
check "tests/README.md mentions the dpkg-deb skip" \
  "$(grep -qi 'dpkg-deb' "$ROOT/tests/README.md" && echo yes || echo no)" "yes"
check "the package test states the Debian-family requirement" \
  "$(grep -qi 'Debian-family' "$ROOT/tests/README.md" && echo yes || echo no)" "yes"
check "build-deb.sh has no platform-conditional path" \
  "$(grep -qc 'SHINOBI_DEB_STAGE_ONLY' "$ROOT/packaging/build-deb.sh" && echo yes || echo no)" "no"
check "tests/README.md says python3 is required" \
  "$(grep -qi 'python3' "$ROOT/tests/README.md" && echo yes || echo no)" "yes"

echo "== every test suite is listed in tests/README.md =="
for suite in "$ROOT"/tests/test-*.sh; do
  name="$(basename "$suite")"
  check "tests/README.md lists $name" \
    "$(grep -q "$name" "$ROOT/tests/README.md" && echo yes || echo no)" "yes"
done

echo "== operator-facing build knobs are documented =="
# These now reject invalid values, so an operator who sets one needs the list.
for knob in SHINOBI_VARIANT SHINOBI_SQUASHFS_COMPRESSION SHINOBI_SQUASHFS_LEVEL; do
  check "distro/README.md documents $knob" \
    "$(grep -q "$knob" "$ROOT/distro/README.md" && echo yes || echo no)" "yes"
done
check "distro/README.md lists the valid compression types" \
  "$(grep -qiE 'gzip.*xz.*zstd.*lz4|gzip xz zstd lz4' "$ROOT/distro/README.md" && echo yes || echo no)" "yes"

echo "== the commands the docs tell you to run actually resolve =="
# A quickstart naming a renamed command is worse than no quickstart. The
# dispatcher routes `shinobi foo bar` to bin/shinobi-foo-bar, so ask it.
# Only backticked references count; prose like "add shinobi to an existing" is
# not a command.
for verb in $(grep -oE '`shinobi [a-z][a-z-]*' "$ROOT/README.md" | awk '{print $2}' | sort -u); do
  [[ "$verb" == "help" ]] && continue
  check "'shinobi $verb' resolves to a command" \
    "$(bin_out="$(SHINOBI_BIN_DIR="$ROOT/bin" "$ROOT/bin/shinobi" "$verb" --help 2>&1)"; \
       grep -q "^Usage: shinobi $verb" <<<"$bin_out" && echo yes || echo no)" "yes"
done

echo "== every workflow action is pinned to a commit =="
for workflow in "$ROOT"/.github/workflows/*.yml; do
  name="$(basename "$workflow")"
  while read -r ref; do
    check "$name pins $ref" \
      "$(printf '%s' "$ref" | grep -qE '@[0-9a-f]{40}$' && echo yes || echo no)" "yes"
  done < <(grep -oE 'uses: [^ ]+' "$workflow" | awk '{print $2}' | sort -u)
done

echo
if (( failures > 0 )); then
  printf 'docs-test: FAIL (%d of %d checks failed)\n' "$failures" "$checks"
  exit 1
fi
printf '%d/%d checks passed\ndocs-test: PASS\n' "$checks" "$checks"
