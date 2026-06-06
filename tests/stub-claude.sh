# Stub `claude` for ccvm boot tests (tests/boot.sh): instead of the real agent, print
# exactly what the guest sees so the host can assert on it, then exit. No API calls.
echo "CCVM_BOOT_MARKER"
echo "ARGV:$*"
echo "CWD:$PWD"
# Try to write into the workspace (the guest CWD == the host project path). In rw mode this
# reaches the host; in overlay mode it lands in the tmpfs upper and never does.
if echo "guest-wrote-$$" >./ccvm-boot-write 2>/dev/null; then
  echo "WRITE:ok"
else
  echo "WRITE:denied"
fi
# Report host-config visibility (only present when shareHostConfig is on and the host has it).
[ -r "$HOME/.claude/settings.json" ] && echo "CONFIG:settings-readable"
[ -e "$HOME/.claude/.credentials.json" ] && echo "CONFIG:credential-present"
