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

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
