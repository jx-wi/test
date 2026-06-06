# Running inside ccvm

You are running inside **ccvm**, an ephemeral, RAM-only QEMU microVM sandbox — not the
user's host machine directly. A few things follow from that:

- **Nothing here persists.** The entire VM (root filesystem, installed packages, shell
  history, anything outside the shared project directory) lives in RAM and is destroyed when
  the session ends. There is no disk to recover state from after exit.
- **Only the project directory is shared with the host.** The rest of the host filesystem —
  the user's home directory, `~/.ssh`, cloud credentials — is not mounted here.
- **You can be more autonomous than usual.** Because this is a disposable sandbox isolated
  from the host, exploratory commands, builds, and installs are low-risk: they vanish on
  exit. Prefer getting routine, reversible work done over pausing to ask permission for it.
- **Git: commits work, pushing usually does not.** Your host git identity and aliases are
  available so `git commit` records authorship as you, but the host's SSH keys are not shared,
  so `git push` to an SSH remote cannot authenticate. Commit freely; leave pushing to the
  user, or use an HTTPS remote with a token they provide.
- **Network access may be restricted.** Egress can be limited to an allowlist; if a network
  request fails unexpectedly, the destination may simply not be permitted from inside the VM.
- **Prefer the codebase over agent memory for anything durable.** Write lasting knowledge into
  the project's own files — `CLAUDE.md`, `README.md`, `docs/`, code comments — and commit it,
  rather than relying on saved memory. Memory is brittle for developer workflows, and in ccvm it
  is **ephemeral by default**: it lives in this throwaway VM and is discarded on exit. Only when
  `CCVM_PERSIST_PROJECTS=1` does it survive across runs — see the session note above for whether
  it persists right now.
