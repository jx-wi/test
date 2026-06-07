# CLAUDE.md

Working agreement for agents and contributors on **ccvm** — run Claude Code in an
ephemeral, RAM-only QEMU microVM with native-terminal fidelity. User docs live in
[README.md](README.md); the full rationale is in [docs/design.md](docs/design.md). This
file is the operational distillation: the rules that must not regress and the traps that
cost time to rediscover.

## Repo map

| Path | Role |
|---|---|
| `flake.nix` | Outputs: `packages.*.ccvm`, `homeManagerModules.default`. |
| `lib/mkccvm.nix` | The builder. Evaluates the guest NixOS system, then bakes its boot artifacts + scalar config into the wrapper via `builtins.replaceStrings` `@TOKENS@`. |
| `wrapper/ccvm.sh` | Host wrapper **template** (the `@TOKEN@` placeholders). Generates throw-away SSH keys, writes the seed, boots QEMU headless, `ssh -tt`s in, traps cleanup. |
| `guest/default.nix` | The microVM NixOS guest (tmpfs root, ro squashfs `/nix/store`). |
| `guest/launcher.nix` | Two units. `ccvm-seed.service` (root oneshot, `Before=sshd`) installs the pinned host key + `authorized_keys` and does every 9p/overlay mount. `ccvm-guest-launch` is the **unprivileged** sshd `ForceCommand` that just `cd`s to the workspace and execs claude (or zsh). |
| `guest/sshd.nix` | Hardened sshd: key-only, no root, single `ForceCommand`. |
| `modules/home-manager.nix` | `programs.ccvm.*` options → installs the command. |
| `tests/` | `host.sh` (CI host-side guarantees via the `CCVM_DRYRUN` hook), `boot.sh`+`stub-claude.sh`+`boot.nix` (local full-boot smoke test), `default.nix` (wires `host.sh` into `nix flake check`). |

## Security invariants — MUST NOT regress

These are the whole point of the project. Treat any change that weakens one as a bug.

- **API key never touches disk/argv/kernel-cmdline.** It travels only over the SSH channel
  via `SendEnv`→`AcceptEnv`. Use `SendEnv`, **never** `SetEnv` (SetEnv puts it on the
  remote command line).
- **Host key is pinned.** Ephemeral ed25519 keys per run, `StrictHostKeyChecking=yes`.
  Never disable host-key checking to "make it work."
- **`shareClaudeConfig` never leaks the OAuth credential.** `~/.claude/.credentials.json`
  must ride the **read-only 9p mount** only — never copied into the scratch/seed dir. Only
  the non-secret `~/.claude.json` is staged through the seed. The config-deref staging loop
  selects `find -type l` and skips `.credentials.json` by name; keep both guards. Verify by
  running the staging loop standalone and grepping the seed dir for the credential — expect
  zero hits. **`persistClaudeProjects` (opt-in) does not change this:** it mounts only
  `~/.claude/projects` read-write; the credential lives at the `~/.claude` *root*, not under
  `projects/`, so it is never in that share. Never widen the writable mount to all of `~/.claude`.
- **`shareGitConfig` stages only sanitized, non-secret git config.** The wrapper resolves the
  **global** git config host-side and writes `seed/gitconfig` only after dropping every value
  containing `/nix/store/` (host-only tool paths that would dangle) and **all `credential.*`
  entries** (no host credential — `~/.ssh`, `gh` token — ever crosses), force-disabling commit/
  tag signing, and staging `core.excludesfile` by *content*. Keep all four guards. Verify by
  grepping the seed for any `/nix/store` path or `credential` key — expect zero hits.
- **No persistent disk.** Root is tmpfs; the store is a read-only image. Nothing the agent
  does survives exit except host-project edits while `autoUpdateFiles=true` — and, when the
  opt-in `persistClaudeProjects` is on, writes under `~/.claude/projects` (session transcripts
  + memory). Both are deliberate, narrowly-scoped write-throughs, not a general persistent disk.
  The opt-in `vmDiskSize` disk pool is **not** an exception: it is an *ephemeral* disk, wiped on
  exit (see next bullet). `/home` and root deliberately stay tmpfs, so secrets never go on the disk.
- **`vmDiskSize` pool: the LUKS key is guest-only, the disk is wiped on exit.** The host attaches
  a sparse image but **never** the key — the guest generates it from `/dev/urandom` in its own RAM
  and `luksFormat`s the device fresh every boot, so the host only ever sees ciphertext (verify: no
  key file in the seed; the wrapper writes only the `vm-disk` marker, never the key). Wipe-on-exit
  is cryptographic (the key dies with guest RAM → inert ciphertext even on a crash), with the trap
  `rm` as belt-and-suspenders. The host image MUST live in a disk-backed dir, never tmpfs/`$TMP`
  (that would put the "disk" back in RAM) — the wrapper refuses a tmpfs target unless
  `CCVM_SCRATCH_ALLOW_TMPFS=1`. The pool backs only **bulk, non-secret** data — `/scratch` and (with
  `nixInVm`) the writable `/nix/store` overlay upper, opened+mounted in the **initrd** by a fail-open
  LUKS oneshot (key still guest-only). Keep `/home`/secrets in tmpfs. Never stage the key through the seed.
- **`autoUpdateFiles=false` means genuinely read-only.** The host tree is the 9p **lower**;
  edits land in a tmpfs **upper** and must not reach the host.
- **Only the CWD is shared.** No `~/.ssh`, `~/.aws`, or home dir crosses the boundary.

## Deliberate defaults — do not reverse

- **Native mirroring is the default.** `autoUpdateFiles=true` (live host edits),
  `shareClaudeConfig=true` (reuse host `~/.claude`), and `shareGitConfig=true` (commit as you,
  with your aliases/ignores) make ccvm behave like native `claude`. Isolation (read-only
  project, no config) is the **opt-in**. Do not re-propose "secure by default" — that was the
  original spec and was deliberately reversed.
- **RAM-only is the default; the disk pool and in-VM nix are opt-in.** `vmDiskSize=0` (no disk,
  pure RAM) and `nix.enable=false` (read-only `/nix/store`, no in-VM nix, lean closure) are the
  defaults — keep boot fast and the no-disk stance unless asked. The user-facing option is
  `programs.ccvm.nix.enable`; it maps to the guest/internal build-time flag still named `nixInVm`
  (the guest closure + `lib/mkccvm.nix` use that name — don't rename it without a guest rebuild).
  It is **build-time** (it flips `nix.enable` and rebuilds the store as a writable overlay in the
  initrd) — never try to make it a runtime `CCVM_*` env var. Its overlay upper is tmpfs (RAM) by
  default; combine with `vmDiskSize>0` and an initrd LUKS oneshot relocates that upper onto the
  encrypted disk (fail-open to tmpfs), so a large `nix develop` doesn't OOM guest RAM — one shared
  pool also backs `/scratch`. **The guest always boots off the self-contained squashfs store; the
  host store is never the guest's boot store.** Reusing the host store to *accelerate* in-VM builds
  is `nix.useHostStoreAsCache` — a read-only build **substituter** (never a writable host-store
  mount), **declared but not implemented yet** (it warns at eval; design §3.11 L2 / TODO #10). The
  old `mountHostNixStore` (host store as the guest's boot store) was **deliberately removed** in
  this collapse — do not re-add it.
- **`extraClaudeMd` is default-on context, not a flag.** A built-in blurb is staged as the
  guest's `~/.claude/CLAUDE.md` (via the seed, **appended** to any host-shared one — never
  clobbering it) so the agent knows it's in ccvm. It must stay seed-delivered, never become
  `--append-system-prompt`, or it breaks transparent passthrough. The wrapper prepends a
  **runtime** mode line (rw=live / overlay=discarded) the build-time file can't know.
- **Transparent passthrough.** The wrapper injects **no** flags. Everything after `ccvm`
  is forwarded to `claude` verbatim, including `--dangerously-skip-permissions` (opt-in by
  the user, never auto-added). The *only* args the wrapper consumes (and does **not**
  forward) are its own: `--shell`, `--ccvm-debug`, `--auto-update-files`,
  `--no-auto-update-files`, `--ccvm-help`, `--ccvm-version`. They are deliberately
  `--ccvm-`/`--*-files`-namespaced so bare `--help`/`--version` still reach claude.
  Preserve that interception boundary.

## Build / test / debug

- Build the wrapper: `nix build .#ccvm`. **Iteration cost:** `memory`/`cores` are runtime
  QEMU args (cheap, no rebuild); changing `package`/`extraPackages`/`nix.enable`/guest
  modules rebuilds the guest closure.
- **Iterate fast with a stub `claude`** — the proven way to test file/config/arg behaviour
  without a real agent run. Bake a shell script as the `package` and assert on its stdout:

  ```nix
  (import ./lib/mkccvm.nix { inherit pkgs; } {
    package = pkgs.writeShellScriptBin "claude" ''
      # print what the guest sees: mount type of $HOME/.claude, is settings.json
      # readable, does it contain the expected model, is .credentials.json present, …
    '';
  }).wrapper
  ```

  Boot it under `tcg`/`q35`, grep the output. This is exactly how `shareClaudeConfig` and
  `autoUpdateFiles` were verified end-to-end — much faster than booting the real agent.
- `nix flake check` should pass. It builds the guest image, shellchecks the wrapper, and
  runs `tests/host.sh` (the `checks.<sys>.host` derivation) — host-side secret hygiene,
  config staging, verbatim argv, mode selection — against the real wrapper driven by its
  `CCVM_DRYRUN` hook (no VM, no claude-code). The `homeManagerModules`/`ccvmParts` "unknown
  flake output" warnings are pre-existing and cosmetic.
- **Full-boot smoke test:** `bash tests/boot.sh` (defaults to `CCVM_ACCEL=tcg
  CCVM_MACHINE=q35`) boots a stub-`claude` VM and asserts argv-reaches-claude and overlay
  vs. rw file visibility. This is the codified version of the stub-package boot test below.
- **Boot-testing without working KVM:** force software emulation with
  `CCVM_ACCEL=tcg CCVM_MACHINE=q35 ccvm` (slow but correct).
- `CCVM_DEBUG=1` / `--ccvm-debug` streams the guest console and keeps the scratch dir.
  `CCVM_SHELL=1` / `--shell` drops into a guest zsh instead of claude.
- **Terminal fidelity is human-verified**, not automated (`ccvm --shell`, then resize /
  vim / less / vi-mode). Don't claim it works from code inspection alone.
- **Definition of done for a behaviour change:** `nix flake check` green **and** a
  stub-package boot test asserting the new behaviour under `tcg`/`q35` — plus a human
  `--shell` pass if it touches the TTY.

## Conventions

- **Working `TODO.md`: commit automatically once all checks pass.** When working through a
  `TODO.md` item, run the relevant checks (`bash -n`, the `host.sh` dry-run recipe, and — on a
  Nix+KVM box — `nix flake check` / `bash tests/boot.sh` / a `--shell` pass for TTY changes); if
  they're green, commit without stopping to ask per item. Still surface anything that can only be
  verified on the Nix+KVM box so it gets checked there before being claimed done.
- **Commit trailer (exact):** `Co-authored-by: Claude <noreply@anthropic.com>` — lowercase
  `authored-by`, bare `Claude`, no model name. This intentionally differs from the Claude
  Code CLI default; use *this* form.
- **Config flows through `@TOKENS@`.** Scalars are baked at build time in `mkccvm.nix`
  (`@MODE@` = `rw`/`overlay`, `@SHARECLAUDE@` = `1`/`0`, etc.). Values only known at launch
  — the workspace 9p share and SSH port — are **not** baked; the wrapper builds those QEMU
  args at runtime (the microvm.nix "runtime-share trap", design §3.8).
- **Runtime override pattern:** a `CCVM_*` env var overrides the baked default for one run
  (`CCVM_AUTOUPDATE`, `CCVM_SHARE_CLAUDE_CONFIG`, `CCVM_MLOCK`); an explicit `ccvm` flag wins over
  the env var.
- **Forwarded argv is NUL-separated** on the wire (`claude-args` in the seed, read with
  `mapfile -d ""`); spaces/quotes/globs survive intact. Never rebuild the argv by
  string-splitting.
- **Nix `''` string escaping** (wrapper + guest scripts are inside `''…''`): a literal bash
  `${var}` is written `''${var}`; `$(...)` and bare `$var` pass through literally.
- `wrapper/ccvm.sh` is built via `writeShellApplication`, so **shellcheck runs at build** —
  keep it clean (and the `set -euo pipefail` it injects in mind).

## Gotchas (expensive to rediscover)

- **9p preserves symlinks verbatim.** A host symlink pointing outside the exported tree
  (home-manager links `~/.claude/settings.json` → `/nix/store/…`) **dangles** in the guest.
  Fix already in place: dereference such links host-side into the seed, then lay the real
  files over the config overlay's tmpfs upper (shadowing the dead lower symlink).
- **Overlay copy-up hazard.** Never `chown -R` an overlay root — it copies *every* lower
  file up into the tmpfs upper. Chown only the specific files you staged.
- **microvm vs q35 use different virtio transports** (`virtio-mmio`/BUS=`device` vs
  `virtio-pci`/BUS=`pci`). The wrapper derives `BUS` from the machine type; keep new
  `-device` args going through it.
- **`ssh -tt` adds a PTY**, so guest stdout gets `\r` and escape sequences. When grepping
  captured guest output, use `grep -a` and `tr -d '\r'` or matches silently fail.
