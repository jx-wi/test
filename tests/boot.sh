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

echo "building stub-claude ccvm wrapper (builds the guest closure; first run is slow)…" >&2
WRAP="$(nix build --impure --no-link --print-out-paths -f tests/boot.nix)/bin/ccvm"

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
# (CLAUDE.md gotcha: otherwise grep silently misses). We must capture the wrapper's stdout
# (the guest output we assert on) WITHOUT discarding its stderr: a boot failure ("boot
# failed", console/qemu tail) prints to stderr, and silently swallowing it under `set -e`
# turns a real failure into an invisible non-zero exit. So tee stderr to a log and, if the
# wrapper exits non-zero, surface it here instead of letting the script die mute.
run_capture() { # $1=project dir, rest=ccvm args; prints cleaned guest stdout
  local proj="$1" out errlog rc=0
  shift
  errlog="$(mktemp)"
  # `|| rc=$?` captures the wrapper's true exit code (an `if !` test would reset $? to 0)
  # and keeps `set -e` from killing us, so a boot failure surfaces instead of dying mute.
  out="$( (cd "$proj" && "$WRAP" "$@") 2>"$errlog" )" || rc=$?
  if ((rc != 0)); then
    {
      printf '\n!! ccvm exited %d — wrapper stderr follows (likely a boot failure):\n' "$rc"
      sed 's/^/    /' "$errlog"
      printf '   (under TCG this is often the boot timeout — see CCVM_BOOT_TRIES)\n\n'
    } >&2
  fi
  rm -f "$errlog"
  printf '%s' "$out" | tr -d '\r'
}

# ---- rw (default): a guest write lands on the host -------------------------
PROJ_RW="$(mktemp -d)"
OUT="$(run_capture "$PROJ_RW" hello 'two words')"
grep -qa 'CCVM_BOOT_MARKER' <<<"$OUT" &&
  ok "stub claude launched inside the guest" || no "claude did not launch"
grep -qa '^ARGV:hello two words$' <<<"$OUT" &&
  ok "argv forwarded verbatim to claude" || no "argv wrong: $(grep -a '^ARGV:' <<<"$OUT")"
[ -f "$PROJ_RW/ccvm-boot-write" ] &&
  ok "rw mode: guest edit landed on the host project" || no "rw mode: host file missing"
# uid remap: the agent runs as the host uid (not the baked 1000), and the file it wrote
# on the host is owned by the host user — the whole point of #4 (correct for any host uid).
grep -qa "^UID:$(id -u)$" <<<"$OUT" &&
  ok "guest agent uid remapped to the host uid" ||
  no "guest uid not remapped: $(grep -a '^UID:' <<<"$OUT") (host $(id -u))"
if [ -f "$PROJ_RW/ccvm-boot-write" ]; then
  [ "$(stat -c %u "$PROJ_RW/ccvm-boot-write")" = "$(id -u)" ] &&
    ok "rw mode: host file owned by the host user (correct ownership)" ||
    no "rw mode: host file owned by uid $(stat -c %u "$PROJ_RW/ccvm-boot-write"), want $(id -u)"
fi
rm -rf "$PROJ_RW"

# ---- overlay (--no-auto-update-files): the write stays in the VM -----------
PROJ_RO="$(mktemp -d)"
OUT="$(run_capture "$PROJ_RO" --no-auto-update-files hi)"
grep -qa 'WRITE:ok' <<<"$OUT" &&
  ok "overlay mode: guest writes its tmpfs upper" || no "overlay: guest write failed"
[ ! -e "$PROJ_RO/ccvm-boot-write" ] &&
  ok "overlay mode: host project untouched (edit stayed ephemeral)" ||
  no "overlay mode: host file LEAKED — isolation broken"
rm -rf "$PROJ_RO"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
