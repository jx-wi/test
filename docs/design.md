# ccvm — design notes

`ccvm` runs Claude Code inside a throw-away QEMU microVM and drops you into it in
your current terminal, so the agent operates against an isolated, RAM-only copy of
your machine instead of the real thing. When the session ends the VM's RAM is freed
and **nothing it did survives** — there is no disk to clean up.

This document explains *why* it is built the way it is. For how to use it, see the
[README](../README.md).

---

## 1. Goals

1. **Indistinguishable UX.** `cd` into a project, run `ccvm` instead of `claude`,
   and land in the normal Claude Code TUI — same terminal, foreground, full fidelity
   (resize, `Ctrl-L`, `vim`, `less`, zsh vi-mode, colours). Arguments pass through
   verbatim. This is the contract; everything else bends to preserve it.
2. **Ephemeral by construction.** No persistent disk image anywhere. Power-off is the
   only cleanup. A crash, a kill, a dropped connection — all leave zero trace.
3. **The VM is the trust boundary.** The rest of the host is invisible — only the project
   directory is shared — and the Anthropic API key never touches disk, argv or the kernel
   cmdline. That boundary is what makes `--dangerously-skip-permissions` safe to opt into;
   ccvm passes no flags of its own, so you add that one yourself when you want it. A
   file-level safety net sits on top and is opt-in: `autoUpdateFiles = false` makes the
   project read-only too, so even edits stay in the VM (§3.6).
4. **Zero host setup.** `nix run github:jx-wi/ccvm` from any flakes-enabled NixOS box,
   or add the home-manager module for a persistent `ccvm` command.

### Non-goals

- Persistence of the VM's own state (installed tools, root fs — all RAM, all discarded).
  Your *project* edits are a separate matter: live on the host by default, or `git push`
  from inside when running under the read-only safety net.
- A general-purpose VM manager. ccvm builds exactly one guest and boots it one way.
- Defending the *host* against a malicious *guest kernel*. The boundary is QEMU; we
  assume QEMU's device/Virtio isolation holds. We do defend the host filesystem and
  the user's credentials.

---

## 2. Architecture at a glance

```
            host                                   guest (QEMU microVM)
  ┌───────────────────────────┐          ┌────────────────────────────────────┐
  │ ccvm (wrapper/ccvm.sh)     │          │  tmpfs /        (RAM, discarded)    │
  │                            │          │  /nix/store     (ro squashfs/vda)  │
  │  1. gen ephemeral ssh keys │  9p ro   │                                    │
  │  2. write seed ───────────────────────▶  ccvm-seed.service (root oneshot)  │
  │  3. boot QEMU (headless)   │          │     ├ install host key + authkeys  │
  │  4. wait for sshd banner   │          │     └ mount workspace per mode      │
  │  5. ssh -tt  ───────────────── SSH ───▶  sshd ─ForceCommand→ launcher       │
  │       (foreground)         │  :22     │            └ cd workdir; exec claude│
  │  6. on exit: kill qemu,    │          │                                    │
  │     rm scratch (trap)      │   slirp  │  networkd/DHCP 10.0.2.x, NAT out    │
  └───────────────────────────┘  net     └────────────────────────────────────┘
```

The wrapper is a single Bash script (`wrapper/ccvm.sh`) with the guest's boot
artifacts baked in at build time by `lib/mkccvm.nix`. The guest is a plain
`nixosSystem` (`guest/*.nix`). There is no daemon, no state directory, no config file.

---

## 3. Design decisions

### 3.1 QEMU + slirp, not cloud-hypervisor / firecracker

We need outbound HTTPS to `api.anthropic.com` with **zero host configuration** — no
bridges, no TAP devices, no `sudo`. QEMU's built-in **slirp** user-mode networking
gives an unprivileged NAT (guest `10.0.2.x`, DNS + DHCP synthesised by QEMU) plus
`hostfwd` for the inbound SSH port. cloud-hypervisor/firecracker are faster to boot but
expect you to wire up host networking yourself, which breaks goal 4. Boot speed matters,
but "works on a stock box as a normal user" matters more.

### 3.2 SSH over a localhost-forwarded port

QEMU forwards a random high port on `127.0.0.1` to the guest's `:22`
(`hostfwd=tcp:127.0.0.1:PORT-:22`). Binding to loopback only keeps the guest sshd off
the LAN. The wrapper picks the port by probing for a free one; there is a tiny TOCTOU
window between probe and QEMU's bind, which is acceptable for a single-user localhost
dev tool. If the bind ever loses the race, boot fails fast and you re-run.

### 3.3 SSH is the transport — for PTY fidelity, not just convenience

This is the load-bearing decision. The obvious way to talk to a VM is the serial
console, but a serial line is **not** a terminal: it does not carry `SIGWINCH`, window
size, or full termios, so resize breaks, full-screen TUIs corrupt, and `vim`/`less`
misbehave. The whole point of ccvm is that you can't tell you're in a VM.

`ssh -tt` to a real `sshd` gives us a genuine **PTY** on the guest side. SSH natively
propagates the client's `TERM`, the initial window size, and — critically — relays
`SIGWINCH` as window-change messages on every resize. termios (raw mode, signals,
flow control) is negotiated end to end. So `Ctrl-L`, vi-mode, `less`, and
arbitrary full-screen programs behave exactly as they do natively.

`-tt` *forces* PTY allocation even though the wrapper's own stdin may not be a tty at
the moment it execs ssh; without the double `-t`, ssh would decline the PTY and we'd
be back to a dumb pipe.

The wrapper runs ssh in the **foreground but never `exec`s it** — it must regain control
after the session to tear the VM down (§5).

### 3.4 Ephemeral root: tmpfs `/` + read-only `/nix/store`

The guest root is a **tmpfs** (RAM), so every byte the agent writes outside the project
lives only in guest memory and vanishes on power-off. The system closure is mounted
**read-only** at `/nix/store` from a self-contained **squashfs** on a virtio-blk disk —
always, for maximal isolation: nothing of the host store is exposed. This is the well-worn
"erase your darlings" pattern, so first-boot risk is low. (Reusing the *host* store to
accelerate in-VM builds is a separate, opt-in concern — a read-only build *substituter*,
not a writable mount; see `nix.useHostStoreAsCache` in §3.11.)

Boot is **direct kernel boot**: no bootloader. `mkccvm` extracts the kernel + initrd and
hands QEMU `-kernel/-initrd/-append`. The initrd is the **systemd** one (the scripted
initrd is deprecated upstream for 26.11); it mounts the tmpfs root and read-only squashfs
store from generated units, with the virtio transports and `squashfs`/`overlay` modules
forced into the initrd so the store device and overlay are available before switch-root.

### 3.5 The seed: a read-only 9p share for per-invocation inputs

Everything that differs per launch — the SSH host key, `authorized_keys`, the workspace
path, the file-sharing mode, the debug-shell flag, and the forwarded argv — is written
by the wrapper into a scratch directory and exported to the guest as a **read-only 9p
share** tagged `ccvm-seed`. A boot oneshot, `ccvm-seed.service`, mounts it, installs the
SSH identity with strict perms, and performs every privileged mount **before sshd
starts**. Because all the privileged work happens there, the sshd `ForceCommand`
launcher runs **completely unprivileged** — it only `cd`s and `exec`s.

The forwarded argv is serialised **NUL-separated** (`printf '%s\0'`) and reconstructed
with `mapfile -d ''`, so spaces, quotes and glob characters survive byte-for-byte and
are never rebuilt by word-splitting.

The API key is **deliberately not in the seed** (§3.7).

### 3.6 File-sharing modes: rw (default) vs overlay

The host CWD is shared over 9p and **mounted at the identical absolute path** inside the
guest, so any path the agent prints or writes matches the host's mental model.

- **`autoUpdateFiles = true` (default): read-write passthrough.** The host CWD is mounted
  read-write; edits land on the host live — identical to running `claude` natively. With
  `security_model=none`, files are created with real host uid/gid (no `.virtfs_metadata`
  litter). The guest `ccvm` user is baked at uid 1000, but 9p passthrough is numeric, so a
  host user whose uid ≠ 1000 would otherwise see the project owned by a foreign uid (the
  agent couldn't write its own files) and create host files owned by 1000. To stay native
  for *any* host uid, the wrapper writes the host `id -u`/`id -g` into the read-only seed
  (non-secret integers, never the API key) and the guest `ccvm-seed.service` remaps its
  agent user/group to match **before sshd starts** — so the login session and every file
  the agent creates carry the correct host ownership. The remap is best-effort and
  fail-open: a missing/garbage/root id leaves uid 1000 rather than blocking boot. This
  mirrors native `claude`, which is why it is the default.
- **`autoUpdateFiles = false`: overlay (the safety net).** The host tree is the
  read-only **lower** of an overlayfs; a tmpfs is the **upper**. The agent sees and edits
  a full working tree, but every write lands in guest RAM. The host project is never
  modified; on exit the edits evaporate. Export deliberately via `git push`.

The mode is resolved at launch, highest precedence first: the per-run flags
`ccvm --no-auto-update-files` / `--auto-update-files` (intercepted by the wrapper and
**not** forwarded to claude), then `CCVM_AUTOUPDATE=0|1`, then the baked-in
`autoUpdateFiles` default. The flags win, so you can flip either way for a single run
without touching config — and because they are consumed by the wrapper, claude still
receives only the user's own arguments.

### 3.7 Secret handling: the API key rides the SSH channel only

The Anthropic key must never be persisted or observable. It is **not** put on the kernel
cmdline, **not** in any QEMU argument, **not** in the seed, **not** in any file. Instead
the wrapper passes only the *variable name* to ssh via `SendEnv`; sshd accepts exactly
that name via `AcceptEnv`; the value travels **inside the encrypted SSH channel** and
arrives as an environment variable in the launcher, which `exec`s claude with it already
in the environment. `ps`, `/proc/<pid>/cmdline`, and the scratch dir never see it.

`SendEnv` (send the host's current value of a named var) is used rather than `SetEnv`
(put a literal `VAR=value` on the ssh command line), precisely because `SetEnv` would
place the secret in argv.

`shareClaudeConfig` (**on by default**, so ccvm mirrors native `claude`) is the other way to
authenticate: it surfaces the host's `~/.claude` (settings, custom commands, global memory,
and the OAuth credential) inside the VM as the read-only **lower** of an overlay, with a
tmpfs **upper** for claude's own writes. Set `CCVM_SHARE_CLAUDE_CONFIG=0` to disable it for one run
(or `=1` to force it on); the env var overrides the baked `shareClaudeConfig` default.
The OAuth credential therefore rides the read-only 9p mount and is **never copied into the
scratch dir or the seed** — only the non-secret home-root `~/.claude.json` is staged through
the seed and installed into the writable home. Claude's writes (including token refreshes)
land in the tmpfs upper and do not persist back to the host.

**home-manager symlinks.** A managed `~/.claude` typically has config files symlinked *out of
the tree* — e.g. `settings.json -> /nix/store/…-home-manager-files/.claude/settings.json`. 9p
passthrough preserves those symlinks verbatim, but their targets don't exist inside the guest,
so they would dangle and claude would read no config. The wrapper therefore walks `~/.claude`
and stages the **dereferenced contents** of every symlink whose target escapes the tree into
`seed/config-deref`; the guest lays those real files over the overlay's writable upper,
shadowing the dangling links. The walk **never follows `.credentials.json`** (it stays a 9p-only
secret), and only escaping links are dereferenced — internal relative links already resolve on
the mount. This is what makes a home-manager-managed config readable in the VM regardless of
whether the host `/nix/store` is shared.

A key is **not required**, though. With no `ANTHROPIC_API_KEY` set and `shareClaudeConfig`
turned off (or no host `~/.claude` to share), the wrapper warns (it no longer aborts) and
starts claude unauthenticated, so the in-VM **`/login` web-auth flow** works: claude prints an
authorization URL, you open it in your host browser and paste the resulting code back into
the TUI. No inbound connection to the guest is needed (the code is pasted, not delivered to
a callback), so nothing about the network model changes. The credentials claude writes to
its tmpfs `~/.claude` are, like everything else in the VM, discarded on exit.

**Guest RAM vs. host swap.** Everything secret in the VM lives in guest RAM — the API key in
the launcher's environment, any `/login` credentials in tmpfs. That RAM is ordinary host
process memory, so a memory-pressured host kernel *could* page it out to swap. `lockGuestMemory`
(off by default; `CCVM_MLOCK=1` for one run) starts QEMU with `-overcommit mem-lock=on`, which
mlocks the guest so it can never reach the host's possibly-unencrypted swap. It needs a large
enough `RLIMIT_MEMLOCK` or QEMU won't start. This — not full-disk encryption, which is moot
when there is no persistent disk — is the relevant at-rest protection for an all-RAM VM.

**Git config passthrough.** For the same native-fidelity reason as `shareClaudeConfig`, ccvm
stages the host's git identity into the VM (`shareGitConfig`, on by default) so in-VM `git`
commits as you, with your aliases and global ignores. It cannot be a verbatim copy: a
home-manager-managed `~/.config/git/config` is full of absolute `/nix/store/…` paths (editor,
pager, `delta`, the `gh` credential helper) that don't exist in the guest — the same dangling-
symlink class of problem as the `~/.claude` config, but here the dead values are *inline*, not
symlinks. So the wrapper resolves the **global** config host-side (where git and the store
both exist) and writes a **sanitized** copy to the seed, applying four rules: drop any setting
whose value contains `/nix/store/` (host-only tool paths); drop every `credential.*` helper
(no host credentials cross the boundary — consistent with `~/.ssh` never being shared); stage
the resolved `core.excludesfile` *content* to the guest's default ignore path; and force
`commit.gpgsign`/`tag.gpgsign` off (the signing key is never carried, and a stray `gpgsign =
true` would otherwise break every in-VM commit). The guest's seed service lays the result at
`~/.config/git/config`/`ignore`, owned by the (uid-remapped) agent user. Only non-secret
config is ever written to the seed — the same invariant as the API key and the OAuth
credential, and it is checked the same way (a host-side test greps the seed). The deliberate
gap: `git push` still can't authenticate in the VM, because the credential to do so is exactly
what we refuse to carry — and we deliberately keep it that way rather than smuggle a token in.
Pushing is a host-side action: in the default rw mode the agent's commits are already in the
host repo (push from a host terminal); in overlay mode you export from the host instead.

**Context injection (`extraClaudeMd`).** The agent behaves better when it *knows* it's inside
ccvm — it can be more autonomous in a disposable sandbox, it should understand that nothing
outside the project persists, and it needs to know that `git commit` works but `git push`
doesn't. ccvm stages a short Markdown blurb (on by default, user-replaceable) as the guest's
`~/.claude/CLAUDE.md` global memory. Two design choices matter here. First, it is delivered
**through the seed and laid over the config overlay — not via `--append-system-prompt`** — so
the transparent-passthrough invariant holds: the wrapper still adds zero flags to claude's
argv (§4). Second, the blurb is baked at build time, but the *file-sharing mode* is only known
per run (flags / `CCVM_AUTOUPDATE`), so the **wrapper prepends a runtime-accurate line** — "edits
are live on the host" in `rw`, "edits are discarded on exit" in overlay — that the static file
could not state correctly. When `shareClaudeConfig` brings the host's own `~/.claude/CLAUDE.md`,
the guest **appends** rather than overwrites (the combined file copies-up into the overlay's
tmpfs upper, so the host file is never touched), preserving the user's global memory.

**Persisting sessions + memory (`persistClaudeProjects`).** Making `~/.claude` ephemeral has a
cost: Claude writes each session's transcript and the project's memory under
`~/.claude/projects/<cwd-slug>/`, and those writes land in the throwaway overlay upper — so a
session *started inside ccvm* can't be `claude --resume`d in a later run (the transcript is
gone; the ID isn't found), and memories don't carry over. (Host-native sessions still resume,
read-only, from the lower.) The opt-in `persistClaudeProjects` mounts the host's
`~/.claude/projects` **read-write** over that subpath, so transcripts and memory write straight
back. The scope is the deliberate part: only `projects/` is writable, never the whole
`~/.claude` — the OAuth credential sits at the config *root*, not under `projects/`, so the
"credential never written back to the host" invariant (§3.7) is untouched. It stays **off by
default** because it is the one place, besides project edits in rw mode, where VM activity
escapes the ephemeral boundary; turning it on is a conscious "I want my history back" choice.

### 3.8 The microvm.nix runtime-share trap

It is tempting to declare the workspace 9p mount inside the guest NixOS config (or to use
microvm.nix's share mechanism). **We can't:** the workspace path and the SSH port are
only known at `ccvm` *launch* time, not at *build* time. If they were baked into the
guest closure, every new project directory would force a guest rebuild, and the same
built artifact couldn't be reused across launches.

So `mkccvm` bakes only what is launch-invariant — kernel, initrd, store image, kernel
cmdline, and the scalar config — into the wrapper. The wrapper constructs the
**runtime** QEMU args (the workspace `-fsdev`, the seed share, the `hostfwd` port) itself,
at launch. The guest learns the workspace path and mode by *reading the seed*, not from
its own configuration. This split is the single most important structural choice in the
codebase; getting it wrong is the "runtime-share trap".

### 3.9 Guest hardening

`sshd` is single-purpose: key-only (`publickey` only, no passwords, no
keyboard-interactive), `PermitRootLogin no`, no TCP/agent/X11 forwarding, one
`ForceCommand`. The host key is the per-run ephemeral key from the seed, so the client
pins it (`StrictHostKeyChecking=yes`, known_hosts entry written before connect) — there
is no blind trust-on-first-use. The firewall is off because slirp already NATs the guest
off any real network and nothing should be reaching *in* except the forwarded port.

### 3.10 Egress: open by default, opt-in allowlist (not Tor)

Outbound is **open by default**: the guest NATs through slirp, so the agent can reach the
Anthropic API and anything else it wants — `WebFetch` URLs, `npm`/`pip`/`git clone`. That is
the deliberate native-mirroring default and is fine for the *containment* goal (the agent
still can't touch the host beyond the CWD), but it leaves one gap: a prompt-injected or
compromised agent can **exfiltrate** the shared project tree — or, under the default
`shareClaudeConfig`, the host OAuth credential it can read in-VM — to an arbitrary host.

The on-threat-model answer is an **egress allowlist**, not anonymity, and it is now
**implemented as an opt-in mode** (`egressAllowlist` / `egressPorts`). An empty list (the
default) keeps egress fully open; a non-empty list switches the guest to a **default-deny**
nftables OUTPUT chain that permits only the listed destinations on the listed ports (TCP),
plus a small base set: loopback, conntrack replies (so the inbound ssh session and DNS
answers keep working), DNS **only to the slirp stub resolver** (10.0.2.3 / fec0::3), DHCPv4
renewal, and IPv6 NDP. `api.anthropic.com` is always auto-included. This stays inside ccvm's
existing model — agent containment + credential hygiene — at zero latency cost.

**Where the work happens.** The allowlist is a per-launch runtime input, so it follows the
runtime-share split (§3.8), not a baked guest closure value: `egressAllowlist`/`egressPorts`
are baked into the wrapper as scalars (`@EGRESSALLOW@`/`@EGRESSPORTS@`), but the **host**
resolves any FQDN entries at launch (it has working DNS), passes IPs/CIDRs through verbatim,
and writes the resolved set + ports into the **seed** alongside an `egress-enforce` marker.
The guest's `ccvm-seed.service` enforces the firewall whenever that **marker** is present —
not merely when the resolved set is non-empty — so an empty set fails closed (deny-all)
instead of reverting to open egress. Two layers guard the fail-open hole: if the user opts in
but *nothing* resolves (host DNS down, no literal IPs), the **wrapper refuses to boot** rather
than run an unenforceable allowlist; and the guest enforces on the marker regardless. If
`nft -f` fails (atomic — nothing installed on error), the guest **fails closed but keeps the
base rules** (ssh session + DNS survive) so you can `--shell` in to debug, rather than a bare
deny-all that would drop sshd's own replies and hang the boot.

```nix
programs.ccvm.egressAllowlist = [ "github.com" "registry.npmjs.org" "10.0.0.0/8" ];
programs.ccvm.egressPorts     = [ 443 ];   # add 80 for plain-HTTP mirrors
```

**Known limitations (the MVP) — three residual channels the IP-filter MVP can't close,**
each the job of the future SNI/DNS-filtering proxy that layers on top:
- **FQDN staleness.** Hostnames can't be matched by a stateless packet filter (the kernel
  sees IPs), so they're handled by host-side DNS pre-resolution at launch — pinned A/AAAA
  records, with the round-robin/CDN caveat for a long session. This bites `api.anthropic.com`
  itself (Cloudflare-fronted): if it rotates to an unpinned edge mid-session, API calls fail —
  the user restarts or pins a broader CIDR. "Auto-included" guarantees it's *attempted*, not
  that the pinned IPs stay valid forever.
- **DNS tunneling.** DNS is restricted to the stub resolver (not arbitrary servers), which
  blocks direct DNS-to-anywhere, but a determined agent can still tunnel low-bandwidth data
  through the recursive resolver. Closing this needs a filtering resolver, not a packet filter.
- **TCP-only.** Only TCP on the listed ports is allowed; QUIC/UDP 443 is dropped and clients
  fall back to TCP. UDP-only services would need explicit handling.

**Why not Tor.** Routing guest traffic through Tor was considered and rejected. It solves
network *anonymity*, which is orthogonal to this project: the dominant flow is the Anthropic
API authenticated with the user's own credential, so Tor hides the source IP while the
application layer still identifies you exactly — self-defeating. It also adds latency and
runs into Anthropic blocking Tor exit IPs, both of which violate the "no compromise on
devex/ux" rule, and a `tor` daemon is new long-running surface to harden. Crucially it is
**redundant**: because the guest egresses through the *host* network stack (§3.1), a user
who wants anonymity runs Tor or a VPN on the host and the guest rides through it for free,
with no guest-side code. Egress *control* (where the agent may connect) belongs in ccvm;
egress *anonymization* (how those packets reach the wire) belongs on the host.

### 3.11 Encrypted disk pool (`vmDiskSize`) + in-VM nix (`nix.enable`)

> **Naming note.** The user-facing option is `programs.ccvm.nix.enable` (with a sibling
> `nix.useHostStoreAsCache`, §"Remaining follow-ons"). The guest/internal build-time flag this maps
> to is still called `nixInVm` throughout the guest closure (`guest/default.nix`, `lib/mkccvm.nix`) —
> the references to `nixInVm` below describe that internal mechanism.

> **Status: both shipped & KVM-verified (2026-06-06).** Two opt-in, off-by-default features came out
> of this design: **`vmDiskSize`** — an encrypted, ephemeral disk pool (key generated in guest RAM,
> host sees only ciphertext, wiped on exit) mounted at `/scratch`; and **`nixInVm`** — a writable
> `/nix/store` overlay + `nix.enable` so in-VM `nix develop`/`nix build` work. Verified end to end:
> `nix flake check` clean, `tests/boot.sh` 25/25, a real `vmDiskSize` run showed `/scratch` as a
> dm-crypt mount, and a real in-VM `nix build nixpkgs#hello` worked with the realised path **gone on
> the host after exit**. Two refinements landed during implementation that the plan below predates:
> the LUKS format uses a fast **pbkdf2** (the key is already 64 random bytes, so a memory-hard KDF
> would only slow boot for no security gain), and a tmpfs image dir is **refused** unless
> `CCVM_SCRATCH_ALLOW_TMPFS=1`. The last piece — wiring the two together so the `nixInVm` overlay
> *upper* is backed by the `vmDiskSize` disk instead of tmpfs — is now **DONE & KVM-verified
> (2026-06-07)**: an initrd LUKS oneshot, fail-open to tmpfs, one shared encrypted pool for the
> store upper and `/scratch`. See "Disk-backed upper" under "Remaining follow-ons" below.

**The problem the RAM-only model can't solve.** ccvm's root is tmpfs and `/nix/store` is a
read-only squashfs (§3.4). That is the right default — wipe-on-exit is a property of *physics*,
not of a cleanup routine — but it breaks for large **writable** data: `nix develop` realising a
multi-GB closure, a big `node_modules`/`target`/`.venv`, hefty build outputs. tmpfs is backed by
RAM, so at `memory=4096` a large write OOMs the guest; and you cannot `nix build`/`nix develop`
into `/nix/store` at all because it is read-only. The workspace 9p share helps for *project*
files, but not for a writable store or scratch that must not consume RAM.

**The plan (keeps wipe-on-exit, cryptographically).**

- The **host** attaches a raw **sparse** image as a `virtio-blk` device, created in a
  **disk-backed** `scratchDir` — explicitly *not* `XDG_RUNTIME_DIR`, which is usually tmpfs and
  would defeat the whole point by putting the "disk" back in RAM. A `diskSize` cap bounds it;
  sparse means it only consumes what is actually written.
- The **guest** generates a LUKS key from `/dev/urandom` and `cryptsetup luksFormat`s the device
  **fresh every boot**. The key is generated *in the guest* and **never crosses 9p** — the host
  only ever sees ciphertext. This is strictly stronger than passing a key through the seed, and
  it mirrors the existing invariant that the API key lives only in guest RAM (§3.7).
- The decrypted device is mounted either as a generic encrypted scratch, or as the encrypted
  overlay **upper** over the read-only squashfs `/nix/store` — giving a writable store backed by
  disk instead of RAM.

**Why FDE rather than a plain ephemeral disk.** Wipe-on-exit must survive a crash that skips the
cleanup trap, and on modern storage *plain deletion is not erasure*: SSD TRIM is asynchronous,
and CoW filesystems/snapshots can retain freed blocks. With FDE the key dies with guest RAM at
power-off, so the on-disk image is inert ciphertext the instant the VM stops — even if the trap
never runs. The trap still `rm`s the image as belt-and-suspenders, but the security guarantee
rests on the key being gone, not on the delete succeeding.

**Decisions (locked 2026-06-06).** After analysis, the chosen shape is **one ephemeral encrypted
pool**, not two disks:

- **One disk, one knob — `vmDiskSize` (integer GiB; `0` = off).** It supersedes the phase-1
  `storeDisk` string (we are pre-public, so the rename is free). The single encrypted, ephemeral
  disk backs the **bulk, non-secret** writable areas — `/scratch` and (phase B) a writable
  `/nix/store` overlay — while **`/home` and root stay tmpfs**, so secrets (`/login` creds, API
  key material, agent memory) never leave guest RAM. The "split" intuition is real but the right
  split line is *bulk on the encrypted disk, secrets in RAM*, achieved by **placement**, not by a
  second sized disk.
- **Why not a separate `/nix/store` disk?** Once the disk is encrypted with a guest-RAM key, disk-
  vs-tmpfs makes **no** confidentiality difference against the in-guest attacker (it can read tmpfs
  or decrypt the disk equally). A second disk only earns its keep for a **different lifecycle** —
  i.e. a *persistent* store cache (safe, since store paths are content-addressed public packages)
  alongside an ephemeral `/home`. That is a separate future feature with its own key-management
  decision (a persistent disk needs a persistent key — likely an *unencrypted* store disk, since
  the store is non-secret), explicitly **not** folded into `vmDiskSize`.
- **Default: off.** Pure-RAM stays the default so boot stays fast and the no-disk invariant holds
  unless explicitly opted into. When enabled, **32 GiB** is a sensible starting size. (`vmDiskSize`
  is an integer so `mkDefault 32` reads naturally, but the *baked default is `0`* — off wins over
  a default size, per the locked "opt-in" decision.)

**Relationship to the host store (`nix.useHostStoreAsCache`).** These are complementary, not
competing. If the multi-GB closure is *already realised in the host store*, the planned
`nix.useHostStoreAsCache` will let in-VM nix pull those paths from the host store as a read-only
build **substituter** (a cache — never a writable mount, so the agent can't mutate the host's
store) instead of rebuilding them, at near-zero RAM cost. The encrypted scratch disk is for the
orthogonal case: when the guest must **write** a large closure (or other large data) ephemerally
and would otherwise exhaust RAM. (The host store is *never* the guest's own boot store — that is
always the self-contained squashfs, §3.4.)

#### Implementation status & remaining plan

Staged so the risky initrd work is isolated from the safe, post-boot part:

**Increment A — the encrypted pool (`/scratch`) — IMPLEMENTED & KVM-VERIFIED, then GENERALIZED.**
Shipped first as `storeDisk` (a sparse, guest-LUKS-encrypted disk mounted at `/scratch`; key
generated in guest RAM, never on 9p; wiped on exit; host image in a disk-backed dir, tmpfs
refused) and verified on a Nix+KVM box. Then **renamed/generalized to `vmDiskSize`** (integer GiB,
`0` = off) per the locked single-pool decision — the disk is the shared pool, `/scratch` is its
first consumer. The mechanics carry over unchanged: size validation, disk-backed scratch dir with
the tmpfs guard, sparse `truncate`, `virtio-blk` with `serial=ccvm-scratch` (stable
`/dev/disk/by-id` path regardless of `/dev` ordering), the seed marker, `cleanup()` `rm`, and the
guest seed-service LUKS-format/open/mkfs/mount with fail-open. `/home` and root stay tmpfs.

**Increment B — writable `/nix/store` overlay + in-VM `nix` — DONE & KVM-VERIFIED (2026-06-06).**
The `nixInVm` option (build-time, default off — it rebuilds the guest with `nix.enable` and changes
the store mount, so it can't be a runtime env var) makes `/nix/store` a **writable overlay**: the
read-only store image as the lower (`/nix/.ro-store`), a writable upper, declarative
`fileSystems.overlay` at `/nix/store`. This turned out far simpler than feared: the declarative
overlay is set up by the systemd initrd with **no custom initrd scripting** — and the upper is
**tmpfs**, so there is no LUKS-in-initrd at all for the RAM-backed case. nix realises new paths into
the upper. Verified: `nix flake check` clean, `tests/boot.sh` 25/25 (default posture stays
read-only + no nix; the `nix` posture is an `overlayfs` `/nix/store` with `nix` present), and a real
guest shell ran `nix build`/`nix run nixpkgs#hello` → "Hello, world!" with the realised path **gone
on the host after exit** (it lived only in the tmpfs upper — ephemeral guarantee intact). MVP scope:
no store-DB registration (nix builds/substitutes fresh into the upper rather than reusing baked
paths — a later optimization), tmpfs upper only.

**Disk-backed upper — DONE & KVM-verified (2026-06-07).** When `nixInVm` and `vmDiskSize > 0` are
both on, the overlay upper (`/nix/.rw-store`) is backed by the encrypted disk instead of tmpfs, so a
large `nix develop` doesn't exhaust guest RAM. This is the LUKS-in-initrd work originally feared here:
the disk must be opened and mounted before the store is assembled, so it runs as a **systemd-initrd**
oneshot (`ccvm-store-disk`, gated on `nixInVm`). The shape chosen for low brick-risk is
**mount-stacking with fail-open**: the declarative tmpfs `/nix/.rw-store` still mounts first (it is
the baseline), then — if the disk is present — the service `luksFormat`/`open`/`mkfs.ext4`s it and
mounts it *over* that tmpfs, so the overlay's `upperdir` lands on disk; the overlay config is
byte-identical either way, only what is mounted at `/nix/.rw-store` differs. Absent disk or *any*
failure leaves the tmpfs upper untouched (the service always exits 0), so boot can never brick. The
LUKS key is generated in the initrd's `/run` (tmpfs RAM), shredded right after open, and never
crosses 9p — the host sees only ciphertext, the same invariant as the post-boot `/scratch` path. The
disk is a single shared **pool**: on success the initrd writes `/run/ccvm-store-on-disk` (systemd
preserves `/run` across switch-root), and the post-boot seed service, seeing that marker, binds
`/nix/.rw-store/scratch` to `/scratch` rather than re-formatting a second disk (`lsblk` confirms one
`ccvm-scratch` crypt device backing both). Three things the *default* initrd lacks had to be added,
all `nixInVm`-gated: a `udevadm settle` before probing (the scratch disk is undeclared, so only the
store disk is waited for and the scratch `by-id` link lags); `cryptsetup` + `e2fsprogs` listed in
`boot.initrd.systemd.storePaths` *directly* (a script's transitive references are not pulled into the
initrd — referencing them only via `PATH` yields `command not found`); and the `ext4` module (the
default initrd carries only squashfs/overlay/9p). Verified by `nix flake check`, `tests/boot.sh`
31/31 (the `nixDisk` posture), and a real `CCVM_VM_DISK_SIZE=8` run building `nixpkgs#hello` into the
disk-backed upper.

**Remaining follow-ons (not blocking — `nix develop` with a disk works today):**
- **L2 — `nix.useHostStoreAsCache` (host store as a build substituter).** The option is **declared**
  (so the public API is final and won't churn after release) but **not yet implemented** — it warns
  at eval time and has no effect. The chosen mechanism is a read-only **substituter** (host store as
  a binary cache: nix copies the needed paths into the VM's own store and registers them as valid),
  *not* mounting the host store as the overlay lower. The overlay-lower approach was **considered and
  rejected**: a bare FS mount gives path *presence* but not nix **DB** validity, so nix won't trust
  those paths for builds without also loading the host store DB (`reginfo`) — and even done right it
  exposes the *entire* host store to the agent (weaker isolation) for only a marginal copy-avoidance.
  The substituter is the standard, DB-consistent, better-isolated mechanism (it surfaces only the
  paths a build actually needs). It still reads the host store over a ro 9p mount internally, just as
  a cache source rather than as the live store.
- **Store-DB registration** (`closureInfo`/`.reginfo` load at boot) so nix reuses the baked paths
  instead of re-fetching — a boot-time optimization, deferred; part of the substituter work above.

**Tests as established:** `host.sh` host-side staging in `nix flake check`; `boot.nix` postures
(`scratch` for the disk, `nix` for in-VM nix) + `stub-claude.sh` reports (`SCRATCH:*`,
`STORE:overlay`/`readonly`, `NIX:present`/`absent`) asserted by `tests/boot.sh`.

**Tests.**
- *`host.sh` (dry-run, new block):* opt-in writes `seed/scratch-disk`; the sparse image exists at
  the resolved scratch dir, `format=raw`, and is **sparse** (allocated blocks ≪ apparent size via
  `du`); the dir is **not** tmpfs and **not** under `$TMP`; the QEMU args carry
  `serial=ccvm-scratch`; default (off) writes no marker/image; and **no key material is ever in
  the seed** (grep → zero hits — the key is guest-only). The test must `rm` the image it triggers.
- *`boot.sh` (persist-style variant, stub claude, tcg):* boot with `storeDisk=64M`; assert
  `/scratch` is a writable mountpoint owned by the agent, backed by a **`crypt`** dm target
  (`dmsetup status ccvm-scratch` / `lsblk -o TYPE` shows `crypt`), and that the **host** image is
  LUKS (`cryptsetup isLuks`, or the `LUKS\xba\xbe` magic) — i.e. the host sees ciphertext only.
- Bump the 20→21 token-balance awk checks; add `@STOREDISK@` to the `host.sh` substitution recipe.

**Docs.** README option row + `CCVM_STORE_DISK`/`CCVM_SCRATCH_DIR` env rows; flip this section's
status "design → implemented (phase 1)"; add a CLAUDE.md security-invariant note: *the LUKS key is
generated in guest RAM and never crosses 9p (host sees only ciphertext); the scratch image is
inert on exit (key death) and `rm`'d by the trap.*

**Definition of done (per CLAUDE.md).** `nix flake check` green **and** the stub-package boot test
above asserting `/scratch` is an encrypted, writable mount with a LUKS host image — on a Nix+KVM
box. None of this is verifiable on the no-Nix/no-KVM dev box, so it is **not** a candidate for the
auto-commit-on-green convention; it must be built and checked on a capable machine.

---

## 4. Boot & connect flow (wrapper)

1. Parse args: peel off ccvm-only flags (`--shell`, `--ccvm-debug`); everything else is
   forwarded to claude. Resolve mode (overlay/rw) and acceleration (KVM if usable, else
   TCG; `CCVM_ACCEL=tcg` forces software emulation for broken nested-virt hosts).
2. Check auth: if no API key and no shared host config, warn (don't abort) so the
   in-VM `/login` web-auth flow can run.
3. Make a scratch dir under `$XDG_RUNTIME_DIR`; arm a single `trap cleanup EXIT INT TERM
   HUP`.
4. Generate two throw-away ed25519 keys (client identity + guest host key); pin the host
   key into a known_hosts file.
5. Populate the seed; build the runtime QEMU device args (store, seed share, workspace
   share, slirp + hostfwd, rng).
6. Boot QEMU **headless in the background**, stdio detached from the terminal so it never
   touches the TTY the TUI will own. Guest serial goes to a log file.
7. Poll the forwarded port for the `SSH-*` banner (not a full ssh — a real connection
   would trip the ForceCommand and launch claude on every probe).
8. `ssh -tt` in the foreground. Hand the terminal to Claude Code.

## 5. Teardown

A single `cleanup` trap fires on every exit path — normal quit, `Ctrl-C`, a dropped
connection, `SIGTERM`/`SIGHUP`, or boot failure. It kills the QEMU process (TERM, then
KILL) and removes the scratch dir (which holds the only copies of the ephemeral keys).
Freeing QEMU discards all guest RAM, which **is** the ephemeral story — there is no disk
state to scrub. The wrapper deliberately does **not** `exec ssh`, so it always regains
control to run this. `Ctrl-C` during a session is forwarded by `ssh -tt` to Claude Code
(it interrupts the agent, as it would natively); the VM is torn down only when the
session itself ends.

---

## 6. Build topology

- `guest/default.nix` — the ephemeral NixOS system (boot, fs, networking, user, packages).
- `guest/sshd.nix` — the hardened, single-ForceCommand sshd.
- `guest/launcher.nix` — `ccvm-seed.service` (privileged setup) + `ccvm-guest-launch`
  (unprivileged `cd`+`exec`).
- `lib/mkccvm.nix` — evaluates the guest, extracts boot artifacts, bakes them + scalar
  config into the wrapper. Called with the caller's own `pkgs`, so host and guest share
  one nixpkgs.
- `wrapper/ccvm.sh` — the host-side launcher (§4–5). Built with `writeShellApplication`,
  so it is shellcheck-clean by construction.
- `modules/home-manager.nix` — `programs.ccvm.*` → installs the `ccvm` command.
- `tests/` — `host.sh` (host-side guarantees via the `CCVM_DRYRUN` hook; wired into
  `nix flake check` by `default.nix`) and `boot.sh`/`stub-claude.sh`/`boot.nix` (local
  full-boot smoke test).

## 7. Known limitations

- **Coverage is layered (see `tests/`).** The host-side security invariants are checked in
  CI by `tests/host.sh`, which drives the real wrapper through a dry-run hook (`CCVM_DRYRUN`:
  populate the seed + run the config-staging loop, then stop before boot): the API key never
  reaching the seed, the OAuth credential never being staged (top-level and nested), escaping
  host-config symlinks being dereferenced, verbatim NUL-separated argv, and ccvm-flag
  consumption + mode selection. `tests/boot.sh` boots a stub-`claude` VM locally to confirm
  the argv reaches claude and that overlay vs. rw file visibility is correct. PTY/`TERM`
  propagation, `SIGWINCH`/resize, and teardown are **not** auto-tested — interactive fidelity
  is a human smoke test by nature (README checklist), and teardown is verified by inspection.
- **aarch64-linux is best-effort.** It evaluates and is wired up, but the primary,
  CI-built target is x86_64-linux.
- **`shareClaudeConfig` is read-only.** The in-VM Claude's writes to its config — including
  OAuth token refreshes — stay in the ephemeral overlay and do not persist back to the
  host (§3.7).
