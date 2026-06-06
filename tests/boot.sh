#!/usr/bin/env bash
#
# Full-boot smoke test. Builds a ccvm with a stub `claude` (tests/stub-claude.sh) and boots
# the REAL VM to check the guarantees that need an actual guest: that the forwarded argv
# reaches claude, that the workspace is mounted at the host path, and — the security-load-
# bearing pair — that overlay mode keeps a guest edit ephemeral while rw mode lands it on
# the host.
#
# Unlike tests/host.sh (pure host-side, runs in CI), this needs a working VM. It defaults to
# TCG software emulation so it runs anywhere — slow but correct (CLAUDE.md: KVM is often
# unavailable under nested virt / CI). Export CCVM_ACCEL=kvm CCVM_MACHINE=microvm for speed
# where /dev/kvm works. This is the local definition-of-done gate, not a CI check.
#
#   bash tests/boot.sh
set -euo pipefail

cd "$(dirname "$0")/.."

export CCVM_ACCEL="${CCVM_ACCEL:-tcg}"
export CCVM_MACHINE="${CCVM_MACHINE:-q35}"
# Don't drag the host's real ~/.claude into the boot test; we assert on files, not config.
export CCVM_SHARE_CONFIG="${CCVM_SHARE_CONFIG:-0}"

echo "building stub-claude ccvm wrappers (builds the guest closure; first run is slow)…" >&2
WRAP="$(nix build --impure --no-link --print-out-paths -f tests/boot.nix open)/bin/ccvm"
WRAP_EGRESS="$(nix build --impure --no-link --print-out-paths -f tests/boot.nix egress)/bin/ccvm"

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf 'ok   - %s\n' "$1"
}
no() {
  FAIL=$((FAIL + 1))
  printf 'FAIL - %s\n' "$1" >&2
}

# ssh -tt gives the guest a PTY, so captured output carries \r — strip it before matching
# (CLAUDE.md gotcha: otherwise grep silently misses).
run_capture() { # $1=wrapper, $2=project dir, rest=ccvm args; prints cleaned guest stdout
  local wrap="$1" proj="$2"
  shift 2
  (cd "$proj" && "$wrap" "$@") 2>/dev/null | tr -d '\r'
}

# ---- rw (default): a guest write lands on the host -------------------------
PROJ_RW="$(mktemp -d)"
OUT="$(run_capture "$WRAP" "$PROJ_RW" hello 'two words')"
grep -qa 'CCVM_BOOT_MARKER' <<<"$OUT" &&
  ok "stub claude launched inside the guest" || no "claude did not launch"
grep -qa '^ARGV:hello two words$' <<<"$OUT" &&
  ok "argv forwarded verbatim to claude" || no "argv wrong: $(grep -a '^ARGV:' <<<"$OUT")"
[ -f "$PROJ_RW/ccvm-boot-write" ] &&
  ok "rw mode: guest edit landed on the host project" || no "rw mode: host file missing"
rm -rf "$PROJ_RW"

# ---- overlay (--no-auto-update-files): the write stays in the VM -----------
PROJ_RO="$(mktemp -d)"
OUT="$(run_capture "$WRAP" "$PROJ_RO" --no-auto-update-files hi)"
grep -qa 'WRITE:ok' <<<"$OUT" &&
  ok "overlay mode: guest writes its tmpfs upper" || no "overlay: guest write failed"
[ ! -e "$PROJ_RO/ccvm-boot-write" ] &&
  ok "overlay mode: host project untouched (edit stayed ephemeral)" ||
  no "overlay mode: host file LEAKED — isolation broken"
rm -rf "$PROJ_RO"

# ---- egress allowlist: only the allowlisted host is reachable --------------
# Needs outbound internet. The egress wrapper allowlists example.com (api.anthropic.com is
# auto-included); the stub probes example.com (must reach) and 1.1.1.1 (must be blocked).
PROJ_EG="$(mktemp -d)"
OUT="$(run_capture "$WRAP_EGRESS" "$PROJ_EG")"
grep -qa '^EGRESS:allowed:reachable$' <<<"$OUT" &&
  ok "egress allowlist: allowlisted host reachable" ||
  no "egress: allowlisted host unreachable (allowlist too strict?): $(grep -a '^EGRESS:' <<<"$OUT")"
grep -qa '^EGRESS:denied:blocked$' <<<"$OUT" &&
  ok "egress allowlist: non-allowlisted host blocked" ||
  no "egress: non-allowlisted host NOT blocked — exfil channel open: $(grep -a '^EGRESS:' <<<"$OUT")"
rm -rf "$PROJ_EG"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
