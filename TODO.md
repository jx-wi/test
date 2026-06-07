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

- **Branch `main` only** (no git remote yet — every commit is local; the user adds the remote
  on the host when ready, see #5). Done & committed:
  **#1, #2, #3, #4, #5, #6, #7, #8, #9, #10(A+B), #11, #12.** Recent commits (newest first):
  - `961f967` #10-B nixInVm (writable /nix/store overlay + in-VM nix; KVM-verified `nix build` works)
  - `d1bedcf` #10 storeDisk→vmDiskSize rename (single ephemeral disk pool, int GiB)
  - `b6efaee` #10-A storeDisk (encrypted ephemeral /scratch; renamed by d1bedcf)
  - `8f95cee` #10 FDE implementation plan in design §3.11
  - `decad40` #11/#12 persistClaudeProjects (resume + memory persist)
  - `c833b47` #8 extraClaudeMd (ccvm-context staged as the guest's `~/.claude/CLAUDE.md`)
  - `9c15793` #9 boot spinner + guest terminfo fix (terminal fidelity under `--shell`)
  - `db0405f` #10 FDE scratch-disk **design** captured (design.md §3.11; design-only)
  - `2c5008d` #6 flake `meta`
  - `c0c5e97` #7 `shareGitConfig` git passthrough + the `shareHostConfig`→`shareClaudeConfig` rename
  - `b461ca1` #2 egress allowlist merge (branch `egress-allowlist` since deleted)
- **#12 (persistClaudeProjects) DONE & VERIFIED on the Nix+KVM box** (2026-06-06): a real
  cross-run `--resume` worked, and the credential check was clean (host `~/.claude/.credentials.json`
  hash + mtime + size identical before/after a persist run; `find ~/.claude/projects` for any
  credential → zero hits). Committed alongside this TODO refresh.
- **`host.sh` = 46 assertions** (15 base + 2 uid/gid #4 + 1 egress-open #2 + 8 git #7 + 5
  extraClaudeMd #8 + 3 persist #12 + 3 help/version #6 + **7 vmDiskSize #10**); `egress.sh` = 6.
  **46/46 green here** via the dry-run recipe (the recipe below was updated for the
  `@CLAUDEMD@`/`@PERSISTPROJECTS@`/`@VERSION@`/`@VMDISKSIZE@` tokens).
- **`boot.sh` = 31 assertions** — **31/31 VERIFIED on the Nix+KVM box** (base + 5 #7 git + 3 #8
  CLAUDEMD + 4 #10 `vmDiskSize`/scratch + 2 default-lean + 2 #10 `nixInVm` overlay; **+6 (2026-06-07):
  the `nixDisk` posture** — disk-backed `nixInVm` upper: store still overlay, nix present, upper is
  dm-crypt ext4 not tmpfs, /scratch shares the pool + writable), with `nix flake check` clean. #12
  still adds **no** boot assertion (needs a persist-enabled `boot.nix` variant + a host-write check
  — see #12).
- **Baked `@TOKENS@` now number 19** (was 21; the `nix.*` option restructure **dropped
  `@MOUNTHOSTSTORE@` + `@HOSTSTOREPATH@`** when `mountHostNixStore` was removed). The token list and
  value list in BOTH `lib/mkccvm.nix` and `tests/default.nix` must stay balanced at 19 — verify with
  the awk one-liners (a mismatch silently mis-bakes the wrapper). Re-verified here: 19/19 distinct
  tokens in both files, wrapper substitutes with no leftover placeholders, `host.sh` 46/46.
- **#5 resolved:** `jx-wi` is the user's real GitHub handle (no substitution was ever needed);
  repo will live at `github.com/jx-wi/ccvm`. The git remote is the user's to add on the host.
- **RENAME (done, `c0c5e97`):** `shareHostConfig` → `shareClaudeConfig` everywhere (option, env
  `CCVM_SHARE_CLAUDE_CONFIG`, token `@SHARECLAUDE@`, seed marker `share-claude-config`). That is
  why #3 below reads as "dead `shareClaudeConfig` guest option" — it was `shareHostConfig` then.

## ✅ #13 `nix.*` option restructure — DONE & KVM-VERIFIED 2026-06-07 (committed)

**What & why (user decision, 2026-06-07):** collapse the two flat nix/store options into a nested
`programs.ccvm.nix` namespace and pick the *cache* (substituter) model for host-store reuse over the
"overlay lower" model:

```nix
programs.ccvm.nix = {
  enable = false;              # was: nixInVm (in-VM nix: writable overlay store + nix command)
  useHostStoreAsCache = false; # NEW, DECLARED-BUT-UNIMPLEMENTED: host store as a ro build substituter
};
```

`mountHostNixStore` is **removed** (the "boot the guest off the host store" provisioning mode is
gone — the guest now **always** boots the self-contained squashfs, max isolation). Rationale captured
in design §3.11 (L2): the host store stays read-only (an rw mount would let the agent mutate the
host's store — breaks the trust boundary); "lower mount" gives path presence without nix DB validity
(half-broken) and exposes the whole store, so the **substituter** is the chosen mechanism. The option
is declared now so the public API is final; it has **no effect yet** and emits a `lib.warnIf` at eval.

**Internal vs user-facing naming:** only the *user-facing* home-manager surface nests. The
guest/internal build-time flag stays named **`nixInVm`** (in `guest/default.nix`, `lib/mkccvm.nix`,
`lib/defaults.nix`, `tests/boot.nix`) — the home-manager module maps `cfg.nix.enable -> nixInVm`. This
kept the guest-closure churn (the Nix+KVM-only part) minimal.

**Files changed (working tree, NOT committed):** `wrapper/ccvm.sh` (dropped `MOUNTHOSTSTORE`/
`HOSTSTOREPATH` vars + the store-source `if`, store is always squashfs), `lib/mkccvm.nix` (dropped
`@MOUNTHOSTSTORE@`/`@HOSTSTOREPATH@` tokens+values → **21→19**; dropped `mountHostNixStore` from the
guest eval; wrapped the wrapper in `lib.warnIf config.useHostStoreAsCache`), `lib/defaults.nix`
(`-mountHostNixStore`, `+useHostStoreAsCache`), `modules/home-manager.nix` (nested `nix` submodule +
mkCcvm mapping), `guest/default.nix` (removed the option + simplified `roStore` to always-squashfs),
`tests/default.nix` (dropped the 2 tokens), plus docs (README options table + In-VM-nix section,
design §3.4 + §3.11, CLAUDE.md deliberate-defaults bullet).

**Verified:** token balance **19/19** in both files; substituted wrapper has no leftover `@…@`;
`bash -n` clean; **`host.sh` 46/46** (host-side, here). On the Nix+KVM box: **`nix flake check` clean**
(only the pre-existing cosmetic `homeManagerModules`/`ccvmParts`/aarch64 warnings) + **`tests/boot.sh`
31/31** (the `nix`/`nixDisk` postures use the internal `nixInVm` key, unchanged). Committed.

**Two follow-ups deliberately NOT done in #13 (briefs below for a fresh session): (14) finish the
rename so `nixInVm` disappears internally too; (15) actually implement `useHostStoreAsCache`.**

---

## 🟡 #14 Finish the rename: internal `nixInVm` → `nix.enable` everywhere — DONE on working tree, KVM-verify pending

**Status (2026-06-07):** implemented on the working tree (NOT yet committed pending the note below).
Took the **deep-merge route**, but with a safer merge than the TODO originally recommended: instead of
`lib.recursiveUpdate` (which recurses into *any* two attrsets — and `package` defaults to a derivation,
i.e. an attrset, so it would silently deep-merge two derivations into a broken Frankenstein), `lib/mkccvm.nix`
does `(defaults // userConfig) // { nix = defaults.nix // (userConfig.nix or {}); }` — a targeted one-level
merge of just the nested `nix` attr (whose children are all scalars). Same correctness (a caller passing
`nix = { enable = true; }` keeps `useHostStoreAsCache`), none of the derivation-merge hazard.

**Files changed:** `lib/defaults.nix` (flat `nixInVm`/`useHostStoreAsCache` → nested `nix = { enable;
useHostStoreAsCache; }`), `lib/mkccvm.nix` (the targeted merge + `inherit (config) nix` into the guest eval
+ `lib.warnIf config.nix.useHostStoreAsCache`), `guest/default.nix` (nested `options.ccvm.nix = { enable;
useHostStoreAsCache; }`; every `cfg.nixInVm` → `cfg.nix.enable`; comments), `modules/home-manager.nix`
(`inherit (cfg) … nix;` — no more `nixInVm =`/`useHostStoreAsCache` mapping; option defaults read
`defaults.nix.{enable,useHostStoreAsCache}`), `tests/boot.nix` (`nix.enable = true` for both the `nix` and
`nixDisk` postures), `tests/boot.sh` + `tests/stub-claude.sh` (assertion labels `nixInVm:`/`nixInVm+disk:`
→ `nix.enable:`/`nix.enable+disk:`), `guest/launcher.nix` (comments), docs (CLAUDE.md, design §3.11 naming
note flipped to "one name end to end", README already on `nix.enable`).

**Verified here:** `bash -n` clean (test scripts + substituted wrapper); `host.sh` **46/46** via the dry-run
recipe (the wrapper + `tests/default.nix` are untouched — `nixInVm` was never a `@TOKEN@`, so host-side is
genuinely unaffected); token balance still **19/19**; `grep -rn nixInVm` returns only TWO intentional doc
mentions (CLAUDE.md + a home-manager comment) explaining that the name was unified away, plus historical
TODO mentions — **zero code hits**.

**STILL TO VERIFY on the Nix+KVM box (the only thing left for #14):** `nix flake check` clean + `bash
tests/boot.sh` 31/31 (now printing `nix.enable:` labels). This is a pure rename/refactor with no behavior
change, but it touches the guest closure (the nested guest option + the mkccvm merge), so Nix eval and a
real boot must confirm it on a capable box before #14 is claimed fully done.

---

### Original brief (for reference)

**Goal (user ask):** after #13 there are TWO names for one thing — the public option is
`programs.ccvm.nix.enable`, but the guest/internal build-time flag is still `nixInVm`, which leaks
into test output (`ok - nixInVm: …`) and guest code. Make `nixInVm` disappear: use `nix.enable`
(and `nix.useHostStoreAsCache`) consistently across the internal config, the guest module, the tests,
and the comments — one name end to end. **Purely a rename/refactor — no behavior change.**

**Why it wasn't done in #13:** to keep the guest-closure churn (the Nix+KVM-only part) minimal while
the API shape was still being decided. The shape is now locked, so collapse the dual naming.

**The one real obstacle — the shallow merge.** `lib/mkccvm.nix` does `config = defaults // userConfig`
(a SHALLOW merge). If the internal config grows a nested `nix = { enable; useHostStoreAsCache; }`,
then a caller passing `nix = { enable = true; }` would REPLACE the whole `nix` attr and silently drop
`useHostStoreAsCache`. So pick ONE:
- **(Recommended) Deep-merge + nested internal name.** Switch the merge to
  `config = lib.recursiveUpdate defaults userConfig`. Safe here: `recursiveUpdate` deep-merges only
  attrsets and replaces lists wholesale (same as `//`), and the only nested attrset would be `nix`;
  all the list options (`extraPackages`, `egressAllowlist`, `egressPorts`, `extraGuestModules`) keep
  their replace-wholesale semantics. Then internal/guest/tests all speak `nix.enable` /
  `nix.useHostStoreAsCache` — exactly matching the public API. **Verify no other option relied on
  shallow-replace of a nested attrset (none do today).**
- (Alternative, lower-effort) Keep the internal config FLAT but rename the key `nixInVm` → `nixEnable`
  (+ keep flat `useHostStoreAsCache`). Avoids touching the merge, but the internal name is `nixEnable`,
  not `nix.enable` — still not a perfect match for the public shape. The user asked for `nix.enable`,
  so prefer the deep-merge route unless it causes trouble.

**Files to touch (deep-merge route):**
- `lib/mkccvm.nix`: `defaults // userConfig` → `lib.recursiveUpdate defaults userConfig`; in the guest
  eval pass `inherit (config) nix;` (the whole nested attr) instead of `nixInVm`; the `lib.warnIf`
  condition becomes `config.nix.useHostStoreAsCache`.
- `lib/defaults.nix`: replace flat `nixInVm` / `useHostStoreAsCache` with
  `nix = { enable = false; useHostStoreAsCache = false; };`.
- `guest/default.nix`: declare a nested `options.ccvm.nix = { enable = mkOption …; useHostStoreAsCache
  = mkOption …; };` (or just `enable` until #15 needs the other); replace EVERY `cfg.nixInVm` →
  `cfg.nix.enable` (there are ~10: the initrd module gates, `storeDiskScript` comment, the `storeFs`
  branch, `nix.enable`/`nix.settings`). Update the comments that say "nixInVm".
- `modules/home-manager.nix`: the `nixInVm = cfg.nix.enable;` mapping line goes away — pass
  `inherit (cfg) nix;` (the whole nested option attr) into `mkCcvm`. (The user-facing option block is
  already nested from #13, so it stays.)
- `tests/boot.nix`: `mk { nixInVm = true; }` → `mk { nix.enable = true; }` (both the `nix` and
  `nixDisk` postures).
- `tests/boot.sh` + `tests/stub-claude.sh`: relabel the `nixInVm:` / `nixInVm+disk:` assertion strings
  and the stub's comments → `nix.enable:` (cosmetic, but it's the whole point — the test output should
  speak the public name).
- `guest/launcher.nix`: the comments mentioning `nixInVm` (~L171, L181, L193) → `nix.enable`.
- Docs: `CLAUDE.md` line ~59 ("(with `nixInVm`)") + the design §3.11 "Naming note" (which currently
  says the internal name stays `nixInVm` — flip it to "now unified as `nix.enable`"); README is
  already on `nix.enable`. Grep for any remaining `nixInVm`.

**Verify (Nix+KVM):** `nix flake check` clean + `bash tests/boot.sh` 31/31 (now printing `nix.enable:`
labels). `host.sh` is unaffected (the rename doesn't touch the wrapper's baked tokens — `nixInVm` was
never a `@TOKEN@`, it's build-time guest config). Final `grep -rn nixInVm .` should return **zero** code
hits (only historical TODO mentions).

**Sequencing:** do **#14 before #15** so the cache implementation is written against the final names.

---

## ⬜ #15 Implement `useHostStoreAsCache` — host store as a read-only build substituter (design §3.11 L2)

**Goal:** make `programs.ccvm.nix.useHostStoreAsCache = true` actually accelerate in-VM `nix
build`/`nix develop` by reusing paths the HOST has already realised, instead of rebuilding/refetching
them. Today the option is a **declared stub** (#13): it only emits a `lib.warnIf` and does nothing.
This task replaces the stub with the real mechanism and **removes the warn**.

**Locked design decisions (from the #13 discussion — do NOT relitigate):**
- The host store is exposed **READ-ONLY**, as a **substituter / binary cache**, NEVER a writable
  mount (an rw host-store mount would let the in-VM agent mutate the host's real `/nix/store` — a hard
  trust-boundary break). Cache only.
- **Substituter, not overlay-lower.** The "mount host store as the overlay lower" approach was
  considered and **rejected**: a bare FS mount makes paths *present* but not nix-DB-*valid*, so nix
  won't trust them for builds; and it exposes the entire host store. The substituter is the standard,
  DB-consistent, better-isolated mechanism (nix pulls only the paths a build needs). See design §3.11.
- The guest **boot** store stays the self-contained squashfs (always). The host store is ONLY a
  build-time/runtime cache *source*, never the live `/nix/store`.
- Only meaningful with `nix.enable = true` (no nix → nothing to substitute for). Consider an assertion
  or warn if `useHostStoreAsCache && !nix.enable`.

**The core nix problem to solve:** nix only trusts a store path as a substitutable input if it is
registered as **valid** in the nix DB. A raw 9p-mounted host `/nix/store` gives files but no validity.
So the implementation has two halves:
1. **Make the host store readable in the guest.** Re-introduce the host-`/nix/store`-over-9p plumbing
   that #13 removed (this is the "repurposed" plumbing referenced in design §3.11) — but mount it at a
   SIDE path (e.g. `/nix/.host-store`), NOT as the live `/nix/store`. Wrapper side: attach the host
   store as a ro 9p share (the old `-fsdev local,…,readonly=on` + `virtio-9p` device, mount_tag e.g.
   `ccvm-hoststore`), gated on a seed marker. This likely re-adds a wrapper token or seed marker
   (decide: build-time `@token@` like the old `@MOUNTHOSTSTORE@`, OR a runtime seed marker so it can be
   a `CCVM_*` per-run override — but note the guest `nix.settings` substituter config is build-time, so
   leaning build-time/baked is most consistent with `nix.enable`).
2. **Register validity so nix will use it.** Options, pick one (spike both if unsure):
   - **(a) Local-store substituter + host DB.** Configure guest
     `nix.settings.extra-substituters = [ "local?root=/nix/.host-store" ]` (or the `file://`/`local`
     store URI form for a chroot store) and make the host's store DB queryable — either share the
     host's `/nix/var/nix/db` read-only too, or stage an exported `reginfo` (`nix-store --dump-db` on
     the host → seed → `nix-store --load-db` in a guest boot oneshot). nix then queries the host store
     for needed paths and copies them into the VM's own writable store (the nixInVm overlay upper),
     registering them as valid. This reuses host *build outputs* generally.
   - **(b) Closure reginfo (narrower).** Use `closureInfo`/`.reginfo` for a *specific* known closure
     loaded at boot — simpler but only helps for pre-declared paths, not arbitrary host-built paths.
     Probably too narrow for the "reuse my host store" intent; (a) is the real feature.
   The design §3.11 "store-DB registration" follow-on is part of this — `reginfo`/`closureInfo` load
   at boot is the mechanism that makes (a) work.
3. **Remove the stub warn** in `lib/mkccvm.nix` (the `lib.warnIf config.useHostStoreAsCache …`) once
   the feature works.

**Security/threat-model notes to honor + document:**
- Exposing the host `/nix/store` ro enlarges the host surface visible to the agent vs. the default
  squashfs-only posture. Store paths are content-addressed PUBLIC packages, so ro exposure is low-risk
  (already argued in design §3.11), but it IS a tradeoff — document it in README + design as the cost
  of the acceleration, and keep it opt-in/off-by-default.
- NEVER expose the host store rw; never share the host's signing keys / nothing secret. The 9p mount is
  `readonly=on`. If sharing the host nix DB, share it ro too.

**Build-time vs runtime:** `nix.enable` is build-time (rebuilds the guest). `useHostStoreAsCache`
changes guest `nix.settings` (build-time) AND needs a runtime host-store 9p attach (wrapper). Simplest
consistent choice: make it build-time too (baked into the guest like `nixInVm`), with the wrapper
attaching the 9p share when the baked flag is on. Revisit if a per-run `CCVM_*` override is wanted.

**Tests (definition of done):**
- New `boot.nix` posture, e.g. `nixCache = mk { nix.enable = true; useHostStoreAsCache = true; }`.
- `stub-claude.sh` reports something verifiable, e.g. `HOSTCACHE:configured` (the host store appears in
  the guest's effective `nix.conf` substituters) and ideally a REAL check: `nix path-info --store
  /nix/.host-store <some-host-path>` succeeds, or a `nix build` of a trivial host-realised path copies
  rather than rebuilds (assert it didn't hit the network / was fast). `boot.sh` asserts these.
- If a wrapper token/marker is added, add a `host.sh` assertion (host store 9p attached, reginfo staged
  if used, NO secret/DB-rw leak into the seed) and rebalance the `@TOKEN@` count (19 → 20) in BOTH
  `lib/mkccvm.nix` and `tests/default.nix` + the host.sh recipe.
- `nix flake check` clean. Per CLAUDE.md, this is Nix+KVM-only — not auto-commit-on-green here.

**Files likely touched:** `wrapper/ccvm.sh` (re-add host-store 9p attach + maybe reginfo staging),
`lib/mkccvm.nix` (pass the flag to the guest, maybe a new token, drop the warn), `guest/default.nix`
(nix.settings substituter + side-path ro mount + reginfo-load oneshot), `lib/defaults.nix` (already
has the default), `modules/home-manager.nix` (already declares the option — update the description from
"not implemented" to live), `tests/{boot.nix,boot.sh,stub-claude.sh,default.nix,host.sh}`, README +
design §3.11 (flip L2 from "planned" to "implemented").

---

## ✅ #10-C cleanup nits — DONE & KVM-VERIFIED 2026-06-07 (pre-public list now clear)

The pre-public feature work is complete: the disk-backed `nixInVm` upper (the hard initrd-LUKS
increment) landed in `2723eef` and is **DONE & KVM-VERIFIED 2026-06-07** — see #10 "Increment C" for
the full record (mount-stacking + fail-open, one shared encrypted pool, `nix flake check` clean +
`tests/boot.sh` 31/31 + a real 8 GiB `nix build`). This batch was **polish only** — small, optional.
None block going public.

**Status (2026-06-07):** all four cleanups DONE, verified, and committed. #4 verified here (host.sh
46/46 via the dry-run recipe); #1–#3 (guest-closure comment/logging edits) **verified GREEN on the
Nix+KVM box** — `nix flake check` clean (only the pre-existing cosmetic `homeManagerModules`/`ccvmParts`/
aarch64 warnings) and `bash tests/boot.sh` **31/31** — then committed. The pre-public list is now clear
apart from the optional, non-blocking #10 L2 / store-DB-registration / #12 persist-boot-assertion items.

**Cleanup candidates (from the #10-C session — low risk, do any/all):**
1. ✅ **Trim the initrd logging** in `guest/default.nix` `storeDiskScript` — DONE (working tree).
   Decided **trim**: dropped the two pure-progress breadcrumbs (`found disk … LUKS-formatting`,
   `LUKS open OK; mkfs …`), kept all fail-open reasons + the single `SUCCESS` line (the initrd has no
   journal handover, so that one line is the only console signal that the upper actually landed on
   disk). `StandardError = "journal+console"` routing unchanged. Now matches the post-boot `/scratch`
   path's "log only what you need to debug a fail-open" discipline (plus the one success line).
2. ✅ **Re-flow the stale comment** in `guest/launcher.nix` (~L168) — DONE (working tree). Lifted the
   invariants common to BOTH branches (key in guest RAM / never on 9p, cryptographic wipe-on-exit,
   fail-open) into a general header that also names the two-case split; moved the format-fresh /
   ext4 / pbkdf2 / size-cap specifics DOWN into the standalone `elif` where they actually happen. The
   shared-pool `if` branch keeps its own local comment.
3. ✅ **`udevadm` dependency** in `storeDiskScript` — DONE (working tree), resolved as **documented
   keep**. There is no narrower provider of `udevadm` than `config.systemd.package` in nixpkgs, and
   systemd is already fully in the initrd, so it adds zero closure — dropping it would only risk losing
   the settle (the `find_dev` retry loop is the real safety net anyway). Added a self-documenting note
   at the call site so it isn't re-flagged. **No code/behavior change** — comment only.
4. ✅ **Re-ran `host.sh`** via the dry-run recipe — **46/46 green** here (2026-06-07). #10-C / this
   session made **no wrapper change**, so host-side is genuinely unaffected; clean re-run closes the
   loop. (Remember the egress branch needs `-e 's#@EGRESSALLOW@##g' -e 's#@EGRESSPORTS@#443#g'` added
   to the recipe, else the lone egress assertion fails — that's a recipe-substitution gap, not a bug.)

**Verification note:** cleanups 1–3 touch the guest closure → they need `nix flake check` +
`tests/boot.sh` on a Nix+KVM box (auto-commit-on-green only after that). #4 was host-side, verified
here via the dry-run recipe below.

**Also still open under #10 (optional, non-blocking, can wait):** L2 — **implement**
`programs.ccvm.nix.useHostStoreAsCache` (the option is DECLARED but not implemented; it warns at
eval). Chosen mechanism: host store as a read-only build **substituter** + store-DB `.reginfo`
registration (the overlay-lower approach was considered and **rejected** — see design §3.11). Plus
the optional #12 persist boot-assertion. See #10 "Remaining" + design §3.11.

## Working on this box without Nix (the key recipe)

The dev box has **no `nix` CLI and no KVM** (stripped NixOS, 2 GB tmpfs root), so `nix flake
check` / `nix build` / `tests/boot.sh` **cannot run here**. But the host-side guarantee tests
*can*, by hand-substituting the wrapper's `@TOKENS@` and running `tests/host.sh` against the
result — this is how every host-side change in this list was verified:

```sh
WRAP=$(mktemp -d)/ccvm
CTX=$(mktemp); printf 'CCVM-CONTEXT-MARKER baked blurb body\n' > "$CTX"   # @CLAUDEMD@ fixture (#8)
{ printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  sed -e 's#@KERNEL@#/dev/null#g' -e 's#@INITRD@#/dev/null#g' -e 's#@STOREIMG@#/dev/null#g' \
      -e 's#@APPEND@#console=ttyS0#g' -e 's#@MEMORY@#4096#g' -e 's#@CORES@#4#g' \
      -e 's#@MODE@#rw#g' -e 's#@APIKEYVAR@#ANTHROPIC_API_KEY#g' -e 's#@SHARECLAUDE@#1#g' \
      -e 's#@PERSISTPROJECTS@#0#g' -e 's#@SHAREGIT@#1#g' -e "s#@CLAUDEMD@#$CTX#g" \
      -e 's#@QEMU@#true#g' -e 's#@DEFAULTMACHINE@#microvm#g' -e 's#@MEMLOCK@#0#g' \
      -e 's#@VERSION@#0.0.0-test#g' -e 's#@VMDISKSIZE@#0#g' \
      wrapper/ccvm.sh
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

## 2. ✅ Default-mode credential-exfil tradeoff + egress allowlist — DONE, MERGED to `main` (`b461ca1`)

**Problem (the block):** in the default posture (`shareClaudeConfig=true` + `autoUpdateFiles=true`
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
  failure it **fails closed** rather than leave egress open. `modprobe nf_tables nf_conntrack` first.
- Tests: `tests/egress.sh` (host-side staging — verbatim IP/CIDR, FQDN resolution, ports) in
  `nix flake check`; `host.sh` asserts default = open; `boot.sh` + stub probe real enforcement.
- Docs: README "Threat model & network egress" section; design §3.10 rewritten "planned →
  implemented (opt-in MVP)"; SNI-proxy noted as the stronger future layer.

**Hardening review applied (`1f394b4`) — most-secure-without-UX-cost on six findings:**
- **A** SC2086 build-breaker fixed (`read -ra`, was unquoted `for entry in $EGRESSALLOW`).
- **B** DNS restricted to the slirp stub resolver (10.0.2.3/fec0::3) — blocks direct
  DNS-to-anywhere; recursive-resolver tunneling documented as residual. Docs softened from
  "closes the exfiltration channel" → "closes the *direct* channel".
- **C** fail-OPEN hole closed: wrapper writes an `egress-enforce` marker (guest enforces on
  THAT, so empty set → deny-all), and the wrapper `die`s if opted-in-but-nothing-resolved.
- **D** fail-closed fallback keeps lo+conntrack+DNS+NDP so the ssh session survives (old bare
  deny-all hung the boot).
- **E** docs: api.anthropic.com CDN IP-pinning can break auth mid-session; dropped "never breaks".
- **F** IPv6 NDP allowed (no v6 black-hole); TCP-only / QUIC-falls-back documented.

**Verified GREEN on the host (pre-merge):** `nix flake check` and `bash tests/boot.sh` 7/7
(allowlisted reachable + non-allowlisted blocked). Merged to `main` via `b461ca1`, conflicts
reconciled (egress forked before #3/#4/#6). ✅ **Re-verified on merged `main`:** the later
Nix+KVM runs under #8/#12 are on the merged tree — `nix flake check` clean + `bash tests/boot.sh`
17/17 with the guest running the uid remap **and** the egress firewall in one boot.

---

## 3. ✅ Dead `shareClaudeConfig` guest option — DONE (`main` working tree)

`guest/default.nix` declared `ccvm.shareClaudeConfig` but **nothing in the guest read it** — the
wrapper does all the sharing work and the guest keys off `seed/share-claude-config`. It was a misleading
option that looked load-bearing.

**Done:**
- Removed the `shareClaudeConfig` option from `guest/default.nix` (replaced with a NOTE comment
  pointing at the real flow: wrapper → `seed/share-claude-config` → `launcher.nix`).
- Stopped passing it into the guest module from `lib/mkccvm.nix` (the `inherit (config) …` list).
- **Left untouched** the genuinely load-bearing host-side path: the home-manager
  `programs.ccvm.shareClaudeConfig` user option → `mkccvm` `config.shareClaudeConfig` →
  baked `@SHARECLAUDE@` in the wrapper. That is the real default knob.

Pure removal of a dead/unread option — no behaviour change. Verified by inspection +
`grep`: the only surviving `shareClaudeConfig` references are the host-side default chain.
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

## 5. ✅ `jx-wi` identity + git remote — DONE (nothing to do in-repo)

`jx-wi` is the user's real GitHub handle, so the references in `flake.nix`, `README.md`,
`LICENSE` are already correct — there were never placeholders to substitute. The only
remaining step is adding the remote, which the **user will do on the host when ready**:
`git remote add origin git@github.com:jx-wi/ccvm.git && git push -u origin main`. (SSH push
works from the host's `~/.ssh`; from inside ccvm it deliberately can't authenticate — see #7.)
No code change needed here.

---

## 6. ✅ Smaller polish — DONE (4 of 4)

- ✅ **`ccvm --ccvm-help` / `--ccvm-version` — DONE.** ccvm's own flags were undiscoverable
  (`--help`/`--version` forward to claude). Added `--ccvm-help` (prints ccvm's flags + the
  `CCVM_*` env knobs) and `--ccvm-version` (prints the baked version). Deliberately
  `--ccvm-`-namespaced so bare `--help`/`--version` still pass through to claude — transparent
  passthrough preserved. Both short-circuit before any VM work (no scratch dir/keys/boot).
  Version baked via a new `@VERSION@` token from `version = "0.1.0"` in `lib/mkccvm.nix`
  (token lists now **20/20** in `mkccvm.nix` + `tests/default.nix`). Files: `wrapper/ccvm.sh`
  (baked `VERSION`, `ccvm_help()`, interception + short-circuit), `lib/mkccvm.nix`,
  `tests/default.nix`, `tests/host.sh` §11 (3 assertions: `--ccvm-version` echoes the baked
  string; `--ccvm-help` prints usage+flags; bare `--version` is forwarded), README + CLAUDE.md.
  **Verified here:** `bash -n` clean; `host.sh` **39/39** via the dry-run recipe (recipe below
  now substitutes `@VERSION@`). **Verified on the Nix box** (`8ab8320`): `nix flake check`
  green — the 20-token `replaceStrings` balance baked correctly through Nix eval (only the
  pre-existing cosmetic `homeManagerModules`/`ccvmParts` warnings). No `boot.sh` change needed
  (the flags exit before boot; `host.sh` §11 covers the output against the real wrapper).
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
- ✅ **Dedupe default values — DONE.** The default VALUES were duplicated between
  `lib/mkccvm.nix` `defaults` and every `modules/home-manager.nix` option `default` (drift
  risk). Extracted them to a single `lib/defaults.nix` (`{ pkgs }: { … }`, all 15 keys);
  `mkccvm.nix` now `import ./defaults.nix` for its merge baseline, and each home-manager option
  does `default = defaults.<name>` (descriptions stay in the module; `defaultText` kept for
  `package`/`extraClaudeMd`). 15 options ↔ 15 keys, verified balanced. **Unverified here**
  (no Nix CLI): `nix flake check` — the default-config `packages.*.ccvm` build reads
  `defaults.nix`, so an eval error there would surface; confirm green on the Nix box.
- ✅ **Add `meta` info to the flake.** `meta` (description/homepage/license=MIT/mainProgram/
  maintainers/platforms) defined once in `lib/mkccvm.nix`, set on the wrapper derivation (via
  `writeShellApplication`'s `meta` arg) and re-exported as `parts.meta`, which the flake's `apps`
  (`ccvm` + `default`) reuse — silences the two "lacks attribute 'meta'" warnings and fixes
  `nix run`/search metadata. (The `homeManagerModules`/`ccvmParts` "unknown flake output"
  warnings are separate, pre-existing, and cosmetic per CLAUDE.md.) **Verified on the Nix box
  (`2c5008d`): the two `meta` warnings are gone.**

---

## 7. ✅ git identity passthrough (`c0c5e97`) + the `git push` export story — DONE

**Done — `shareGitConfig` (default on):** the wrapper stages a SANITIZED copy of the host's
GLOBAL git config into the seed (`seed/gitconfig`/`gitignore`); the guest seed service lays it
at `~/.config/git/config`/`ignore` owned by the (uid-remapped) agent user, so in-VM `git commit`
works as you, with your aliases + global ignores. Sanitization (the home-manager wrinkle: the
config is full of inline `/nix/store` tool paths, not symlinks): drop any value containing
`/nix/store/`, drop all `credential.*` (no host creds cross), stage `core.excludesfile` by
content, force `commit.gpgsign`/`tag.gpgsign` off (signing key never carried). Runtime override
`CCVM_SHARE_GIT_CONFIG=0|1`. New option `programs.ccvm.shareGitConfig`, token `@SHAREGIT@`.
Files: `wrapper/ccvm.sh` (staging block), `guest/launcher.nix` (install), `lib/mkccvm.nix` +
`modules/home-manager.nix` (option/token/default + `git` in wrapper runtimeInputs),
`tests/{host.sh,boot.sh,stub-claude.sh,default.nix}`, README + design §3.7 + CLAUDE.md.
**VERIFIED & COMMITTED (`c0c5e97`):** `tests/host.sh` (the 8 git assertions) green here, and on
the Nix+KVM box `nix flake check` clean + `bash tests/boot.sh` green (the 5 guest-side git
assertions: config present, identity, sanitized, signing off, ignore present).

**✅ The push/export story — RESOLVED (push is host-side by design):** `~/.ssh` is
**deliberately** unshared, so `git push` can't authenticate in the VM. The right model — which
the docs now state plainly — is that **pushing is a host action**: in the default **rw** mode
the agent's commits land in the *host* repo live, so you `git push` from a normal host terminal;
in **overlay** mode you export from the host first. **Decision: the "HTTPS-token push path" idea
is REJECTED, not deferred** — carrying a token (or key) into the VM purely to enable in-VM push
would weaken the core "no credentials / `~/.ssh` ever cross the boundary" invariant for a
capability the host already provides for free. So there is nothing left to build here.
(`core.editor`/bare-command settings transfer as names like `nvim`; git falls back to its
built-ins — guest ships `vim`/`less` — documented.) Docs updated for the rw-vs-overlay framing:
README "git identity" section + design §3.7. Ties into #8 (the CLAUDE.md blurb already tells the
agent commits work but pushes don't).

---

## 8. ✅ `extraClaudeMd` / `extraContext` option — DONE & VERIFIED (`c833b47`)

A `programs.ccvm.extraClaudeMd` (lines) staged as the guest's `~/.claude/CLAUDE.md` so the agent
knows it's inside ccvm (ephemeral, sandboxed, only the project dir shared) and adapts — more
autonomous, knows overlay edits are ephemeral, knows `git commit` works but `git push` doesn't
(ties into #7).

**Design honored:** delivered **via the seed + config overlay, never `--append-system-prompt`**,
so transparent passthrough holds (wrapper still adds zero flags to claude's argv). Default-on
with a sensible built-in blurb (`lib/ccvm-context.md`, read by BOTH `mkccvm.nix` defaults and the
home-manager option default → no string duplication / drift); `extraClaudeMd = ""` disables.

**Done:**
- Default blurb in `lib/ccvm-context.md`. `mkccvm.nix`: `extraClaudeMd` default + `claudeMdFile`
  (baked to a store file, empty string when disabled) + new `@CLAUDEMD@` token. `home-manager.nix`:
  `extraClaudeMd` option (type `lines`) + inherit.
- `wrapper/ccvm.sh`: baked `CLAUDEMD`, runtime override `CCVM_CLAUDE_MD=<file>` (set-empty
  disables, via `+x`), and a staging block that **prepends a runtime-accurate mode line** (rw =
  edits LIVE on host / overlay = edits DISCARDED on exit — the build-time file can't know the
  per-run mode) then the blurb → `seed/claude-md`.
- `guest/launcher.nix`: lays `seed/claude-md` at `~/.claude/CLAUDE.md`, **appending** to any
  host-shared one (copy-up into the overlay upper; host file never touched), owned by the
  remapped agent user.
- Tests: `host.sh` §9 (staged / blurb present / rw-LIVE line / overlay-DISCARDED line / opt-out
  stages nothing); `tests/default.nix` `@CLAUDEMD@` fixture token; `stub-claude.sh` reports
  `CLAUDEMD:present|blurb|mode-rw`; `boot.sh` asserts those in the rw scenario. README
  ("Telling the agent it's in ccvm" + option/env rows), design §3.7, CLAUDE.md (deliberate
  default bullet).

**VERIFIED & COMMITTED (`c833b47`):** `host.sh` 31/31 here; on the Nix+KVM box `nix flake check`
clean + `bash tests/boot.sh` **17/17** (incl. the 3 guest-side CLAUDEMD assertions: present,
blurb, mode-rw).

---

## 9. ✅ Loading & status indicators during boot/wait — DONE & VERIFIED (`9c15793`; +terminfo fix)

The wrapper was silent through `wait_for_boot` (slow under TCG — looked hung). Added a braille
spinner (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) + status text.

**First attempt (reverted): probe-coupled animation.** A `spin_wait` helper animated frames during
the loop's inter-probe `sleep`. It **froze for seconds at a time** in practice: QEMU's slirp
accepts the forwarded port immediately, so each probe's banner `read -r -t 2` can block up to 2s,
and the frames were tied to that loop. User-reported.

**Final: background spinner (`wrapper/ccvm.sh`).**
- `spinner_start`/`spinner_stop`: a detached subshell renders ~30 fps (`sleep 0.03`/frame),
  **independent of the probe cadence**, so the boot-timeout budget is untouched and the animation
  stays smooth no matter how long a probe blocks. `wait_for_boot` is back to a plain `sleep 0.3`.
- `spinner_stop` `kill`s **and `wait`s** the subshell (so no stray frame lands after the clear),
  then clears the line. Called on **both** boot-success (before `ssh -tt`) and failure (before the
  console dump); `cleanup` also kills `SPINNER_PID` for Ctrl-C mid-boot. Same discipline as the
  debug-tail kill.
- Frames are an **array** (not a sliced string — each braille frame is 3 UTF-8 bytes and bash
  substring extraction is byte-based in a non-multibyte locale, which would emit a partial byte).
- `PROGRESS=1` only when **`[[ -t 2 ]]` (stderr is a TTY) AND not `--ccvm-debug`** (debug already
  streams the guest console to stderr), set **past the dry-run early-exit** — so redirected stderr
  / pipelines / dry-run + `host.sh`/`boot.sh` captures never spawn the subshell ⇒ output stays
  byte-clean.

**Also fixed here — terminal fidelity bug (zsh ZLE under `--shell`).** Backspace/quotes corrupted
in the guest shell: the host forwards `$TERM=xterm-ghostty`/`xterm-kitty`, which the guest's
ncurses terminfo DB doesn't know, so ZLE couldn't drive the terminal (visible line desynced from
the edit buffer). Fix: ship the common emulators' own terminfo in `guest/default.nix`
(`alacritty.terminfo foot.terminfo ghostty.terminfo kitty.terminfo wezterm.terminfo` in
`environment.systemPackages`). NB: `environment.enableAllTerminfo` (the obvious knob) **broke in
recent nixpkgs**, hence the explicit list. terminfo outputs are tiny — negligible closure/boot cost.

**Verified here:** `bash -n` clean; `host.sh` **26/26** (the `-t 2` gate keeps it silent under
capture); the background spinner exercised standalone (smooth ~30 fps, stops with no leftover job,
clears the line). **Verified by the user on the Nix+KVM box** (2026-06-06): under
`CCVM_ACCEL=tcg ccvm --shell` the spinner spins smoothly with no multi-second stalls, and the
guest shell line-editing (backspace, etc.) works correctly with the terminfo fix.

---

## 10. 🟡 Disk pool (`vmDiskSize`) + in-VM nix (`nixInVm`) — A, B & disk-backed upper done; L2 + reginfo optional

**Decision (locked 2026-06-06, see design §3.11):** ONE ephemeral encrypted pool, not two disks.
`vmDiskSize` (integer GiB, `0`=off, default off) supersedes the phase-1 `storeDisk` string (pre-
public, so the rename was free). The disk is the VM's writable pool for **bulk, non-secret** data;
**`/home` + root stay tmpfs** so secrets never leave guest RAM. A separate *persistent* store-cache
disk was considered and **deferred** as its own future feature (different lifecycle + key mgmt) —
not folded into `vmDiskSize`. Rejected: putting `/home` on the disk (no in-guest-security gain,
makes the disk load-bearing for boot).

**Increment A — `/scratch` pool — DONE & VERIFIED, then RENAMED.** Originally shipped & KVM-verified
as `storeDisk` (sparse guest-LUKS disk at `/scratch`; key in guest RAM, never on 9p; wiped on exit;
tmpfs-image-dir refused). Now generalized to `vmDiskSize` (int GiB; env `CCVM_VM_DISK_SIZE`; token
`@VMDISKSIZE@`; seed marker `vm-disk`; image `vmdisk-*.img`). host.sh §12 (7 assertions) green here
**46/46** via the dry-run recipe (recipe + balance now `@VMDISKSIZE@`/21). **Rename RE-VERIFIED on
Nix+KVM (2026-06-06):** `nix flake check` clean, `bash tests/boot.sh` 21/21 (the 4 `vmDiskSize`
assertions), and a real `CCVM_VM_DISK_SIZE=4 nix run` showed `/scratch` as a 4 G dm-crypt mount.

**Problem:** the RAM-only model breaks for big **writable** data — `nix develop` realising a multi-GB
closure, large `node_modules`/`target`/`.venv`, build outputs. tmpfs OOMs at `memory=4096`, and
`/nix/store` is a read-only squashfs so you can't `nix build`/`nix develop` into it at all.
the future `nix.useHostStoreAsCache` (L2, not built) will cover the case where the closure is already
realised on the **host** (reuse via a ro substituter); the disk pool is for when the guest must
**write** large data ephemerally. (`mountHostNixStore` — host store as the guest's boot store — was
removed in the #13 `nix.*` restructure; the guest always boots the self-contained squashfs now.)

**Increment A details (the shipped pool):** wrapper validates the GiB int, resolves a disk-backed
image dir (refuses tmpfs unless `CCVM_SCRATCH_ALLOW_TMPFS=1`), sparse `truncate`d image attached as
`virtio-blk serial=ccvm-scratch`, `seed/vm-disk` marker, `cleanup()` rm. Guest: `dm_mod`/`dm_crypt`
modules + `cryptsetup`/`e2fsprogs`; fail-open seed block finds the disk by serial, generates a
64-byte key in guest RAM (never on 9p), `luksFormat` fresh each boot with fast **pbkdf2** (key is
already high-entropy → no memory-hard KDF, keeps TCG boot quick), open, `mkfs.ext4`, mount `/scratch`.
Tests: `host.sh` §12, `boot.nix` `scratch` posture, `stub` `SCRATCH:mounted|writable|encrypted`.

**Increment B — writable `/nix/store` overlay + `nix.enable` (`nixInVm`) — DONE & KVM-VERIFIED
(2026-06-06).** Build-time option `nixInVm` (default off; rebuilds the guest — can't be a runtime
env var since it flips `nix.enable` + the store mount). When on, `/nix/store` is a **declarative
`fileSystems.overlay`** (ro store image lower at `/nix/.ro-store` + **tmpfs** upper at
`/nix/.rw-store`) — far simpler than the feared initrd-LUKS path: the systemd initrd sets the
overlay up with **no custom scripting**, and the tmpfs upper means no LUKS-in-initrd at all for the
RAM case. Files: `lib/defaults.nix` (`nixInVm=false`), `lib/mkccvm.nix` (passed to the guest eval —
**no `@TOKEN@`**, build-time), `modules/home-manager.nix` (option+inherit), `guest/default.nix`
(merged `fileSystems` = `rootFs // storeFs`; `nix.enable = cfg.nixInVm` + flakes/trusted-users).
Tests: `boot.nix` `nix` posture, `stub` reports `STORE:overlay`/`readonly` + `NIX:present`/`absent`,
`boot.sh` asserts default=ro/no-nix and nix-posture=overlay+nix. **Verified:** `nix flake check`
clean, `bash tests/boot.sh` **25/25**, and a real `--shell` ran `nix build`/`nix run nixpkgs#hello`
→ "Hello, world!" with `/nix/store`=overlayfs and the realised path **gone on the host after exit**.
MVP scope: tmpfs upper only, no store-DB registration (nix builds fresh into the upper).

**Verified (increment A):** `host.sh` **46/46** here via dry-run, AND on the Nix+KVM box
(2026-06-06): `nix flake check` clean, `bash tests/boot.sh` (now 25/25), real `CCVM_VM_DISK_SIZE=4`
run showed `/scratch` as a 4 G dm-crypt mount. **Both A & B committed.**

**Increment C — disk-backed overlay upper — DONE & KVM-VERIFIED (2026-06-07).** The `nixInVm` upper is
relocated from tmpfs onto the `vmDiskSize` encrypted disk via an initrd oneshot (`storeDiskScript` +
`boot.initrd.systemd.services.ccvm-store-disk`, gated on `nixInVm`): mount-stacking over the
declarative tmpfs with fail-open, and the post-boot `/scratch` shares the same pool via the
`/run/ccvm-store-on-disk` marker (`lsblk` shows one `ccvm-scratch` crypt backing both). Three
initrd requirements were needed (all nixInVm-gated, in the code): `udevadm settle` (undeclared
scratch disk's by-id lags), `cryptsetup`/`e2fsprogs` in `boot.initrd.systemd.storePaths` directly
(a script's transitive refs aren't pulled in), and `ext4` in the initrd module list. **Verified:**
`nix flake check` clean, `tests/boot.sh` 31/31, and a real `CCVM_VM_DISK_SIZE=8` run building
`nixpkgs#hello` with the upper on a dm-crypt ext4 (see NEXT TASK for detail). Full `bash -n` +
`host.sh` 46/46 hold too (no wrapper change). See design §3.11.

**Remaining (not blocking — `nix develop` with a disk works today):**
- **L2: implement `nix.useHostStoreAsCache`** — host store as a ro **substituter** (host-as-binary-
  cache) + store-DB `.reginfo` registration. The overlay-lower approach was **rejected** (FS mount
  gives path presence but not nix DB validity, and exposes the whole store). Option declared (warns),
  impl pending. See #13 + design §3.11.
- **Store-DB registration** (`closureInfo`/`.reginfo` load at boot) so nix reuses baked paths — a
  boot-time optimization.
- **Watch:** the bigger nix-enabled guest occasionally tripped the boot timeout once (worked on
  retry); if it recurs, bump `wait_for_boot`'s cap for the nix posture / document `CCVM_BOOT_TRIES`.

---

## 11. ✅ Session `--resume` fails across ccvm runs ("ID not found") — ROOT-CAUSED, fixed by #12

**Symptom (user-reported 2026-06-06):** start a Claude session *inside* ccvm, exit, then try to
resume it in a later run (`ccvm --resume` / `-r <id>` — forwarded verbatim to claude) → "ID not
found", even though the session was recent/active.

**Root cause:** Claude stores each session's transcript at `~/.claude/projects/<cwd-slug>/<id>.jsonl`
(`--resume` reads these). With `shareClaudeConfig` (default), `~/.claude` is a **read-only 9p lower
+ tmpfs upper overlay**, so transcripts Claude writes in-VM land in the **ephemeral upper** and are
gone on exit → the next run can't find the ID. (Sessions started with *native* host `claude` DO
resume in-VM — they're on the read-only lower.) The cwd-slug matches the host because ccvm mirrors
the workspace at the identical absolute path, so this is purely a persistence problem, **not** a
slug mismatch.

**Fix:** #12 (`persistClaudeProjects`) — mount `~/.claude/projects` read-write so transcripts
persist back to the host; then cross-run `--resume` works. No separate work item; verifying #12's
boot/resume path closes this too.

---

## 12. ✅ `persistClaudeProjects` — persist session transcripts + memory to the host — DONE & VERIFIED

**Why:** answers #11 (cross-run `--resume`) and the user's ask to **sync in-VM Claude memory back
to the host**. Both live under `~/.claude/projects/<cwd-slug>/` (transcripts = `*.jsonl`, memory =
`memory/`), which is ephemeral today (see #11).

**Design (mirrors the share* options):** opt-in `programs.ccvm.persistClaudeProjects` (default
**false** — keeps the ephemeral stance). When on, the wrapper mounts the host `~/.claude/projects`
into the VM **read-write** (its own 9p share, `mount_tag=ccvm-claude-projects`), and the guest
mounts it over `~/.claude/projects` (on top of the config overlay, or plain tmpfs home if
`shareClaudeConfig` is off) so those writes reach the host. **Scoped to `projects/` ONLY** — the
OAuth credential is at the `~/.claude` *root*, never under `projects/`, so the "credential never
written back" invariant holds (now also a security note in CLAUDE.md). Per-run: `CCVM_PERSIST_PROJECTS=0|1`.

**Done (on the working tree, NOT committed):**
- `lib/mkccvm.nix`: default + new `@PERSISTPROJECTS@` token (lists balanced 19/19).
- `modules/home-manager.nix`: `persistClaudeProjects` option + inherit.
- `wrapper/ccvm.sh`: baked `PERSISTPROJECTS`, `CCVM_PERSIST_PROJECTS` override, `PROJECTS_ARGS`
  writable-share block (`mkdir -p` the host dir, security_model=none, NOT readonly) + `seed/persist-claude-projects` marker; added to the QEMU args array.
- `guest/launcher.nix`: after the shareClaudeConfig overlay, `mount -t 9p ... ccvm-claude-projects`
  at `~/.claude/projects` (no `chown -R` — passthrough + uid-remap give correct ownership and a
  recursive chown over a big history risks an overlay copy-up).
- `tests/default.nix` `@PERSISTPROJECTS@` token; `host.sh` §10 (default = no marker; opt-in writes
  the marker AND creates the host `~/.claude/projects`). README (option + env + "Resuming sessions
  & persisting memory"), design §3.7, CLAUDE.md (2 invariants updated).

**Verified here:** `bash -n` clean; `host.sh` **34/34** via the dry-run recipe (the 3 new §10).
**Verified on the Nix+KVM box (2026-06-06):**
1. `nix run` builds + boots (flake evaluates; 19/19 token balance correct).
2. Real cross-run **resume** worked: `CCVM_PERSIST_PROJECTS=1 ccvm` → printed a resume ID →
   `CCVM_PERSIST_PROJECTS=1 ccvm --resume` found and resumed it; memory persisted to the host.
3. **Credential untouched:** host `~/.claude/.credentials.json` sha256 + mtime + size identical
   before/after a persist run; `find ~/.claude/projects -iname '*credential*'` → zero hits. The
   share is rooted at `$HOME/.claude/projects` (wrapper L404), so 9p can't reach the credential
   one level up.

**Follow-ups (optional):** a dedicated persist-enabled `boot.nix` variant + a guest-write boot
assertion (currently #12 has no boot.sh coverage); consider scoping the share to the current
project's slug instead of all of `projects/` if exposing all history to in-VM writes is a concern.

---

### Cross-cutting notes

- **No git remote yet** (#5): every commit is local-only; `main` is the only branch (the
  `egress-allowlist` branch was merged and deleted). The user adds the remote on the host.
- **#5, #6, #7 done; #10 increments A (`vmDiskSize` `/scratch`) AND B (`nixInVm` writable store +
  in-VM nix) DONE & KVM-VERIFIED (2026-06-06).** Open work left under #10: wiring them together
  (disk-backed overlay upper — the hard initrd-LUKS bit, now DONE #10-C), L2 (`nix.useHostStoreAsCache`
  substituter + store-DB registration; option declared in #13, impl pending). Plus the optional #12
  persist boot assertion. The pre-public list is otherwise clear.
- **Commit trailer:** `Co-authored-by: Claude <noreply@anthropic.com>` (exact form; see CLAUDE.md).
- **Recently done, not a blocker:** `CCVM_MEMORY=<MiB>` per-run guest-RAM override (wrapper + docs
  + `host.sh` tests). The `memory` home-manager option already existed (default 4096); the new bit
  is the env override for heavy `nix develop` closures (ties into #10).
