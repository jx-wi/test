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
export CCVM_SHARE_CLAUDE_CONFIG="${CCVM_SHARE_CLAUDE_CONFIG:-0}"

echo "building stub-claude ccvm wrappers (builds the guest closure; first run is slow)…" >&2
WRAP="$(nix build --impure --no-link --print-out-paths -f tests/boot.nix open)/bin/ccvm"
WRAP_EGRESS="$(nix build --impure --no-link --print-out-paths -f tests/boot.nix egress)/bin/ccvm"
WRAP_SCRATCH="$(nix build --impure --no-link --print-out-paths -f tests/boot.nix scratch)/bin/ccvm"
WRAP_PERSIST="$(nix build --impure --no-link --print-out-paths -f tests/boot.nix persist)/bin/ccvm"
WRAP_NIX="$(nix build --impure --no-link --print-out-paths -f tests/boot.nix nix)/bin/ccvm"
WRAP_NIXDISK="$(nix build --impure --no-link --print-out-paths -f tests/boot.nix nixDisk)/bin/ccvm"
WRAP_NIXSUBST="$(nix build --impure --no-link --print-out-paths -f tests/boot.nix nixSubst)/bin/ccvm"

# Deterministic git-config fixture so the shareGitConfig assertions don't depend on the
# runner's real ~/.gitconfig. Point HOME here for the wrapper runs (set AFTER `nix build`, so
# nix still uses the real ~/.config/nix). With CCVM_SHARE_CLAUDE_CONFIG=0 nothing else reads HOME, so
# this only affects the git passthrough under test. The fixture mixes real identity with
# host-only /nix/store tool paths + signing that the wrapper must sanitize out.
FIXTURE_HOME="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_HOME"' EXIT
printf '%s\n' 'boot-fixture-ignored' >"$FIXTURE_HOME/.gitignore-global"
cat >"$FIXTURE_HOME/.gitconfig" <<EOF
[user]
	name = BootTester
	email = boot@example.com
[credential "https://github.com"]
	helper = /nix/store/deadbeef-gh/bin/gh auth git-credential
[core]
	pager = /nix/store/deadbeef-delta/bin/delta
	excludesfile = $FIXTURE_HOME/.gitignore-global
[commit]
	gpgsign = true
EOF
export HOME="$FIXTURE_HOME"

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
run_capture() { # $1=wrapper, $2=project dir, rest=ccvm args; prints cleaned guest stdout
  local wrap="$1" proj="$2" out errlog rc=0
  shift 2
  errlog="$(mktemp)"
  # `|| rc=$?` captures the wrapper's true exit code (an `if !` test would reset $? to 0)
  # and keeps `set -e` from killing us, so a boot failure surfaces instead of dying mute.
  out="$( (cd "$proj" && "$wrap" "$@") 2>"$errlog" )" || rc=$?
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
OUT="$(run_capture "$WRAP" "$PROJ_RW" hello 'two words')"
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
# shareGitConfig: the sanitized host git identity reached the guest, with the host-only
# /nix/store tool paths stripped and signing disabled (so in-VM `git commit` works as you).
grep -qa '^GIT:config-present$' <<<"$OUT" &&
  ok "git: sanitized config reached the guest" || no "git: no config in the guest"
grep -qa '^GITNAME:BootTester$' <<<"$OUT" &&
  ok "git: host identity carried into the guest" ||
  no "git: identity not carried: $(grep -a '^GITNAME:' <<<"$OUT")"
grep -qa '^GIT:sanitized$' <<<"$OUT" &&
  ok "git: host-only /nix/store tool paths stripped in the guest" ||
  no "git: a /nix/store path survived into the guest config"
grep -qa '^GITSIGN:false$' <<<"$OUT" &&
  ok "git: signing force-disabled in the guest (commits won't fail)" ||
  no "git: signing not disabled: $(grep -a '^GITSIGN:' <<<"$OUT")"
grep -qa '^GIT:ignore-present$' <<<"$OUT" &&
  ok "git: global ignore staged to the guest's default path" || no "git: global ignore missing"
# extraClaudeMd: the ccvm-context global memory reached the guest as ~/.claude/CLAUDE.md, with
# the baked blurb and the rw-mode "edits are live" note (so the agent knows where it is).
grep -qa '^CLAUDEMD:present$' <<<"$OUT" &&
  ok "claude-md: ccvm-context laid at the guest's ~/.claude/CLAUDE.md" ||
  no "claude-md: not present in the guest"
grep -qa '^CLAUDEMD:blurb$' <<<"$OUT" &&
  ok "claude-md: the ccvm-context blurb survived into the guest" || no "claude-md: blurb missing"
grep -qa '^CLAUDEMD:mode-rw$' <<<"$OUT" &&
  ok "claude-md: rw-mode 'edits are live' note present in the guest" || no "claude-md: rw mode note missing"
# Default (nix.enable off): the store stays read-only and nix is absent — the lean default posture.
grep -qa '^STORE:readonly$' <<<"$OUT" &&
  ok "default: /nix/store is read-only (no in-VM nix)" ||
  no "default: /nix/store not read-only: $(grep -a '^STORE:' <<<"$OUT")"
grep -qa '^NIX:absent$' <<<"$OUT" &&
  ok "default: nix is absent from the guest (lean closure)" || no "default: nix unexpectedly present"
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

# ---- vmDiskSize: /scratch is a writable, dm-crypt-backed mount --------------
# The guest LUKS-formats the attached sparse disk with a key it generates in its own RAM and
# mounts it at /scratch. We host the image in a fresh tmp dir (and allow tmpfs, since the
# runner's /tmp is often tmpfs — a real deployment uses ~/.cache, but for a 1 GiB sparse test
# image on tmpfs that's fine). The stub asserts the mount is present, writable, on a dm-crypt device.
PROJ_SC="$(mktemp -d)"
SCRATCH_TMP="$(mktemp -d)"
OUT="$(CCVM_SCRATCH_DIR="$SCRATCH_TMP" CCVM_SCRATCH_ALLOW_TMPFS=1 run_capture "$WRAP_SCRATCH" "$PROJ_SC")"
grep -qa '^SCRATCH:mounted$' <<<"$OUT" &&
  ok "vmDiskSize: /scratch is mounted in the guest" ||
  no "vmDiskSize: /scratch not mounted: $(grep -a '^SCRATCH:' <<<"$OUT")"
grep -qa '^SCRATCH:writable$' <<<"$OUT" &&
  ok "vmDiskSize: /scratch is writable by the agent" || no "vmDiskSize: /scratch not writable"
grep -qa '^SCRATCH:encrypted$' <<<"$OUT" &&
  ok "vmDiskSize: /scratch is backed by a dm-crypt (LUKS) device" ||
  no "vmDiskSize: /scratch not on a dm-crypt device (host could read plaintext)"
# Belt-and-suspenders: the wrapper's trap should have removed the image on exit.
[ -z "$(find "$SCRATCH_TMP" -name 'vmdisk-*.img' 2>/dev/null)" ] &&
  ok "vmDiskSize: disk image removed on exit" ||
  no "vmDiskSize: disk image left behind after exit"
rm -rf "$PROJ_SC" "$SCRATCH_TMP"

# ---- nix.enable: /nix/store is a writable overlay + nix is present -------------
# The guest is built with nix.enable and a writable /nix/store overlay (ro store lower + tmpfs
# upper, set up in the initrd). We can't do a full `nix build` here without leaning on the
# network/cache, so assert the structural guarantees: the store is an overlayfs (not the ro
# squashfs) and `nix` is on PATH. A real `nix develop` is the human sanity pass.
PROJ_NIX="$(mktemp -d)"
OUT="$(run_capture "$WRAP_NIX" "$PROJ_NIX")"
grep -qa '^STORE:overlay$' <<<"$OUT" &&
  ok "nix.enable: /nix/store is a writable overlay (ro lower + tmpfs upper)" ||
  no "nix.enable: /nix/store not an overlay: $(grep -a '^STORE:' <<<"$OUT")"
grep -qa '^NIX:present$' <<<"$OUT" &&
  ok "nix.enable: nix is available in the guest" || no "nix.enable: nix not on PATH"
rm -rf "$PROJ_NIX"

# ---- nix.enable + vmDiskSize: the overlay upper is backed by the encrypted disk ----
# Both features on: the INITRD LUKS-opens the disk and mounts it as the /nix/store overlay UPPER
# (/nix/.rw-store) instead of tmpfs, so a multi-GB closure doesn't OOM RAM — and /scratch shares
# that same pool. Assert: store is still an overlay, nix present, the upper is a dm-crypt ext4 (NOT
# tmpfs — that would mean it fell open to RAM), and /scratch is a writable mount off the shared pool.
PROJ_ND="$(mktemp -d)"
ND_TMP="$(mktemp -d)"
OUT="$(CCVM_SCRATCH_DIR="$ND_TMP" CCVM_SCRATCH_ALLOW_TMPFS=1 run_capture "$WRAP_NIXDISK" "$PROJ_ND")"
grep -qa '^STORE:overlay$' <<<"$OUT" &&
  ok "nix.enable+disk: /nix/store is still a writable overlay" ||
  no "nix.enable+disk: /nix/store not an overlay: $(grep -a '^STORE:' <<<"$OUT")"
grep -qa '^NIX:present$' <<<"$OUT" &&
  ok "nix.enable+disk: nix is available in the guest" || no "nix.enable+disk: nix not on PATH"
grep -qa '^RWSTORE:disk$' <<<"$OUT" &&
  ok "nix.enable+disk: overlay upper is disk-backed ext4 (not tmpfs/RAM)" ||
  no "nix.enable+disk: overlay upper not disk-backed (fell open to tmpfs?): $(grep -a '^RWSTORE:' <<<"$OUT")"
grep -qa '^RWSTORE:encrypted$' <<<"$OUT" &&
  ok "nix.enable+disk: overlay upper sits on a dm-crypt (LUKS) device" ||
  no "nix.enable+disk: overlay upper not on a dm-crypt device (host could read plaintext)"
grep -qa '^SCRATCH:mounted$' <<<"$OUT" &&
  ok "nix.enable+disk: /scratch shares the same disk pool" ||
  no "nix.enable+disk: /scratch not mounted: $(grep -a '^SCRATCH:' <<<"$OUT")"
grep -qa '^SCRATCH:writable$' <<<"$OUT" &&
  ok "nix.enable+disk: /scratch is writable by the agent" || no "nix.enable+disk: /scratch not writable"
rm -rf "$PROJ_ND" "$ND_TMP"

# ---- nix.substituters / nix.trustedPublicKeys: extra binary cache reaches guest nix.conf ----
# nix.substituters/trustedPublicKeys are pure guest-closure config (a binary cache is HTTP
# substitution, no mount). Assert the configured substituter URL and its trusted public key both
# reach the guest's effective nix config. (A real fetch is a network/human check — example.invalid
# never resolves; what we verify here is that the option plumbs through to nix.conf.)
PROJ_SUB="$(mktemp -d)"
OUT="$(run_capture "$WRAP_NIXSUBST" "$PROJ_SUB")"
grep -qa '^SUBST:substituter-configured$' <<<"$OUT" &&
  ok "substituters: configured cache URL reaches the guest nix.conf" ||
  no "substituters: cache URL not in guest nix.conf: $(grep -a '^SUBST:' <<<"$OUT")"
grep -qa '^SUBST:key-configured$' <<<"$OUT" &&
  ok "substituters: trusted public key reaches the guest nix.conf (signatures stay verified)" ||
  no "substituters: trusted public key not in guest nix.conf: $(grep -a '^SUBST:' <<<"$OUT")"
rm -rf "$PROJ_SUB"

# ---- persistClaudeProjects: a guest write to ~/.claude/projects lands on the host ----------
# The persist posture mounts the host ~/.claude/projects (here: $FIXTURE_HOME/.claude/projects)
# read-WRITE. Assert the FUNCTIONAL guarantee that host.sh can't (it never boots): a guest write
# under projects/ actually reaches the host, AND the scope holds — a write at the ~/.claude ROOT
# stays ephemeral (only projects/ is mounted, so the credential there can never be written back).
PROJ_PER="$(mktemp -d)"
HOST_PROJ="$FIXTURE_HOME/.claude/projects"
rm -rf "$HOST_PROJ" "$FIXTURE_HOME/.claude/ccvm-root-probe"
OUT="$(run_capture "$WRAP_PERSIST" "$PROJ_PER")"
grep -qa '^PERSIST:wrote-projects$' <<<"$OUT" &&
  ok "persistClaudeProjects: guest wrote into ~/.claude/projects (rw mount)" ||
  no "persistClaudeProjects: guest could not write ~/.claude/projects: $(grep -a '^PERSIST:' <<<"$OUT")"
grep -q 'CCVM-PERSIST-MARKER' "$HOST_PROJ/ccvm-persist-probe" 2>/dev/null &&
  ok "persistClaudeProjects: the write PERSISTED back to the host projects dir" ||
  no "persistClaudeProjects: guest write did NOT reach the host (persistence broken)"
[ ! -e "$FIXTURE_HOME/.claude/ccvm-root-probe" ] &&
  ok "persistClaudeProjects: a write at the ~/.claude ROOT did NOT persist (projects-only scope holds)" ||
  no "persistClaudeProjects: a ~/.claude ROOT write reached the host — scope leak (credential path at risk)"
rm -rf "$PROJ_PER" "$HOST_PROJ" "$FIXTURE_HOME/.claude/ccvm-root-probe"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
