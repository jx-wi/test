# CLAUDE.md

Working agreement for agents and contributors on **ccvm** — run Claude Code in an
ephemeral, RAM-only QEMU microVM with native-terminal fidelity. User docs live in
[README.md](README.md). This file is the authoritative engineering doc: the rules that
must not regress, the rationale behind the settled decisions, and the traps that cost
time to rediscover.

## Repo map

| Path | Role |
|---|---|
| `flake.nix` | Outputs: `packages.*.ccvm`, `homeModules.default`. |
| `lib/mkccvm.nix` | The builder. Evaluates the guest NixOS system, then bakes its boot artifacts + scalar config into the wrapper via `builtins.replaceStrings` `@TOKENS@`. |
| `wrapper/ccvm.sh` | Host wrapper **template** (the `@TOKEN@` placeholders). Generates throw-away SSH keys, writes the seed, boots QEMU headless, `ssh -tt`s in, traps cleanup. |
| `guest/default.nix` | The microVM NixOS guest (tmpfs root, ro squashfs `/nix/store`). |
| `guest/launcher.nix` | Two units. `ccvm-seed.service` (root oneshot, `Before=sshd`) installs the pinned host key + `authorized_keys` and does every 9p/overlay mount. `ccvm-guest-launch` is the **unprivileged** sshd `ForceCommand` that just `cd`s to the workspace and execs claude (or zsh). |
| `guest/sshd.nix` | Hardened sshd: key-only, no root, single `ForceCommand`. |
| `modules/home-manager.nix` | `programs.ccvm.*` options → installs the command. |
| `tests/` | `host.sh` (CI host-side guarantees via the `CCVM_DRYRUN` hook), `boot.sh`+`stub-claude.sh`+`boot.nix` (local full-boot smoke test), `default.nix` (wires `host.sh` into `nix flake check`). |

## Security invariants — MUST NOT regress

These are the whole point of the project. Treat any change that weakens one as a bug.

**Scope of the boundary.** The trust boundary is QEMU: we assume its device/Virtio isolation
holds, and defend the *host filesystem and the user's credentials* against a (possibly
prompt-injected) agent. Explicitly out of scope: defending the host against a malicious *guest
kernel*, and being a general-purpose VM manager — ccvm builds exactly one guest and boots it one
way. The VM being the boundary is what makes `--dangerously-skip-permissions` safe to opt into
(`writableCwd=false` adds a file-level safety net on top).

**Default posture — what the defaults do and don't stop (be honest about this).** The
invariants below stop the *host* from being **persisted to or having its credentials written to
disk** — they do **not** sandbox what a prompt-injected agent can **read and send**. With the
native-mirroring defaults (open egress + `share.*` allowlist on), the in-VM agent can read the
whole project tree and **exfiltrate it over open egress** (and, with `clipboard.images` on, pull
the host clipboard *image* — never its text — into that same exfiltratable set; see "Image paste").
What it can NO LONGER read is the
host's OAuth login: the `share.*` allowlist stages only settings/commands/memory, and the
credential is **excluded by construction** (it is simply not a `share.*` item and thus never
reaches the seed at all), so claude starts unauthenticated and the user's own in-VM `/login` or
API key authenticates it. Be precise about what that buys: it is the host's **stored** credential
that never crosses. Once the user authenticates in-VM, the resulting `/login` token lives in the
ephemeral tmpfs `~/.claude` and **is readable by the in-VM agent** (it has to be — claude reads
it), so under open egress it is exfiltratable: the same class of exposure as the project tree, and
no worse than native `claude` (where the agent runs as the user too). `egressAllowlist` contains
it; nothing else does. So the out-of-the-box win is **containment** (no host access beyond the
CWD, nothing persists) plus **the host login never auto-crossing** — **not**
project-exfiltration resistance, a deliberate DevEx choice, not a bug. The primary hardening knob
is `egressAllowlist` (default-deny egress; the API stays reachable) — but its firewall is enforced
**inside the guest**, so it only binds an agent that isn't guest-root. Setting `egressAllowlist`
therefore also **auto-drops the agent's sudo** (`agentSudo` auto) **and, under `nix.enable`, removes
the agent from Nix `trusted-users`** — both are load-bearing, because a Nix trusted-user is
root-equivalent (it can register a `post-build-hook`, which the root daemon runs **as root**) and
would otherwise regain root and `nft flush` the rules (audit S-1; was demonstrated end-to-end, now
fixed in `guest/default.nix`). With those two, a prompt-injected agent can't reopen egress short of a
guest-kernel exploit; the *complete* fix is still host-side egress enforcement (not built yet —
see "Egress: an allowlist, not Tor"). To disable all claude config sharing, set all
`share.*` items to false or use `CCVM_SHARE_CLAUDE_CONFIG=0`. Keep this distinction accurate in
user-facing docs — under-stating it is the one thing that turns a sandbox into a liability.

- **API key never touches disk/argv/kernel-cmdline.** It travels only over the SSH channel
  via `SendEnv`→`AcceptEnv`. Use `SendEnv`, **never** `SetEnv` (SetEnv puts it on the
  remote command line).
- **Host key is pinned.** Ephemeral ed25519 keys per run, `StrictHostKeyChecking=yes`.
  Never disable host-key checking to "make it work."
- **`share.*` allowlist excludes the OAuth credential — airtight by construction.**
  The `share.*` items (settings, claudeMd, commands, agents, skills, and the off-by-default
  plugins/config) are the ONLY things the wrapper stages from `~/.claude` into the seed. The
  credential (`.credentials.json`) is not a `share.*` item and is therefore **never copied into
  the seed at all** — exclusion is by omission, not by filter. Two defenses reinforce this:
  (1) the per-item `cp -aL` only copies the listed paths, so the credential is never touched,
  and (2) a defense-in-depth `find $SEED/claude-config -name .credentials.json -delete` strips
  any nested one that a directory `cp` might drag in (e.g. an agents/ dir that contains a
  credential at a nested path). The guest lays the staged items into a fresh **tmpfs** `~/.claude`
  at boot — there is no 9p config lower, no root-private dir, no overlay whiteout. Claude starts
  unauthenticated; the user's own `/login` or API key authenticates it (ephemerally). Once the
  user runs `/login`, claude writes a fresh **in-VM** token into the tmpfs `~/.claude` — ephemeral,
  dies on exit, contained only by `egressAllowlist`. What the allowlist guards is "the *host's
  stored* credential never crosses," not "the agent never sees any credential." This also avoids
  the OAuth refresh-token rotation that an in-VM auth would otherwise trigger: claude refreshes
  on a stale token, the rotated token dies with the ephemeral tmpfs, and the host's stored
  (now-superseded) token is left invalid — forcing a host `/login`. Excluding the credential
  sidesteps that entirely. Verify: `grep -rl '\.credentials\.json' "$SEED"` → zero hits.
  **`persistClaudeProjects` (opt-in) does not change this:** it mounts only `~/.claude/projects`
  read-write; the credential lives at the `~/.claude` *root*, not under `projects/`, so it is
  never staged and never in that share. Never widen the writable mount to all of `~/.claude`.
- **`~/.claude.json` is staged SANITIZED — its known secret-bearing keys are stripped.** The
  home-root `~/.claude.json` (distinct from the `~/.claude/` dir) is normally non-secret (startup
  flags, project list, `userID`), but it *can* carry MCP server configs with inline secrets. When
  `share.settings` is on (the default), the wrapper stages it through `jq`, dropping
  `mcpServers[].env`, `mcpServers[].headers` and the legacy `primaryApiKey` (the way
  `share.gitConfig` strips `credential.*`); the non-secret structure (incl. the server definitions)
  is kept. **Secure-fail:** if `jq` is missing or the file is not valid JSON, nothing is staged
  (better to lose the config in-VM than leak a token) — hence `jq` is a wrapper `runtimeInput`.
  Verify: a fixture with an MCP env token + auth header + `primaryApiKey` → grep `seed/claude-json`
  for the secrets → zero hits, with `userID` + server name still present (`tests/host.sh` §1b). If
  a new secret-bearing key appears in the schema, add it to the `jq del(...)`.
- **`share.gitConfig` stages only sanitized, non-secret git config.** The wrapper resolves the
  **global** git config host-side (option `programs.ccvm.share.gitConfig`, was `shareGitConfig`)
  and writes `seed/gitconfig` only after dropping every value containing `/nix/store/` (host-only
  tool paths that would dangle) and **all `credential.*` entries** (no host credential — `~/.ssh`,
  `gh` token — ever crosses), force-disabling commit/tag signing, and staging `core.excludesfile`
  by *content*. Keep all four guards. Verify by grepping the seed for any `/nix/store` path or
  `credential` key — expect zero hits.
- **No persistent disk.** Root is tmpfs; the store is a read-only image. Nothing the agent
  does survives exit except host-project edits while `writableCwd=true` — and, when the
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
  `nix.enable`) the writable `/nix/store` overlay upper, opened+mounted in the **initrd** by a fail-open
  LUKS oneshot (key still guest-only). Keep `/home`/secrets in tmpfs. Never stage the key through the seed.
- **`writableCwd=false` means genuinely read-only.** The host tree is the 9p **lower**;
  edits land in a tmpfs **upper** and must not reach the host.
- **Only the CWD is shared.** No `~/.ssh`, `~/.aws`, or home dir crosses the boundary.
- **QEMU is sandboxed; ccvm never runs as host root; 9p shares are `nosuid,nodev`.** QEMU launches
  with `-sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny` so a
  device-emulation/9p/slirp escape of the trust boundary hits a seccomp wall instead of the
  launching user's full privileges (`CCVM_QEMU_SANDBOX=0` is the escape hatch). The wrapper refuses
  host uid 0 — 9p `security_model=none` passthrough as root would let the guest create
  root-owned/setuid files on the host workspace (`CCVM_ALLOW_ROOT=1` overrides). Every 9p share is
  mounted `nosuid,nodev` (deliberately not `noexec` — the workspace needs to run project
  binaries/build scripts). Don't regress any of the three.

## Deliberate defaults — do not reverse

- **Native mirroring is the default.** `writableCwd=true` (live host edits),
  `share.*` allowlist on (settings/claudeMd/commands/agents/skills reuse host `~/.claude`), and
  `share.gitConfig=true` (commit as you, with your aliases/ignores) make ccvm behave like native
  `claude`. Isolation (read-only project, no config) is the **opt-in**. Do not re-propose "secure
  by default" — that was the original spec and was deliberately reversed.
- **RAM-only is the default; the disk pool and in-VM nix are opt-in.** `vmDiskSize=0` (no disk,
  pure RAM) and `nix.enable=false` (read-only `/nix/store`, no in-VM nix, lean closure) are the
  defaults — keep boot fast and the no-disk stance unless asked. The user-facing option is
  `programs.ccvm.nix.enable`; the internal config + guest module use the **same** nested `nix.enable`
  name end to end (the old internal `nixInVm` flag was unified away — `lib/mkccvm.nix` passes the whole
  `nix` attr through). It is **build-time** (it flips `nix.enable` and rebuilds the store as a writable overlay in the
  initrd) — never try to make it a runtime `CCVM_*` env var. Its overlay upper is tmpfs (RAM) by
  default; combine with `vmDiskSize>0` and an initrd LUKS oneshot relocates that upper onto the
  encrypted disk (fail-open to tmpfs), so a large `nix develop` doesn't OOM guest RAM — one shared
  pool also backs `/scratch`. **The guest always boots off the self-contained squashfs store; the
  host store is never the guest's boot store.** To give in-VM nix extra pre-built paths, point it at a
  **binary cache** via `nix.substituters` + `nix.trustedPublicKeys` (typically your own self-hosted
  cache of tweaked deps). These are **pure guest-closure config** — baked into the guest's nix.conf
  (appended to `cache.nixos.org` and nixpkgs' keys), no wrapper token, no seed marker, no mount: a
  binary cache is **HTTP substitution**, reached over the network at line rate, exposing nothing of the
  host. `require-sigs` stays ON — paths must verify against `trustedPublicKeys`. A **public-read** signed
  cache works with zero secrets; a cache behind a token/netrc is **not yet supported** (ccvm carries no
  host credentials — a sanitized netrc-staging path, modeled on `shareGitConfig`, would be the future
  story). Two host-store-reuse predecessors were **deliberately removed — do not re-add either**:
  `mountHostNixStore` (host store as the guest's *boot* store) and `nix.useHostStoreAsCache` (host
  `/nix/store`+DB over **ro 9p** as a `local?root=…` substituter with a `db.sqlite` copy). The cache
  variant was implemented, KVM-verified, then cut: 9p copy ran **slower than downloading** (<1 MiB/s
  vs. network), it punched a hole in the isolation thesis (exposed the *entire* host store ro to the
  agent), and the audience that benefits from caching already runs a real binary cache — which the
  `substituters` option serves cleanly.
- **`agentSudo` is auto, not a fixed default.** The agent has passwordless root in the guest (DevEx,
  `--shell` debugging) EXCEPT when `egressAllowlist` is set, where it auto-drops so the in-guest
  egress firewall can't be flushed by the agent (the firewall is installed by a root systemd unit,
  not the agent, so enforcement survives the drop). **Coupled to it (`guest/default.nix`): Nix
  `trusted-users` is gated on the SAME flag — `[ "root" ] ++ lib.optional cfg.agentSudo "ccvm"` — so
  when sudo is off the agent is also non-trusted. This is load-bearing under `nix.enable`: a Nix
  trusted-user is root-equivalent (a `post-build-hook` runs as root), so leaving the agent trusted
  would hand straight back the root the sudo-drop removes, letting it `nft flush` the firewall (audit
  S-1). A non-trusted agent can still `nix build`/`nix develop`; builds run as the nixbld users.**
  `null` = auto; `true`/`false` force it — but forcing `true` *alongside* an `egressAllowlist`
  re-opens the `nft flush` bypass (and re-grants trusted-user), so it's only sensible behind
  host-side egress control. It's the in-guest half of egress containment — don't quietly flip it back
  to always-on without an equivalent guarantee (host-side enforcement). Build-time (rebuilds the
  guest closure).
- **Guest kernel/userspace hardening is deliberate, cheap, and boot-safe (`guest/default.nix`).**
  A small in-guest defense-in-depth layer against an agent probing the kernel, none of it touching
  the host or the boot-critical path: **`security.protectKernelImage`** (no kexec/hibernation —
  *not* `lockKernelModules`, which would break the seed service's runtime `modprobe` of
  nf_tables/dm_crypt); **sysctls** `kptr_restrict=2`, `dmesg_restrict=1`, `unprivileged_bpf_disabled=1`,
  `bpf_jit_harden=2`, `rp_filter=1`; **`sudo-rs`** (memory-safe Rust sudo, `execWheelOnly`) in place
  of classic C sudo, still gated on `agentSudo`; an **explicit `root.hashedPassword = "!"`**; and a
  pinned **`nix.settings.allowed-users = [ "root" "ccvm" ]`**. Two things are deliberately NOT done:
  `lockKernelModules` (incompatible with runtime modprobe, above) and disabling unprivileged user
  namespaces (the nix build sandbox needs them, and the namespaced-root they grant can't reach the
  init-netns firewall or route packets out — audit-verified, so it's not a containment hole).
- **`extraClaudeMd` is default-on context, not a flag.** A built-in blurb is staged as the
  guest's `~/.claude/CLAUDE.md` (via the seed, **appended** to any host-shared one — never
  clobbering it) so the agent knows it's in ccvm. It must stay seed-delivered, never become
  `--append-system-prompt`, or it breaks transparent passthrough. The wrapper prepends a
  **runtime** mode line (rw=live / overlay=discarded) the build-time file can't know.
- **Transparent passthrough.** The wrapper injects **no** flags. Everything after `ccvm`
  is forwarded to `claude` verbatim, including `--dangerously-skip-permissions` (opt-in by
  the user, never auto-added). The *only* args the wrapper consumes (and does **not**
  forward) are its own: `--shell`, `--ccvm-debug`, `--writable-cwd`,
  `--read-only-cwd`, `--ccvm-help`, `--ccvm-version`. They are deliberately ccvm-specific
  names (none is a claude flag), so bare `--help`/`--version` still reach claude.
  Preserve that interception boundary.

- **Image paste — an image-only reverse clipboard bridge (`clipboard.images`, default-on).**
  Claude Code reads pasted images by shelling out to `xclip`/`wl-paste`
  (`xclip -selection clipboard -t image/png -o`, `wl-paste --type image/png`, detect via
  `… -t TARGETS -o` / `wl-paste -l`). The guest has no X/Wayland and no view of the host
  clipboard, so out of the box Ctrl+V image paste **silently no-ops** — a real DevEx loss.
  ccvm restores it **without** opening any new attack surface by routing claude's clipboard
  command back to the host over the channel that already exists — the management SSH connection:
    1. **Guest shims.** Fake `xclip`/`wl-paste` on the guest PATH (`guest/default.nix`,
       `pkgs.writeShellScriptBin`, gated on `cfg.clipboard.images`). They connect to a fixed
       guest-loopback port (`cfg.clipboard.port`, 9180), send a one-word request
       (`TARGETS`/`image/png`/`image/bmp`) and stream the reply to stdout — mimicking real xclip.
    2. **Reverse tunnel.** The wrapper's `ssh -tt` gains `-R 127.0.0.1:9180:127.0.0.1:<hostport>`.
       sshd is `AllowTcpForwarding = "remote"` (only when the bridge is on) **pinned by
       `PermitListen 127.0.0.1:9180`** — exactly one reverse forward to one loopback port; no
       local/dynamic forwarding, and forwarding is a *client*-requested feature, so the in-guest
       agent can't set up its own.
    3. **Host server.** A `socat` listener (a wrapper `runtimeInput`; zero host setup) the wrapper
       starts before connecting. Per request it runs the **host's** `wl-paste`/`xclip` for
       **image targets only** and returns the bytes. The reader's `case` arms are literal image
       MIME types, so a guest request can neither widen to `text/*` nor inject a command.
  **Why this doesn't weaken the boundary (be precise):** the bridge rides **loopback +
  the established SSH connection** (`oifname lo accept` + `ct state established`), so it punches
  **zero holes** in the egress firewall and works identically under open *and* hardened egress; a
  prompt-injected agent can't repurpose the one pinned forward to reach anything but the host
  clipboard-image server. It is **image-only, enforced host-side** — the server never reads
  `text/plain`, and the shims never *write* the host clipboard — so host clipboard **text** (where
  passwords/tokens live) **never crosses**. That makes it **strictly less** clipboard exposure than
  *native* `claude` (where the agent reads clipboard text *and* images at will). The one honest
  residual, consistent with the documented default posture: under **open egress** a prompt-injected
  agent can *pull* whatever **image** is on the host clipboard at any time (not just on the user's
  paste — the host can't see the Ctrl+V keystroke, so it's pull-on-demand) and exfiltrate it — the
  same class as "the project tree is exfiltratable under open egress," and still less than native.
  Under hardened egress it can read the image but can't send it off-box. The bridge is **inert**
  when the host has no `wl-paste`/`xclip` (the guest shims' connect just fails → paste no-ops) and
  when the build flag is off (no shims, sshd forwarding stays the hardened `no`). Build-time installs
  the guest half; the per-run `CCVM_CLIPBOARD_IMAGES=0` can only **disable** the wrapper-side wiring
  (it can't conjure the missing guest shims/sshd rule on), so re-enabling needs the built default.
  The security-critical image-only guarantee is regression-tested against the **real** reader
  extracted from the wrapper (`tests/clipboard.sh`, the `clipboard` flake check) — no VM needed.
  macOS host is future (its image clipboard needs `osascript`/`pngpaste`, not `pbpaste`).

## Why it's built this way (settled decisions — don't relitigate)

The rationale that used to live in `docs/design.md`. These were considered and decided;
reopening one needs a *new* reason, not a rediscovery of the old trade-off.

- **SSH transport, not the serial console — for PTY fidelity.** The load-bearing choice. A
  serial line is not a terminal: no `SIGWINCH`, no window size, no full termios, so resize
  breaks and `vim`/`less`/full-screen TUIs corrupt. `ssh -tt` to a real sshd gives a genuine
  guest PTY that propagates `TERM`, the initial window size, `SIGWINCH` on every resize, and
  termios end-to-end — so the VM is invisible. `-tt` *forces* PTY allocation even when the
  wrapper's own stdin isn't a tty. The wrapper runs ssh in the foreground but **never `exec`s
  it**, so it regains control to tear the VM down.
- **QEMU + slirp, not firecracker / cloud-hypervisor.** We need outbound HTTPS to the API with
  **zero host setup** — no bridges, TAP devices, or `sudo`. QEMU's built-in slirp gives
  unprivileged user-mode NAT (guest 10.0.2.x, synthesised DNS+DHCP) plus `hostfwd` for the
  inbound SSH port. The lighter VMMs boot faster but make you wire up host networking, which
  breaks "works on a stock box as a normal user." Boot speed matters; running unprivileged
  matters more.
- **Guest can reach the host's loopback via slirp `10.0.2.2` — know this.** slirp maps its gateway
  `10.0.2.2` to the *host's* `127.0.0.1`. Verified: from the guest, `10.0.2.2:22` answers with the
  **host's own sshd** (a different ed25519 host key than the guest's). So under **open egress (the
  default) any host service bound to `127.0.0.1` is reachable from inside the VM** — local databases,
  unauth dashboards/metrics, model servers (e.g. Ollama on 11434), cloud metadata/credential
  proxies, a second concurrent ccvm — many of which are unauthenticated *precisely because* they
  assume only host-local processes reach them. It is **network reach only, not a host-write path**
  (the fs boundary still holds), but it widens what a prompt-injected agent can talk to. An
  `egressAllowlist` closes it (`10.0.2.2` isn't in the set, so `policy drop` blocks it) — subject to
  the same in-guest-enforcement caveat as everything else (a root agent could `nft flush` it → hence
  `agentSudo`). There is **no slirp knob to keep internet but drop only the host redirect**
  (`restrict=on` kills both), so the only complete fix is the host-side namespace under "Egress"
  below. Matters most when ccvm runs on a box with sensitive loopback-bound services.
- **Egress: an allowlist, not Tor.** Tor solves *anonymity*, which is orthogonal — the dominant
  flow is the Anthropic API authenticated with the user's own credential, so Tor hides the
  source IP while the app layer still identifies you exactly (self-defeating), adds latency, and
  hits Tor-exit blocking. It's also redundant: the guest egresses through the *host* stack, so a
  user who wants anonymity runs Tor/VPN on the host and the guest rides it for free. Egress
  *control* (where the agent may connect) belongs in ccvm; *anonymization* belongs on the host.
  The IP-filter MVP leaves three residual channels the packet filter alone doesn't fully address:
  **FQDN staleness** (the kernel sees IPs, so FQDNs are host-pre-resolved at launch into pinned
  A/AAAA records. The *host* (launch-time) and *guest* (runtime) resolvers would otherwise disagree
  for round-robin / CDN hosts — the host pins one member of the pool, the guest dials another, and
  the firewall silently drops it; verified, `egressAllowlist=["github.com"]` pinned the host's
  snapshot while the guest resolved a github.com IP outside it and the SYN hung. ccvm closes this by
  pinning the *guest* resolver to the host's resolution: the wrapper stages a name→IP map
  (`egress-hosts`) and the guest writes it into `/etc/hosts` (a real file swapped in over the store
  symlink — `/etc` is tmpfs — and resolved reloaded), so the agent resolves each allowlisted FQDN to
  exactly an IP the firewall allows. It is staged host-side (reliable DNS), needs no guest DNS at
  boot, and is fail-open. Residual: a host that rotates *every* pinned IP away mid-session breaks
  (the /etc/hosts pin shadows upstream, so no re-resolution) — restart, or pin a CIDR for hosts that
  churn that hard, e.g. GitHub's ranges at api.github.com/meta. The pin is session-static; a future
  SNI-filtering proxy would drop it entirely); **DNS tunneling** (DNS is pinned
  to the slirp stub resolver, blocking DNS-to-anywhere, but low-bandwidth tunneling through the
  recursive resolver remains); **TCP-only** (QUIC/UDP 443 is dropped; clients fall back to TCP).
  And the load-bearing caveat: **enforcement lives in the guest, so it only binds a non-root agent.**
  The nftables ruleset is installed by a root systemd unit, but a root agent in the same guest could
  `nft flush` it (verified trivially). That is why setting `egressAllowlist` auto-drops the agent's
  sudo (`agentSudo`) **and, under `nix.enable`, drops it from Nix `trusted-users`** — a trusted-user
  is root-equivalent (a `post-build-hook` runs as root), so the audit (S-1) showed that with
  `nix.enable` the sudo-drop alone was bypassable end-to-end (`nix build --post-build-hook` →
  `nft delete table inet ccvm` → blocked host reachable); gating trusted-users on the same flag
  closes it. Together they raise the bar from one command to a guest-kernel exploit. The *complete*
  fix is **host-side egress enforcement**: put the allowlist nft in a namespace the guest can't reach,
  with a filtered uplink via an **external** `pasta`/`slirp4netns` (attached by `/proc/$PID/ns/*`).
  The uplink + filtering half is prototyped and works (allowlisted host reachable, all else dropped).
  But integrating it hit a hard **uid/caps/9p trilemma** that makes this a real design decision, not
  a quick build — three constraints can't all hold at once in a plain *unprivileged* userns:
    * **nft needs `CAP_NET_ADMIN`** inside the namespace (pasta/slirp4netns have no IP allowlist);
    * **9p `security_model=none` ownership** needs QEMU's effective host uid to be the real user and
      the guest agent's uid to match QEMU's namespace view, or rw-mode writes are unreadable to it;
    * **caps don't survive `execve` for a non-root uid.** So `unshare --map-current-user` (uid
      preserved → 9p OK) *loses* `CAP_NET_ADMIN` the instant it execs — **verified: `nft` fails with
      "Operation not permitted"** — while `--map-root` *keeps* caps (nft works) but maps the user to
      uid 0, so QEMU's 9p view reports the workspace as uid 0 and the agent must then *also* run as
      guest-uid-0 for rw to work. `--runas` can't bridge it (the process needs caps **and** the right
      uid at once).
  Two ways out were considered. **(b) is RULED OUT:** `--map-root` + running the in-guest agent as
  uid 0 would keep 9p consistent, but **claude-code hard-refuses `--dangerously-skip-permissions`
  when euid==0** ("cannot be used with root/sudo privileges for security reasons" — verified) — and
  that flag is ccvm's flagship. So the agent must NOT be uid 0, which rules out the whole map-root
  family. That leaves **(a):** host `/etc/subuid` + `newuidmap` (a setuid helper) to map a uid
  *range*, so one userns can hold uid 0 (for nft's `CAP_NET_ADMIN`) AND the real uid (QEMU runs there
  → native 9p, agent stays non-root). Clean and correct, but it needs **host setup**, which cuts
  against ccvm's "works as a normal user, zero setup" principle. Plus the orchestration itself
  (external pasta attached by `/proc/$PID/ns/*`, ready/uplink handshake, TTY-foreground `ssh -tt`,
  dual cleanup, then `setpriv`-drop QEMU to the real uid) is a delicate boot-path rework needing a
  human `--shell` pass. **Net: host-side enforcement is only viable as (a), gated on host subuid
  setup.** `agentSudo` is the shipped interim and already raises exfil from one `sudo` to a
  guest-kernel exploit; (a) would raise it to a full QEMU escape — a marginal gain for real setup
  cost, so it stays opt-in/future unless someone needs that last increment. Don't re-attempt map-root.
- **Encrypted disk, not a plain ephemeral one.** Wipe-on-exit must survive a crash that skips
  the cleanup trap, and on modern storage plain deletion ≠ erasure (async SSD TRIM, CoW
  snapshots retain freed blocks). With FDE the key dies with guest RAM at power-off, so the image
  is inert ciphertext the instant QEMU stops — trap or no trap. The trap `rm` is
  belt-and-suspenders; the guarantee rests on the key being gone.
- **One encrypted pool, not a second `/nix/store` disk.** Once the disk is encrypted with a
  guest-RAM key, disk-vs-tmpfs makes no confidentiality difference to an in-guest attacker (it
  can read tmpfs or decrypt the disk equally). The right split is *bulk on the encrypted disk,
  secrets in tmpfs* — by **placement**, not a second sized disk. A second disk only earns its
  keep for a different *lifecycle* (a persistent, content-addressed store cache) — a separate
  future feature with its own key story, deliberately **not** folded into `vmDiskSize`.
- **9p for the shares, not virtiofs (and the large-tree edge case).** The workspace/seed/config/
  projects shares ride virtio-9p — zero host daemon, unprivileged, fits the zero-setup goal. 9p
  with `cache=none` (the default) is latency-bound on *metadata*: each `stat`/`open`/`readdir` is
  a host round-trip, so a **cold whole-tree walk** (a fresh `rg`/`git status`/`fd` over the entire
  tree) is sluggish, while the agent's normal localized loop (read a few files, edit, build) feels
  native. Calibration for the realistic audience: **systemd-scale (~4k files) is a non-issue; the
  Linux kernel (~85k files, ~1.5 GB) is the usable ceiling** — fine except the occasional cold
  whole-tree grep; past that (giant monorepos, 100k+ tiny files) it crawls, but that isn't ccvm's
  user. The real-world worst case is a huge gitignored dir (`node_modules`/`.venv`/`target`), and
  that's already handled: `rg`/`fd` skip gitignored paths, and bulk build output belongs on
  `/scratch` (`vmDiskSize`, native ext4). **virtiofs would be faster but is a deliberate non-goal
  pre-1.0:** it needs a per-share `virtiofsd` daemon + a shared-memory guest backend (reworking the
  core QEMU `-m` args, the cleanup trap that reaps the daemons, and the uid-remap/`security_model=none`
  passthrough path), a multi-day change that reopens every share's security verification — for a
  problem the audience rarely hits. The cheap lever *if* a kernel-scale user ever complains: bump
  9p `msize` and add a **mode-aware** cache (`cache=loose`/`mmap` is fine for the ro overlay
  lower/config/seed, but risks stale reads on the live **rw** workspace where host and guest both
  write — keep it conservative there). Don't reach for virtiofs without that benchmark first.
- **No published binary cache (first-run stays a local build).** Considered for `nix run` speed
  and declined. Most of the guest closure already substitutes from `cache.nixos.org`, so first-run
  is **bounded** — mostly download + the ccvm-specific squashfs/toplevel build (~minutes), not a
  giant compile. And re-serving the **unfree** `claude-code` path from a public cache is a
  **redistribution** problem (it's exactly why `cache.nixos.org` doesn't carry it). Net: bounded
  win, licensing headache — not worth it. Don't re-propose a public cache without a new reason; if
  first-run ever genuinely hurts, the lever is shrinking the closure, not redistributing claude-code.

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

  Boot it under `tcg`/`q35`, grep the output. This is exactly how `share.*` and
  `writableCwd` were verified end-to-end — much faster than booting the real agent.
- `nix flake check` should pass — and is **warning-clean**. It builds the guest image, shellchecks
  the wrapper, and runs `tests/host.sh` (the `checks.<sys>.host` derivation) — host-side secret
  hygiene, config staging, verbatim argv, mode selection — against the real wrapper driven by its
  `CCVM_DRYRUN` hook (no VM, no claude-code). Both former "unknown flake output" warnings were real,
  avoidable naming issues (not cosmetic): the home-manager module is exposed as **`homeModules`**
  (the name stock Nix recognizes — `homeManagerModules` warns, verified on Nix 2.34.7; don't
  reintroduce it), and the `ccvmParts` catch-all is gone. Buildable guest artifacts are honest
  packages: `nix build .#guest-store` (ro squashfs store) or `.#guest-toplevel` (system closure).
  The non-derivation bring-up handles (`append`, the evaluated `guestSystem`) are deliberately
  **not** flake outputs; introspect them with a direct import — e.g. dump any guest config value:

  ```bash
  nix eval --impure --expr 'let p = (builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.x86_64-linux;
    in (import ./lib/mkccvm.nix { pkgs = p; } { nix.enable = true; egressAllowlist = ["x"]; }).guestSystem.config.nix.settings.trusted-users'
  ```
- **Rebuilding the guest from inside a hardened-egress ccvm needs `storage.googleapis.com`.** Any
  build that re-realizes the guest closure — `nix flake check`'s `guest-image`/`wrapper` checks,
  `tests/boot.nix`, or `nix build .#ccvm` — must fetch the **unfree** `claude-code`, whose
  fixed-output derivation downloads from `storage.googleapis.com` (deliberately never on a binary
  cache — see "No published binary cache"). That host is NOT in a typical `egressAllowlist`
  (cache.nixos.org / github / npm), so from *inside* a hardened ccvm such a build hangs, then fails
  with `cannot download claude from any mirror` — the egress firewall doing its job, not a bug. Add
  `storage.googleapis.com` to the allowlist when you need to rebuild ccvm in-VM. The host-side
  checks (`checks.<sys>.{host,egress}`) don't pull claude-code, so they build fine under any egress
  posture (and are the way to verify wrapper-side changes without a VM).
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
- **aarch64-linux is best-effort.** It evaluates and is wired up (`qemu-system-aarch64`, the
  `virt` machine, PL011 `ttyAMA0` console), but x86_64-linux is the primary, CI-built target.

## Conventions

- **Commit automatically once all checks pass when working through a task list.** When working a
  multi-step task, run the relevant checks (`bash -n`, the `host.sh` dry-run recipe, and — on a
  Nix+KVM box — `nix flake check` / `bash tests/boot.sh` / a `--shell` pass for TTY changes); if
  they're green, commit without stopping to ask per item. Still surface anything that can only be
  verified on the Nix+KVM box so it gets checked there before being claimed done.
- **Don't touch `README.md` without an explicit go-ahead.** The user owns the README. Propose
  changes (even a one-word fix to a dangling reference) and wait for an explicit OK before
  editing it — unlike the rest of the tree, it is not auto-fixable under the commit-on-green rule.
- **Audience split — write to the right altitude.** The README is **newcomer-facing**:
  approachable, for people new to ccvm and non-technical evaluators. **CLAUDE.md is for the
  technical reader** — security nuts, contributors — and is where the deep detail, threat-model
  nuance, edge cases, and settled-decision rationale live. When something surfaces, put the
  friendly version (if any) in the README and the real depth here, not the other way round.
- **Commit trailer (exact):** `Co-authored-by: Claude <noreply@anthropic.com>` — lowercase
  `authored-by`, bare `Claude`, no model name. This intentionally differs from the Claude
  Code CLI default; use *this* form.
- **Config flows through `@TOKENS@`.** Scalars are baked at build time in `mkccvm.nix`
  (`@MODE@` = `rw`/`overlay`, `@SHARE_SETTINGS@`/`@SHARE_CLAUDEMD@`/`@SHARE_COMMANDS@`/
  `@SHARE_AGENTS@`/`@SHARE_SKILLS@`/`@SHARE_PLUGINS@`/`@SHARE_CONFIG@` = `1`/`0`, etc.).
  Values only known at launch — the workspace 9p share and SSH port — are **not** baked;
  the wrapper builds those QEMU args at runtime (the microvm.nix "runtime-share trap").
- **Runtime override pattern:** a `CCVM_*` env var overrides the baked default for one run
  (`CCVM_WRITABLE_CWD`, `CCVM_SHARE_SETTINGS`, `CCVM_SHARE_CLAUDEMD`, `CCVM_SHARE_COMMANDS`,
  `CCVM_SHARE_AGENTS`, `CCVM_SHARE_SKILLS`, `CCVM_SHARE_PLUGINS`, `CCVM_SHARE_CONFIG`,
  `CCVM_MLOCK`, `CCVM_ACCEL`); an explicit `ccvm` flag wins over the env var.
  Back-compat: `CCVM_SHARE_CLAUDE_CONFIG=0|1` toggles all claude items at once; per-item
  vars win over it.
- **`acceleration` is a declarative mode, baked as `@ACCELERATION@` (`auto`/`kvm`/`tcg`).** `auto`
  (default) uses KVM when `/dev/kvm` is usable else falls back to TCG, **never** erroring on accel —
  the friction-free first run; it uses `-cpu max` (not `host`) so QEMU's own `-accel kvm:tcg` runtime
  fallback stays valid on a present-but-broken KVM. `kvm` *requires* KVM: it hard-errors with an
  actionable reason (missing device / not in the `kvm` group / not writable) and uses `-accel kvm`
  (no fallback) + `-cpu host`. `tcg` forces emulation. Per-run: `CCVM_ACCEL`. The boot-wait budget is
  generous for anything that might run emulated (`ACCEL != kvm`) — the cap is a timeout, not a wait,
  so it never slows a fast KVM boot. The KVM-usability probe only checks the device is writable (it
  can't detect a present-but-broken KVM) — so a real `KVM_CREATE_VM` failure surfaces as QEMU's error
  (`kvm` mode) or a silent runtime fallback to TCG (`auto`). Tests drive the modes via `CCVM_KVM_DEV`
  (internal seam) to simulate `/dev/kvm` states portably.
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
- **The guest interactive shell is zsh, which has no `/dev/tcp`.** Any in-guest TCP-connect probe
  (egress checks against the allowlist, the clipboard-bridge `127.0.0.1:9180` reader — e.g. the
  ones in `tests/security-reverification.md`) relies on bash's `/dev/tcp` pseudo-device; under the
  guest's zsh it fails with `no such file or directory` and *falsely* reads as BLOCKED/dead. Wrap
  such probes in `bash -c`. Test artifact only — the real clipboard shims are bash scripts
  (`writeShellScriptBin`), so they hit `/dev/tcp` fine.
- **9p `msize` is negotiated DOWN.** `guest/launcher.nix` requests `msize=1048576` (1 MiB), but
  QEMU's virtio-9p caps the *effective* value (≈`512000` in practice — `grep msize /proc/mounts`).
  Harmless (the request is clamped, not rejected), but don't trust the requested number when
  reasoning about 9p throughput, and don't bother raising it past what QEMU will grant.
- **`vmDiskSize` adds ~4–5s to boot — the encrypted disk's device-settle + per-boot `luksFormat`.**
  Measured baselines under KVM (8 vCPU / 8 GiB), so you don't rediscover them: a full boot is
  ~7.3s (≈277ms kernel + 3.9s initrd + 3.1s userspace), and `systemd-analyze blame`'s top units are
  the `vdb` / `virtio-ccvm-scratch` device settling at ~4.6s — the undeclared scratch disk waiting on
  `udevadm settle` plus the initrd LUKS-format. The pure-RAM default (`vmDiskSize=0`) boots faster;
  this cost is **inherent to the wipe-on-exit guarantee** (a fresh `luksFormat` every boot, by
  design — see "Encrypted disk, not a plain ephemeral one"), not a regression, so don't chase it
  without first confirming the disk is the cause. Other measured references: **warm 9p is a
  non-issue** (a 768-file repo walk ≈70ms, `git status` ≈100ms — the cold whole-tree caveat still
  stands for kernel-scale trees), and a **running session sits around ~0.7–0.8 GiB RAM** because the
  squashfs store and the writable-store overlay upper live on the (encrypted) disk, not in RAM.
