#!/usr/bin/env bash
#
# Host-side guarantee tests for ccvm. These drive the *real* wrapper via its CCVM_DRYRUN
# hook (populate the seed + run the config-staging loop, then stop before booting QEMU),
# so they exercise the exact secret-handling code path with no VM and no claude-code —
# fast enough to run in `nix flake check` / CI.
#
# Required env:
#   CCVM   path to a ccvm wrapper built with dummy boot artifacts (tests/default.nix).
#
# Covers the security-critical invariants from CLAUDE.md / design §3.7:
#   * the API key never reaches the seed (it rides SendEnv over SSH only),
#   * the OAuth credential is never staged into the seed (top-level *and* nested),
#   * escaping host-config symlinks (home-manager) ARE dereferenced into the seed,
#   * the forwarded argv round-trips byte-for-byte (NUL-separated),
#   * ccvm-only flags are consumed, not forwarded, and select the mode.
set -euo pipefail

: "${CCVM:?set CCVM to the dry-run wrapper binary}"

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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export XDG_RUNTIME_DIR="$WORK/run"
mkdir -p "$XDG_RUNTIME_DIR"

# Every invocation runs the wrapper's host-side path only — populate the seed, stage
# config, then stop before booting QEMU.
export CCVM_DRYRUN=1

# Markers we will hunt for in the seed. The credential marker must NEVER appear there.
CRED_MARKER="OAUTH-CREDENTIAL-MUST-NOT-LEAK"
NESTED_CRED_MARKER="NESTED-CREDENTIAL-MUST-NOT-LEAK"
SETTINGS_MARKER="settings-content-should-be-staged"
API_KEY="sk-ant-SECRET-KEY-MUST-NOT-LEAK"

# ---- fixture: a home-manager-style ~/.claude -------------------------------
# Config files live OUTSIDE ~/.claude (in a "store") and are symlinked in, exactly like
# home-manager. settings.json escapes the tree (must be dereferenced into the seed); the
# OAuth credential is ALSO an escaping symlink (must NOT be) — both the top-level one and
# one dragged in via an escaping directory symlink.
HM_STORE="$WORK/hm-store"
mkdir -p "$HM_STORE/.claude" "$HM_STORE/agents"
printf '%s\n' "$SETTINGS_MARKER" >"$HM_STORE/.claude/settings.json"
printf '{"oauth":"%s"}\n' "$CRED_MARKER" >"$HM_STORE/.claude/.credentials.json"
printf '{"oauth":"%s"}\n' "$NESTED_CRED_MARKER" >"$HM_STORE/agents/.credentials.json"
printf 'agent body\n' >"$HM_STORE/agents/helper.md"

FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/.claude"
ln -s "$HM_STORE/.claude/settings.json" "$FAKE_HOME/.claude/settings.json"
ln -s "$HM_STORE/.claude/.credentials.json" "$FAKE_HOME/.claude/.credentials.json"
# An escaping *directory* symlink whose target contains a nested .credentials.json — the
# defense-in-depth `find -delete` must strip it after cp -rL drags it in.
ln -s "$HM_STORE/agents" "$FAKE_HOME/.claude/agents"
printf '{"non":"secret"}\n' >"$FAKE_HOME/.claude.json"

# Run the wrapper in dry-run; echo the scratch dir it prints. Each call gets a fresh CWD
# so $PWD (the shared workspace) is well-defined.
run() {
  local cwd
  cwd="$(mktemp -d "$WORK/cwd.XXXXXX")"
  ( cd "$cwd" && "$CCVM" "$@" )
}

# ===========================================================================
# 1. shareClaudeConfig staging: secret out, non-secret in.
# ===========================================================================
SEED="$(HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=1 run)/seed"

if [[ -z "$(grep -rl "$CRED_MARKER" "$SEED" 2>/dev/null)" ]]; then
  ok "top-level OAuth credential never reaches the seed"
else
  no "top-level OAuth credential LEAKED into the seed: $(grep -rl "$CRED_MARKER" "$SEED")"
fi

if [[ -z "$(grep -rl "$NESTED_CRED_MARKER" "$SEED" 2>/dev/null)" ]]; then
  ok "nested OAuth credential (via dir symlink) never reaches the seed"
else
  no "nested OAuth credential LEAKED into the seed"
fi

if [[ -f "$SEED/config-deref/settings.json" ]] &&
  grep -q "$SETTINGS_MARKER" "$SEED/config-deref/settings.json"; then
  ok "escaping settings.json symlink is dereferenced into the seed"
else
  no "settings.json was not staged into config-deref"
fi

if [[ ! -e "$SEED/config-deref/.credentials.json" ]]; then
  ok "no .credentials.json file exists anywhere under config-deref"
else
  no ".credentials.json present under config-deref"
fi

[[ -f "$SEED/claude-json" ]] && ok "non-secret ~/.claude.json staged" ||
  no "~/.claude.json not staged"
[[ "$(cat "$SEED/share-claude-config" 2>/dev/null)" == 1 ]] && ok "share-claude-config flag written" ||
  no "share-claude-config flag missing"

# ===========================================================================
# 2. The API key never reaches the seed (it rides SendEnv over SSH only).
# ===========================================================================
SEED="$(HOME="$FAKE_HOME" ANTHROPIC_API_KEY="$API_KEY" CCVM_SHARE_CLAUDE_CONFIG=0 run)/seed"
if [[ -z "$(grep -rl "$API_KEY" "$SEED" 2>/dev/null)" ]]; then
  ok "ANTHROPIC_API_KEY never written to the seed"
else
  no "ANTHROPIC_API_KEY LEAKED into the seed"
fi

# ===========================================================================
# 3. Verbatim argv: spaces, quotes and globs survive NUL-separated round-trip.
# ===========================================================================
declare -a EXPECT=(--model sonnet 'two words' 'a"b' '*' '--' '-x')
SEED="$(HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 run "${EXPECT[@]}")/seed"
declare -a GOT=()
mapfile -t -d "" GOT <"$SEED/claude-args"
if [[ "${GOT[*]@Q}" == "${EXPECT[*]@Q}" ]]; then
  ok "forwarded argv round-trips byte-for-byte"
else
  no "argv mismatch: got ${GOT[*]@Q} want ${EXPECT[*]@Q}"
fi

# ===========================================================================
# 4. ccvm-only flags are consumed (not forwarded) and select the mode.
# ===========================================================================
SEED="$(HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 run --no-auto-update-files --model x)/seed"
[[ "$(cat "$SEED/mode")" == overlay ]] && ok "--no-auto-update-files selects overlay mode" ||
  no "mode not overlay (got $(cat "$SEED/mode"))"
declare -a EXPECT_FWD=(--model x)
mapfile -t -d "" GOT <"$SEED/claude-args"
if [[ "${GOT[*]@Q}" == "${EXPECT_FWD[*]@Q}" ]]; then
  ok "--no-auto-update-files consumed, not forwarded to claude"
else
  no "ccvm flag leaked into claude argv: ${GOT[*]@Q}"
fi

SEED="$(HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 run)/seed"
[[ "$(cat "$SEED/mode")" == rw ]] && ok "default mode is rw (native mirroring)" ||
  no "default mode not rw (got $(cat "$SEED/mode"))"

# With no baked egress allowlist (this wrapper), egress stays OPEN: neither the allow set nor
# the enforce marker is written, so the guest installs no OUTPUT filter (native default). The
# marker is what the guest gates on, so its absence is the real "open egress" guarantee.
[[ ! -e "$SEED/egress-allow" && ! -e "$SEED/egress-enforce" ]] &&
  ok "default: open egress (no allowlist or enforce marker staged)" ||
  no "egress firewall staged with an empty allowlist (allow=$([[ -e "$SEED/egress-allow" ]] && echo y || echo n) enforce=$([[ -e "$SEED/egress-enforce" ]] && echo y || echo n))"

# ===========================================================================
# 5. CCVM_MEMORY override: a positive integer is accepted, anything else rejected
#    before boot (so a typo can't silently fall back to the baked default).
# ===========================================================================
if HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 CCVM_MEMORY=16384 run >/dev/null 2>&1; then
  ok "CCVM_MEMORY accepts a positive integer"
else
  no "CCVM_MEMORY=16384 was rejected"
fi
if HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 CCVM_MEMORY=lots run >/dev/null 2>&1; then
  no "CCVM_MEMORY=lots was not rejected"
else
  ok "CCVM_MEMORY rejects a non-integer"
fi

# ===========================================================================
# 6. Host uid/gid are staged into the seed (the guest remaps its agent user to
#    them so 9p passthrough gives correct workspace ownership for any host uid).
# ===========================================================================
SEED="$(HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 run)/seed"
if [[ "$(cat "$SEED/host-uid" 2>/dev/null)" == "$(id -u)" ]]; then
  ok "host uid staged into the seed"
else
  no "host-uid wrong/missing (got '$(cat "$SEED/host-uid" 2>/dev/null)', want '$(id -u)')"
fi
if [[ "$(cat "$SEED/host-gid" 2>/dev/null)" == "$(id -g)" ]]; then
  ok "host gid staged into the seed"
else
  no "host-gid wrong/missing (got '$(cat "$SEED/host-gid" 2>/dev/null)', want '$(id -g)')"
fi

# ===========================================================================
# 7. Static: the wrapper uses SendEnv (in-channel) and never SetEnv (argv).
# ===========================================================================
grep -q 'SendEnv=' "$CCVM" && ok "wrapper passes the key via SendEnv" ||
  no "wrapper does not use SendEnv"
if grep -q 'SetEnv' "$CCVM"; then
  no "wrapper uses SetEnv (would put the secret on argv)"
else
  ok "wrapper never uses SetEnv"
fi

# ===========================================================================
# 8. shareGitConfig staging: identity/aliases/ignores carried, but host-only
#    /nix/store tool paths, credentials and signing are sanitized out.
# ===========================================================================
# A home-manager-style global git config: real personalization mixed with absolute
# /nix/store paths (editor/pager/gh credential helper) that don't exist in the guest, a
# global ignore file, and signing turned on (whose key the VM deliberately never gets).
GIT_HOME="$WORK/githome"
mkdir -p "$GIT_HOME"
GITIGNORE_SRC="$WORK/fixture-gitignore"
printf '%s\n' 'fixture-ignored-marker' >"$GITIGNORE_SRC"
cat >"$GIT_HOME/.gitconfig" <<EOF
[user]
	name = Fixture Tester
	email = fixture@example.com
[init]
	defaultBranch = main
[alias]
	co = checkout
[pull]
	rebase = true
[credential "https://github.com"]
	helper = /nix/store/deadbeef-gh/bin/gh auth git-credential
[core]
	pager = /nix/store/deadbeef-delta/bin/delta
	editor = nvim
	excludesfile = $GITIGNORE_SRC
[commit]
	gpgsign = true
EOF

# Isolate from any inherited XDG config so only this fixture is the "global" git config.
SEED="$(HOME="$GIT_HOME" XDG_CONFIG_HOME="$GIT_HOME/xdg" CCVM_SHARE_CLAUDE_CONFIG=0 run)/seed"
GC="$SEED/gitconfig"

[[ -f "$GC" ]] && ok "git: sanitized config staged into the seed" ||
  no "git: no gitconfig staged"
grep -q 'Fixture Tester' "$GC" 2>/dev/null && ok "git: user identity carried into the VM" ||
  no "git: user identity missing from staged config"
grep -q 'checkout' "$GC" 2>/dev/null && ok "git: aliases carried into the VM" ||
  no "git: alias missing from staged config"
if grep -q '/nix/store' "$GC" 2>/dev/null; then
  no "git: a /nix/store tool path LEAKED into the staged config (would dangle in the guest)"
else
  ok "git: host-only /nix/store tool paths stripped"
fi
if grep -qi 'helper' "$GC" 2>/dev/null; then
  no "git: credential.* helper LEAKED into the staged config"
else
  ok "git: credential helpers stripped (no host credentials cross the boundary)"
fi
if grep -q 'gpgsign = false' "$GC" 2>/dev/null && ! grep -q 'gpgsign = true' "$GC" 2>/dev/null; then
  ok "git: commit/tag signing force-disabled (signing key never carried)"
else
  no "git: signing not disabled (gpgsign=true would break in-VM commits)"
fi
if [[ -f "$SEED/gitignore" ]] && grep -q 'fixture-ignored-marker' "$SEED/gitignore"; then
  ok "git: global ignore content staged to the guest's default ignore path"
else
  no "git: global excludesfile content not staged"
fi

# Opt out: CCVM_SHARE_GIT_CONFIG=0 must stage nothing at all.
SEED="$(HOME="$GIT_HOME" XDG_CONFIG_HOME="$GIT_HOME/xdg" CCVM_SHARE_CLAUDE_CONFIG=0 CCVM_SHARE_GIT_CONFIG=0 run)/seed"
[[ ! -e "$SEED/gitconfig" && ! -e "$SEED/gitignore" ]] &&
  ok "git: CCVM_SHARE_GIT_CONFIG=0 stages no git config" ||
  no "git: opt-out still staged a git config/ignore"

# ===========================================================================
# 9. extraClaudeMd: the ccvm-context global memory is staged into the seed, with
#    a runtime-accurate file-sharing-mode line prepended; CCVM_CLAUDE_MD= opts out.
# ===========================================================================
# Default (rw) run: claude-md staged, carries the baked blurb AND the LIVE mode line.
SEED="$(HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 run)/seed"
CM="$SEED/claude-md"
[[ -f "$CM" ]] && ok "claude-md: ccvm-context staged into the seed" ||
  no "claude-md: not staged"
grep -q 'CCVM-CONTEXT-MARKER' "$CM" 2>/dev/null &&
  ok "claude-md: baked context blurb reaches the seed" ||
  no "claude-md: baked blurb missing from the seed"
grep -q 'LIVE to the host' "$CM" 2>/dev/null &&
  ok "claude-md: rw mode prepends the LIVE-edits note" ||
  no "claude-md: rw mode line missing"
# persist off (baked default): the agent is told memory is ephemeral and to prefer the codebase.
grep -q 'do NOT persist across runs' "$CM" 2>/dev/null &&
  grep -q 'PREFER writing durable information into the codebase' "$CM" 2>/dev/null &&
  ok "claude-md: persist-off run warns memory is ephemeral, prefer the codebase" ||
  no "claude-md: missing the ephemeral-memory / prefer-codebase guidance"

# Overlay run: the mode line must flip to the DISCARDED warning (and not claim LIVE).
SEED="$(HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 run --no-auto-update-files)/seed"
CM="$SEED/claude-md"
if grep -q 'DISCARDED' "$CM" 2>/dev/null && ! grep -q 'LIVE to the host' "$CM" 2>/dev/null; then
  ok "claude-md: overlay mode prepends the DISCARDED-edits warning"
else
  no "claude-md: overlay mode line wrong (should warn DISCARDED, not LIVE)"
fi

# Opt out: CCVM_CLAUDE_MD= (set empty) disables injection entirely.
SEED="$(HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 CCVM_CLAUDE_MD= run)/seed"
[[ ! -e "$SEED/claude-md" ]] &&
  ok "claude-md: CCVM_CLAUDE_MD= stages no context" ||
  no "claude-md: opt-out still staged a context file"

# ===========================================================================
# 10. persistClaudeProjects: opt-in writes the enforce marker and ensures the
#     host ~/.claude/projects dir exists; default (baked off) stages nothing.
# ===========================================================================
# Default (baked PERSISTPROJECTS=0): no marker — projects writes stay ephemeral.
SEED="$(HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 run)/seed"
[[ ! -e "$SEED/persist-claude-projects" ]] &&
  ok "persist: default stages no projects-persist marker" ||
  no "persist: marker present without opt-in"

# Opt in via the env override: marker written AND the host projects dir created for the share.
PERSIST_HOME="$WORK/persist-home"
mkdir -p "$PERSIST_HOME"
SEED="$(HOME="$PERSIST_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 CCVM_PERSIST_PROJECTS=1 run)/seed"
[[ "$(cat "$SEED/persist-claude-projects" 2>/dev/null)" == 1 ]] &&
  ok "persist: CCVM_PERSIST_PROJECTS=1 writes the persist marker" ||
  no "persist: opt-in did not write the marker"
[[ -d "$PERSIST_HOME/.claude/projects" ]] &&
  ok "persist: host ~/.claude/projects created for the writable share" ||
  no "persist: host projects dir not created"
# With persist on, the ccvm-context memory note flips to "memory survives".
grep -q 'PERSIST to the host this run' "$SEED/claude-md" 2>/dev/null &&
  ok "persist: claude-md tells the agent memory survives when persist is on" ||
  no "persist: claude-md memory note did not flip for the persist-on run"

# ===========================================================================
# 11. ccvm's own --ccvm-help / --ccvm-version: handled by the wrapper (printed
#     and exited before any VM work), while bare --help/--version pass through
#     to claude verbatim (transparent passthrough).
# ===========================================================================
VOUT="$(HOME="$FAKE_HOME" run --ccvm-version)"
[[ "$VOUT" == "ccvm 0.0.0-test" ]] &&
  ok "--ccvm-version prints the baked version and exits" ||
  no "--ccvm-version wrong output (got '$VOUT')"

HOUT="$(HOME="$FAKE_HOME" run --ccvm-help)"
if grep -q '^Usage: ccvm' <<<"$HOUT" && grep -q -- '--ccvm-version' <<<"$HOUT" &&
  grep -q -- '--shell' <<<"$HOUT"; then
  ok "--ccvm-help prints ccvm's own usage and flags"
else
  no "--ccvm-help output missing usage/flags"
fi

# Passthrough guard: bare --version / --help are NOT intercepted — they must reach claude's
# argv unchanged (otherwise ccvm would shadow claude's own help/version).
SEED="$(HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 run --version)/seed"
mapfile -t -d "" GOT <"$SEED/claude-args"
if [[ " ${GOT[*]} " == *" --version "* ]]; then
  ok "bare --version is forwarded to claude (not consumed by ccvm)"
else
  no "bare --version was not forwarded to claude: ${GOT[*]@Q}"
fi

# ===========================================================================
# 12. vmDiskSize: the opt-in encrypted disk pool stages a SPARSE raw image in a
#     disk-backed dir + a seed marker; the LUKS key is guest-only (never in the
#     seed); default off stages nothing; a non-integer size is rejected pre-boot.
# ===========================================================================
# Default (baked VMDISKSIZE=0): no marker, no image.
SEED="$(HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 run)/seed"
[[ ! -e "$SEED/vm-disk" ]] &&
  ok "vmDiskSize: default off stages no disk marker" ||
  no "vmDiskSize: disk marker present without opt-in"

# Opt in via the env override (1 GiB). Point the image dir at a known location and allow tmpfs
# (the test tree may sit on tmpfs in the nix sandbox; the guard is exercised separately below).
SCRATCHDIR="$WORK/scratchdir"
mkdir -p "$SCRATCHDIR"
SEED="$(HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 \
  CCVM_VM_DISK_SIZE=1 CCVM_SCRATCH_DIR="$SCRATCHDIR" CCVM_SCRATCH_ALLOW_TMPFS=1 run)/seed"
[[ "$(cat "$SEED/vm-disk" 2>/dev/null)" == 1 ]] &&
  ok "vmDiskSize: CCVM_VM_DISK_SIZE=1 writes the disk marker" ||
  no "vmDiskSize: opt-in did not write the marker"

IMG="$(find "$SCRATCHDIR" -maxdepth 1 -name 'vmdisk-*.img' 2>/dev/null | head -1)"
if [[ -n "$IMG" && -f "$IMG" ]]; then
  ok "vmDiskSize: a sparse disk image was created in the disk-backed dir"
  apparent="$(stat -c %s "$IMG" 2>/dev/null || echo 0)"
  [[ "$apparent" == 1073741824 ]] &&
    ok "vmDiskSize: image apparent size == 1 GiB" ||
    no "vmDiskSize: image apparent size wrong (got $apparent, want 1073741824)"
  # Sparse: it must not have actually allocated 1 GiB of blocks (du reports allocated KiB).
  allocated_kb="$(du -k "$IMG" 2>/dev/null | cut -f1)"
  [[ "${allocated_kb:-999999}" -lt 1024 ]] &&
    ok "vmDiskSize: image is sparse (allocated ${allocated_kb:-?}KiB ≪ 1 GiB apparent)" ||
    no "vmDiskSize: image not sparse (allocated ${allocated_kb}KiB)"
else
  no "vmDiskSize: no disk image created in $SCRATCHDIR"
fi

# The LUKS key is generated IN THE GUEST and never crosses 9p, so no key material is ever in
# the seed. (There is nothing host-side that could carry it; assert defensively anyway.)
if [[ -z "$(find "$SEED" -name '*.key' 2>/dev/null)" ]]; then
  ok "vmDiskSize: no key file staged into the seed (key is guest-only)"
else
  no "vmDiskSize: a key file LEAKED into the seed"
fi

rm -f "$SCRATCHDIR"/vmdisk-*.img

# A non-integer value is rejected before boot (a typo must not silently disable the disk).
if HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 CCVM_VM_DISK_SIZE=lots \
   CCVM_SCRATCH_ALLOW_TMPFS=1 run >/dev/null 2>&1; then
  no "vmDiskSize: invalid size 'lots' was not rejected"
else
  ok "vmDiskSize: invalid size is rejected"
fi

# NOTE: nix.substituters / nix.trustedPublicKeys (the successor to the removed
# nix.useHostStoreAsCache) are pure guest-closure config — they bake into the guest's nix.conf and
# touch nothing host-side (no seed marker, no 9p share, no staged secret), so there is nothing to
# assert here. The guest-side plumbing is covered by tests/boot.sh (the nixSubst posture).

# ===========================================================================
# 13. acceleration: the declarative mode (auto|kvm|tcg) baked from `acceleration`,
#     overridable per-run by CCVM_ACCEL. The wrapper records the resolved
#     `<mode> <accel> <cpu>` in seed/accel under dry-run; CCVM_KVM_DEV (internal
#     seam) simulates /dev/kvm states so these run identically on any host.
# ===========================================================================
FAKE_KVM="$WORK/fake-kvm" # a writable stand-in => "KVM usable"; /nonexistent => "unusable"
: >"$FAKE_KVM"

# Baked default is auto. KVM usable -> kvm:tcg + cpu max (so QEMU's runtime fallback stays valid).
SEED="$(HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 CCVM_KVM_DEV="$FAKE_KVM" run)/seed"
[[ "$(cat "$SEED/accel" 2>/dev/null)" == "auto kvm:tcg max" ]] &&
  ok "acceleration: default auto + usable KVM -> kvm:tcg, cpu max" ||
  no "acceleration: auto/usable resolved wrong: '$(cat "$SEED/accel" 2>/dev/null)'"

# auto + unusable KVM -> falls back to tcg, no error (friction-free first run).
SEED="$(HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 CCVM_KVM_DEV=/nonexistent run)/seed"
[[ "$(cat "$SEED/accel" 2>/dev/null)" == "auto tcg max" ]] &&
  ok "acceleration: auto + no KVM -> tcg fallback (no error)" ||
  no "acceleration: auto fallback resolved wrong: '$(cat "$SEED/accel" 2>/dev/null)'"

# kvm mode + usable -> kvm + cpu host, no TCG fallback.
SEED="$(HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 CCVM_ACCEL=kvm CCVM_KVM_DEV="$FAKE_KVM" run)/seed"
[[ "$(cat "$SEED/accel" 2>/dev/null)" == "kvm kvm host" ]] &&
  ok "acceleration: kvm mode + usable -> kvm, cpu host (no fallback)" ||
  no "acceleration: kvm/usable resolved wrong: '$(cat "$SEED/accel" 2>/dev/null)'"

# kvm mode + UNusable -> hard error naming KVM (no silent fallback).
if OUT="$(HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 CCVM_ACCEL=kvm CCVM_KVM_DEV=/nonexistent run 2>&1)"; then
  no "acceleration: kvm mode did not error on an unusable /dev/kvm"
elif grep -qi 'kvm' <<<"$OUT"; then
  ok "acceleration: kvm mode hard-errors with a KVM reason when unusable"
else
  no "acceleration: kvm-mode error lacked a KVM reason: $OUT"
fi

# tcg mode -> tcg + cpu max, never consults /dev/kvm (unusable device, still tcg).
SEED="$(HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 CCVM_ACCEL=tcg CCVM_KVM_DEV=/nonexistent run)/seed"
[[ "$(cat "$SEED/accel" 2>/dev/null)" == "tcg tcg max" ]] &&
  ok "acceleration: tcg mode -> tcg, cpu max (ignores /dev/kvm)" ||
  no "acceleration: tcg resolved wrong: '$(cat "$SEED/accel" 2>/dev/null)'"

# Invalid CCVM_ACCEL -> die with usage (consistent with kvm's erroring).
if OUT="$(HOME="$FAKE_HOME" CCVM_SHARE_CLAUDE_CONFIG=0 CCVM_ACCEL=bogus run 2>&1)"; then
  no "acceleration: invalid CCVM_ACCEL was not rejected"
elif grep -qi "must be 'auto', 'kvm', or 'tcg'" <<<"$OUT"; then
  ok "acceleration: invalid CCVM_ACCEL rejected with usage"
else
  no "acceleration: invalid CCVM_ACCEL error unclear: $OUT"
fi

rm -f "$FAKE_KVM"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
