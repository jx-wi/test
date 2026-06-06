# ccvm — pre-public TODO

Working list of security / devex / UX items to clear before making the repo public,
derived from a 2026-06-06 review. We work through it **one item at a time**. Status
legend: ✅ done · 🟡 in progress / pending verification · ⬜ not started · 💭 design only.

---

## Start here (orientation for a fresh agent)

**What ccvm is:** a wrapper that runs Claude Code inside an ephemeral, RAM-only QEMU microVM
with native-terminal fidelity. Read these first, in order:

1. `CLAUDE.md` — the operational working agreement: security invariants that must not regress,
   deliberate defaults, build/test/debug, and the expensive-to-rediscover gotchas. **Most
   important file.**
2. `README.md` — user-facing behaviour, options, the threat model.
3. `docs/design.md` — the *why* behind every decision (numbered §3.x).
4. `tests/` — what's verified and how (`host.sh` host-side, `boot.sh` full-boot).

**This file (`TODO.md`) is the portable source of truth for in-flight work** — the `~/.claude`
memories are machine-local and do **not** travel with a `git clone`, so trust this over any
half-remembered context.

## Current state (keep this updated)

- **Branch `main`:** item #1 merged. **Working tree is intentionally dirty** — uncommitted:
  the `CCVM_MEMORY` per-run override (`wrapper/ccvm.sh`, `modules/home-manager.nix`,
  `README.md`, `tests/host.sh`), item #3's dead-option removal (`guest/default.nix`,
  `lib/mkccvm.nix`), item #4's uid auto-remap (`wrapper/ccvm.sh`, `guest/launcher.nix`,
  `guest/default.nix`, `docs/design.md`, `tests/host.sh`, `tests/boot.sh`,
  `tests/stub-claude.sh`), item #6's TCG `wait_for_boot` timeout + boot-test hardening
  (`wrapper/ccvm.sh` `wait_for_boot`, `tests/boot.sh` `run_capture`, `tests/stub-claude.sh`
  `exit 0`), **and this `TODO.md`**. Not a mistake; not yet committed because the user hadn't
  asked. Commit on `main` or a small branch when directed.
- **Branch `egress-allowlist`:** item #2 (the egress allowlist), committed there, **not merged**
  — it diverges from `main` and is blocked on Nix+KVM verification (see #2).
- **No git remote** is configured: every merge so far is local-only (see #5).
- **`host.sh` assertion counts differ by branch** (the file diverged): committed `main` = 13;
  `main` working tree (with `CCVM_MEMORY` + #4 uid/gid) = **17**; `egress-allowlist` = **14**
  (adds the default-open assertion); they reconcile to 18 once #2 merges.
- **Next item: #5** (replace `jx-wi` placeholders + add a git remote) — fully doable on this
  box, but needs the user to confirm the real GitHub org/identity first.

## Working on this box without Nix (the key recipe)

The dev box has **no `nix` CLI and no KVM** (stripped NixOS, 2 GB tmpfs root), so `nix flake
check` / `nix build` / `tests/boot.sh` **cannot run here**. But the host-side guarantee tests
*can*, by hand-substituting the wrapper's `@TOKENS@` and running `tests/host.sh` against the
result — this is how every host-side change in this list was verified:

```sh
WRAP=$(mktemp -d)/ccvm
{ printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  sed -e 's#@KERNEL@#/dev/null#g' -e 's#@INITRD@#/dev/null#g' -e 's#@STOREIMG@#/dev/null#g' \
      -e 's#@APPEND@#console=ttyS0#g' -e 's#@MEMORY@#4096#g' -e 's#@CORES@#4#g' \
      -e 's#@MODE@#rw#g' -e 's#@APIKEYVAR@#ANTHROPIC_API_KEY#g' -e 's#@SHARECONFIG@#1#g' \
      -e 's#@MOUNTHOSTSTORE@#0#g' -e 's#@HOSTSTOREPATH@#/nix/store#g' -e 's#@QEMU@#true#g' \
      -e 's#@DEFAULTMACHINE@#microvm#g' -e 's#@MEMLOCK@#0#g' wrapper/ccvm.sh
} > "$WRAP"; chmod +x "$WRAP"
CCVM="$WRAP" bash tests/host.sh        # add -e 's#@EGRESSALLOW@##g' -e 's#@EGRESSPORTS@#443#g' on the egress branch
```

The dry-run hook (`CCVM_DRYRUN=1`, which `host.sh` sets) makes the wrapper populate the seed
and run the real config-staging loop, then stop before booting and print the scratch dir.
`bash -n` the wrapper/scripts to lint without shellcheck. Always note clearly which guarantees
remain **unverified here** (Nix eval, real VM boot) so they get checked on a capable box.

> **Verification constraint (summary):** host-side shell logic → verified here via the dry-run
> tests; anything needing Nix eval or a real VM boot → must be verified on a Nix+KVM machine
> before merge. See `tests/` and the README "Verifying it yourself" section.

---

## 1. ✅ Tests + CI backing the "checked automatically" claims — DONE (`main`)

**Problem:** README/design claimed automated security tests + a "CI-built target" that did
not exist (`nix flake check` only built the image and shellchecked the wrapper).

**Done:**
- `CCVM_DRYRUN` hook in the wrapper: runs every host-side step (key gen, seed population,
  the real config-staging loop, QEMU-arg assembly) then stops before booting and prints
  the scratch dir — makes the security-critical host path testable with no VM, no claude-code.
- `tests/host.sh` (15 assertions via dry-run): API key never in the seed; OAuth credential
  never staged (top-level + nested); escaping host-config symlinks dereferenced; verbatim
  NUL-separated argv; ccvm-only flag consumption + mode selection; `CCVM_MEMORY` validation;
  `SendEnv`-not-`SetEnv`. Wired into `nix flake check` via `tests/default.nix` against a
  dummy-token wrapper (no guest build).
- `tests/boot.sh` + `stub-claude.sh` + `boot.nix`: full-boot smoke test (stub claude, TCG by
  default) for argv-reaches-claude and overlay-vs-rw file visibility.
- `.github/workflows/check.yml`: `nix flake check` on push/PR.
- README/design/CLAUDE.md rewritten to describe the three coverage tiers (CI host-side /
  local boot / human fidelity).

Merged to `main` (local; no git remote configured yet — see #5).

---

## 2. 🟡 Default-mode credential-exfil tradeoff + egress allowlist — IMPLEMENTED, on branch `egress-allowlist`, NOT merged

**Problem (the block):** in the default posture (`shareHostConfig=true` + `autoUpdateFiles=true`
+ open egress, all defaults), the host OAuth credential is readable by the agent inside the VM
and the network is wide open — a prompt-injected/compromised agent could exfiltrate the project
tree or that credential. The VM still can't touch the host FS, but containment ≠ exfil-proof.

**Design decision:** "most secure without compromising native devex/ux" ⇒ the default **must**
stay open-egress (native mirroring is a locked invariant), so the fix is an **opt-in,
default-open** egress allowlist (design §3.10 MVP) + honest documentation of the default tradeoff.

**Done on branch `egress-allowlist`:**
- Options `programs.ccvm.egressAllowlist` (FQDN/IP/CIDR; empty = open, the default) and
  `egressPorts` (`[443]`), baked into the wrapper as `@EGRESSALLOW@`/`@EGRESSPORTS@`.
- Wrapper resolves FQDNs host-side at launch (host has DNS), passes IPs/CIDRs verbatim, always
  auto-includes `api.anthropic.com` so auth can't break, writes the resolved set + nft port list
  to the seed.
- Guest `ccvm-seed.service` applies a **default-deny** nftables OUTPUT chain (allowlist + loopback
  + conntrack replies so inbound ssh survives + DNS + DHCP renewal). `nft -f` is atomic, so on
  failure it **fails closed** (bare deny-all) rather than leave egress open. `modprobe
  nf_tables nf_conntrack` first.
- Tests: `tests/egress.sh` (host-side staging — verbatim IP/CIDR, FQDN resolution, ports) in
  `nix flake check`; `host.sh` asserts default = open; `boot.sh` + stub probe real enforcement.
- Docs: README "Threat model & network egress" section (default tradeoff + mitigations: API-key
  auth, `egressAllowlist`, `autoUpdateFiles=false`); design §3.10 rewritten "planned → implemented
  (opt-in MVP)"; SNI-proxy noted as the stronger future layer.

**Blocked on:** `nix flake check` (eval — `pkgs.getent` etc.) and `tests/boot.sh` (real
packet-drop) on a Nix+KVM box. Host-side staging tests pass locally. **Do not merge until both
are green.** To land: `git checkout egress-allowlist && nix flake check && bash tests/boot.sh`.

---

## 3. ✅ Dead `shareHostConfig` guest option — DONE (`main` working tree)

`guest/default.nix` declared `ccvm.shareHostConfig` but **nothing in the guest read it** — the
wrapper does all the sharing work and the guest keys off `seed/share-config`. It was a misleading
option that looked load-bearing.

**Done:**
- Removed the `shareHostConfig` option from `guest/default.nix` (replaced with a NOTE comment
  pointing at the real flow: wrapper → `seed/share-config` → `launcher.nix`).
- Stopped passing it into the guest module from `lib/mkccvm.nix` (the `inherit (config) …` list).
- **Left untouched** the genuinely load-bearing host-side path: the home-manager
  `programs.ccvm.shareHostConfig` user option → `mkccvm` `config.shareHostConfig` →
  baked `@SHARECONFIG@` in the wrapper. That is the real default knob.

Pure removal of a dead/unread option — no behaviour change. Verified by inspection +
`grep`: the only surviving `shareHostConfig` references are the host-side default chain.
**Unverified here** (no Nix CLI on this box): `nix flake check` guest eval — should be a
no-op since the option had no readers, but confirm green on a Nix box before relying on it.

---

## 4. ✅ Hardcoded guest uid 1000 — DONE (`main` working tree)

The guest `ccvm` user is uid 1000 and rw-mode relies on 9p `security_model=none` passthrough, so
a host user whose uid ≠ 1000 got workspace files created as uid 1000 (wrong ownership / read
errors on their own files).

**Fix chosen — runtime auto-remap** (most secure *and* best devex: zero config, works for any
host uid, no rebuild, no new attack surface — just maps the agent user to the host uid via
non-secret integers on the read-only seed). Rejected the build-time `@TOKEN@`/option route (it
needs user action + a guest rebuild and doesn't auto-fix) and document-only (leaves the bug).

**Done:**
- `wrapper/ccvm.sh` stages `id -u`/`id -g` into the seed (`host-uid`/`host-gid`).
- `guest/launcher.nix` `ccvm-seed-setup` (runs Before=sshd) remaps the `ccvm` user/group to the
  host ids with `usermod`/`groupmod` **before** the workspace/config setup, so every later
  `chown ccvm` and the login session use the right ids; re-owns `/home/ccvm`. Added `pkgs.shadow`
  + `pkgs.gnugrep` to its runtimeInputs. Best-effort + fail-open: missing/garbage/root id, or a
  hiccup, keeps uid 1000 rather than failing the oneshot and blocking sshd.
- Docs: `docs/design.md` §3.x rw-passthrough bullet rewritten; `guest/default.nix` user comment
  updated.

**Verified here:** `tests/host.sh` now 17/17 (added 2: host-uid/host-gid staged into the seed),
run via the dry-run recipe; remap guard logic exercised standalone across uid shapes
(NixOS-1000 no-op, non-NixOS remap, macOS 501, root/garbage/missing → fail-open).
**Verified on a Nix+KVM box** (2026-06-06): `nix build -f tests/boot.nix` green and
`bash tests/boot.sh` **7/7** including the two new assertions (agent `id -u` == host uid;
the host file the agent wrote is owned by the host user). NOTE: that box's host uid is 1000,
so the boot test exercises the *no-op* path (1000 == baked 1000), not the live `usermod`
remap branch — the remap branch remains covered only by the standalone logic test above. To
exercise it for real, run `bash tests/boot.sh` as a host user whose uid ≠ 1000.

---

## 5. ⬜ Replace `jx-wi` placeholders — MEDIUM

`jx-wi` appears in `flake.nix`, `README.md` (×4), `LICENSE`. Confirm the real GitHub
org/identity before anyone `nix run github:jx-wi/ccvm` (currently a dead URL). Also unblocks
adding a real **git remote** + PR flow — there is **no remote configured** today, so all merges
so far are local-only.

---

## 6. 🟡 Smaller polish — LOW (2 of 3 done)

- ⬜ `ccvm --ccvm-help` / `--version`: ccvm's own flags (`--shell`, `--ccvm-debug`,
  `--auto-update-files`, `--no-auto-update-files`) are undiscoverable — `--help` forwards to
  claude's help.
- ✅ **Longer `wait_for_boot` timeout under TCG — DONE.** `wait_for_boot` now scales its cap
  by accel: KVM keeps the snappy 120×0.3s (~36 s), TCG gets 600×0.3s (~180 s); `CCVM_BOOT_TRIES`
  overrides. This was a real silent-failure source: a cold TCG boot on a busy box exceeded the
  old ~36 s cap → `die "boot failed"`. **Also hardened `tests/boot.sh`:** `run_capture` no
  longer swallows the wrapper's stderr under `2>/dev/null` + `set -e` (which turned any boot
  failure into a mute non-zero exit — cost real debugging time); it captures the true exit code
  and dumps the wrapper stderr on failure. **And fixed `tests/stub-claude.sh`** to `exit 0`:
  its last diagnostic `[ -e …credentials… ]` returned non-zero when config wasn't shared, and
  the wrapper propagates the remote exit code, so a clean run looked like a failure. Verified:
  `bash tests/boot.sh` 7/7 clean on the Nix+KVM box.
- ⬜ Dedupe default values between `lib/mkccvm.nix` `defaults` and `modules/home-manager.nix`
  option defaults (two sources of truth for `memory`/`cores`/`shareHostConfig`/… → drift risk).

---

## 7. ⬜ git identity passthrough + the `git push` export story — NEW

`~/.gitconfig` is not passed through (only the CWD crosses the boundary), so in-VM `git commit`
fails without repo-local identity. Worse, `~/.ssh` is **deliberately** unshared, yet the docs tell
you to "export via `git push`" in overlay mode — which can't authenticate to an SSH remote.
**Action:** reconcile. Options: stage a minimal identity (`user.name`/`user.email`) from host
gitconfig via the seed; document an HTTPS-token push path; or surface the limitation clearly.
Pairs with #4 (both are host-identity boundary issues) and #8 (the default blurb is the natural
place to tell the agent how to handle commits given no identity).

---

## 8. ⬜ `extraClaudeMd` / `extraContext` option — NEW

A `programs.ccvm.*` string injected into the guest so the agent knows it's running inside ccvm
(ephemeral isolation) and adapts behaviour — e.g. git-commit guidance, knowing overlay edits are
ephemeral, that it can be more autonomous because it's sandboxed.

**Design note:** prefer staging it as the guest's `~/.claude/CLAUDE.md` (global memory) **via the
seed** over injecting a `--append-system-prompt` flag — that keeps the transparent-passthrough
invariant intact (the wrapper still adds no flags to claude's argv). Ship a sensible default
blurb, user-extendable. Interacts with #7.

Example intent:

```nix
programs.ccvm.extraClaudeMd = ''
  You are running inside `ccvm`, an ephemeral isolation microVM. Edits to the project are
  <live on the host | discarded on exit>, and there is no persistent disk. When you make git
  commits, <do xyz — e.g. note the ccvm provenance / skip signing>.
'';
```

---

## 9. ⬜ Loading & status indicators during boot/wait — NEW

The wrapper is silent through `wait_for_boot` (slow under TCG — looks hung). Add a spinner
(ASCII `\ | / -` or braille `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) plus status text ("booting microVM…", "waiting for
guest sshd…", "connecting…").

**Constraints:** only animate when **stderr is a TTY**; clear the line before handing the terminal
to `ssh -tt`/the TUI (same discipline as the existing debug-tail kill); must **not** fire under
`CCVM_DRYRUN`, in tests, or when output is redirected (it would corrupt the dry-run/test captures).

---

## 10. 💭 Encrypted ephemeral scratch disk (FDE) for large writable data — NEW (design)

**Problem:** the RAM-only model breaks for big **writable** data — `nix develop` realising an 8 GB
closure, large `node_modules`/`target`/`.venv`, build outputs. tmpfs OOMs at `memory=4096`, and
`/nix/store` is a read-only squashfs so you can't `nix build`/`nix develop` into it at all.

**Plan (keeps wipe-on-exit):**
- Host attaches a raw **sparse** image as a `virtio-blk` device from a **disk-backed** `scratchDir`
  (NOT `XDG_RUNTIME_DIR`, which is usually tmpfs!) with a `diskSize` cap (sparse → only consumes
  what's written).
- Guest generates a LUKS key from `/dev/urandom` — **the key never crosses 9p; the host only ever
  sees ciphertext** (stronger than passing it via the seed; same spirit as "API key lives only in
  guest RAM"). `cryptsetup luksFormat` fresh **every boot**, then mount as the encrypted overlay
  **upper** over the ro squashfs `/nix/store` (writable store) and/or a generic scratch.
- **Wipe-on-exit is preserved cryptographically:** the key dies with guest RAM → the on-disk image
  is inert even on a crash that skips cleanup; the trap still `rm`s the image (belt + suspenders).
  FDE is load-bearing here because plain delete ≠ erasure on SSD/CoW (TRIM async, snapshots).

**Decisions to make:**
- **Scope:** writable encrypted `/nix/store` **+ enable `nix` in the guest** (true in-VM `nix
  develop`; guest currently sets `nix.enable = false`) — vs. a generic encrypted scratch only,
  leaving the store read-only.
- **Default:** off by default (pure-RAM stays the default, boot stays fast); opt in via something
  like `storeDisk = "16G"`.

**Complementary to `mountHostNixStore`:** if the 8 GB is already realised in the **host** store,
`mountHostNixStore = true` exposes it read-only at zero RAM cost — no new disk needed. The
encrypted disk is specifically for when the guest must **write** a large closure ephemerally.

**Status:** design only. Needs `cryptsetup` in the guest + initrd; unbuildable/untestable without
Nix+KVM. To be captured as a `design.md` §3.x section.

---

### Cross-cutting notes

- **No git remote yet** (#5): every merge is local. The egress feature (#2) sits on an unmerged
  branch precisely so an unverified Nix-eval typo can't break `main`'s CI.
- **Commit trailer:** `Co-authored-by: Claude <noreply@anthropic.com>` (exact form; see CLAUDE.md).
- **Recently done, not a blocker:** `CCVM_MEMORY=<MiB>` per-run guest-RAM override (wrapper + docs
  + `host.sh` tests). The `memory` home-manager option already existed (default 4096); the new bit
  is the env override for heavy `nix develop` closures (ties into #10).
