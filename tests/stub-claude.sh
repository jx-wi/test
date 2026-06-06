# Stub `claude` for ccvm boot tests (tests/boot.sh): instead of the real agent, print
# exactly what the guest sees so the host can assert on it, then exit. No API calls.
echo "CCVM_BOOT_MARKER"
echo "ARGV:$*"
echo "CWD:$PWD"
# The agent's uid: the guest remaps the ccvm user to the host uid so 9p passthrough gives
# correct workspace ownership. The host asserts this equals its own `id -u`.
echo "UID:$(id -u)"
# Try to write into the workspace (the guest CWD == the host project path). In rw mode this
# reaches the host; in overlay mode it lands in the tmpfs upper and never does.
if echo "guest-wrote-$$" >./ccvm-boot-write 2>/dev/null; then
  echo "WRITE:ok"
else
  echo "WRITE:denied"
fi
# Report host-config visibility (only present when shareClaudeConfig is on and the host has it).
[ -r "$HOME/.claude/settings.json" ] && echo "CONFIG:settings-readable"
[ -e "$HOME/.claude/.credentials.json" ] && echo "CONFIG:credential-present"

# ccvm-context global memory (extraClaudeMd): should be laid at ~/.claude/CLAUDE.md, carrying
# the baked blurb and the runtime mode line. Report so boot.sh can assert it survived a boot.
if [ -r "$HOME/.claude/CLAUDE.md" ]; then
  echo "CLAUDEMD:present"
  grep -q 'inside .*ccvm' "$HOME/.claude/CLAUDE.md" 2>/dev/null && echo "CLAUDEMD:blurb"
  grep -q 'LIVE to the host' "$HOME/.claude/CLAUDE.md" 2>/dev/null && echo "CLAUDEMD:mode-rw"
else
  echo "CLAUDEMD:absent"
fi

# Git config passthrough (shareGitConfig): the guest should see the host identity, with the
# host-only /nix/store tool paths and credentials stripped and signing disabled. Report what
# actually landed so boot.sh can assert the sanitization survived a real boot.
if [ -r "$HOME/.config/git/config" ]; then
  echo "GIT:config-present"
  echo "GITNAME:$(git config --get user.name 2>/dev/null)"
  if grep -q '/nix/store' "$HOME/.config/git/config"; then
    echo "GIT:storepath-leaked"
  else
    echo "GIT:sanitized"
  fi
  echo "GITSIGN:$(git config --get commit.gpgsign 2>/dev/null)"
else
  echo "GIT:config-absent"
fi
[ -r "$HOME/.config/git/ignore" ] && echo "GIT:ignore-present"
# Egress probes (best-effort, short timeout). With open egress both reach; with the
# example.com allowlist only the allowed host reaches and the other is blocked. boot.sh
# asserts on these only in the egress scenario.
probe() { # $1=url $2=label
  if curl -sS --max-time 8 -o /dev/null "$1" 2>/dev/null; then
    echo "EGRESS:$2:reachable"
  else
    echo "EGRESS:$2:blocked"
  fi
}
probe https://example.com/ allowed
probe https://1.1.1.1/ denied

# Exit cleanly: the diagnostic probes/tests above must not leak a non-zero status to the
# wrapper (which propagates the remote exit code) — that would look like a boot/session
# failure when the run was fine. The real claude returns 0 on a normal exit; mirror that.
exit 0
