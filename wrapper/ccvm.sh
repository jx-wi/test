# shellcheck shell=bash
#
# ccvm — boot an ephemeral microVM and drop the user straight into Claude Code.
#
# writeShellApplication supplies the shebang and `set -euo pipefail`. The @TOKENS@
# below are substituted with store paths / config at build time by lib/mkccvm.nix.
#
# Flow (see docs/design.md and spec §5): generate throwaway SSH keys, pin the guest
# host key, write a read-only "seed" the guest reads over 9p, boot QEMU headless in the
# background, wait for sshd, then `ssh -tt` into it in the FOREGROUND (never exec — the
# wrapper must regain control to tear the VM down). A single trap guarantees the qemu
# process and the tmpfs scratch dir are gone on every exit path.

# ---- baked-in configuration (build time) -----------------------------------
KERNEL="@KERNEL@"
INITRD="@INITRD@"
STOREIMG="@STOREIMG@"
APPEND="@APPEND@"
MEMORY="@MEMORY@"
CORES="@CORES@"
APIKEYVAR="@APIKEYVAR@"
SHARECLAUDE="@SHARECLAUDE@"
PERSISTPROJECTS="@PERSISTPROJECTS@" # 1 = mount host ~/.claude/projects rw (resume + memory persist); 0 = off
SHAREGIT="@SHAREGIT@" # 1 = stage a sanitized host git config into the guest; 0 = off
CLAUDEMD="@CLAUDEMD@" # path to the baked ccvm-context CLAUDE.md (empty = inject nothing)
MOUNTHOSTSTORE="@MOUNTHOSTSTORE@"
HOSTSTOREPATH="@HOSTSTOREPATH@"
MODE="@MODE@" # rw (autoUpdateFiles=true, default — mirrors native claude) | overlay (secure)
MEMLOCK="@MEMLOCK@" # 1 = mlock guest RAM (lockGuestMemory) so it can't hit host swap; 0 = off
EGRESSALLOW="@EGRESSALLOW@" # space-separated FQDN/IP/CIDR allowlist; empty = open egress (default)
EGRESSPORTS="@EGRESSPORTS@" # space-separated dst ports the allowlist permits (default 443)

# ---- helpers ---------------------------------------------------------------
warn() { printf 'ccvm: %s\n' "$*" >&2; }
die() {
  printf 'ccvm: error: %s\n' "$*" >&2
  exit 1
}

# Animated boot progress on stderr. The wrapper is otherwise silent through wait_for_boot,
# which is slow under TCG and looks hung. PROGRESS is enabled only when stderr is a real
# terminal AND we're not in debug mode (which already streams the guest console to stderr) —
# so redirected stderr / pipelines / the dry-run + test captures see nothing ([[ -t 2 ]] is
# false there), keeping those outputs byte-for-byte clean. Set just before the boot section.
PROGRESS=0
SPINNER_PID=""
# Braille spinner as an ARRAY (not a string sliced with ${s:i:1}: each frame is 3 UTF-8 bytes,
# and bash substring extraction is byte-based in a non-multibyte locale, which would emit a
# partial byte). Array indexing sidesteps the locale dependency entirely.
SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
# Spin in the BACKGROUND so the animation stays smooth no matter how long a boot probe blocks:
# QEMU's slirp accepts the forwarded port immediately, so wait_for_boot's banner read can sit
# for up to its timeout — driving frames from that loop made the spinner freeze for seconds at a
# time. A detached subshell renders ~30 fps independent of the probe cadence. No-op unless
# PROGRESS=1, so tests/pipelines/dry-run (stderr not a TTY) never spawn it.
spinner_start() { # $1 = status text
  [[ $PROGRESS == 1 ]] || return 0
  local msg="$1"
  (
    i=0
    while :; do
      printf '\r\033[K%s %s' "${SPIN[i]}" "$msg" >&2
      i=$(((i + 1) % ${#SPIN[@]}))
      sleep 0.03
    done
  ) &
  SPINNER_PID=$!
}
# Stop the spinner and clear its line so it never bleeds into the TUI or a following message.
# `wait` reaps the subshell so no stray frame can land after we clear (same discipline as the
# debug-tail kill before handing the terminal to ssh -tt). Safe to call when not running.
spinner_stop() {
  [[ -n ${SPINNER_PID:-} ]] || return 0
  kill "$SPINNER_PID" 2>/dev/null || true
  wait "$SPINNER_PID" 2>/dev/null || true
  SPINNER_PID=""
  if [[ $PROGRESS == 1 ]]; then printf '\r\033[K' >&2; fi
}

# shellcheck disable=SC2329  # invoked indirectly via `trap` below, not by name.
cleanup() {
  # Stop the boot spinner / debug log tail first so neither outlives us (e.g. Ctrl-C mid-boot).
  if [[ -n ${SPINNER_PID:-} ]]; then kill "$SPINNER_PID" 2>/dev/null || true; fi
  if [[ -n ${TAILPID:-} ]]; then kill "$TAILPID" 2>/dev/null || true; fi
  # Tear down the VM: ask politely, then insist. Freeing qemu discards all guest RAM,
  # which is the entire ephemeral story — there is no disk state to clean up.
  if [[ -n ${QEMU_PID:-} ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill -TERM "$QEMU_PID" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$QEMU_PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$QEMU_PID" 2>/dev/null || true
  fi
  if [[ -n ${TMP:-} ]]; then
    if [[ ${DEBUG:-0} == 1 ]]; then
      warn "debug mode — scratch dir kept at $TMP (contains logs + ephemeral keys)"
    elif [[ ${DRYRUN:-0} == 1 ]]; then
      : # dry run prints and keeps $TMP itself; leave it for the caller to inspect/remove.
    else
      rm -rf "$TMP"
    fi
  fi
}

# Returns a free localhost TCP port. A connect that fails means nothing is listening, so
# the port is (very likely) free. A tiny TOCTOU race to the qemu bind is acceptable for a
# localhost dev tool (spec §3.2).
pick_port() {
  local p _
  for _ in $(seq 1 50); do
    p=$(((RANDOM % 20000) + 20000))
    # The 2>/dev/null must wrap the whole group: redirections apply left-to-right, so on a
    # bare `exec 3<>… 2>/dev/null` the failing /dev/tcp connect prints "Connection refused"
    # to the still-current stderr *before* 2>/dev/null takes effect. The brace group routes
    # that message to /dev/null while leaving fd 3 open in this shell on success.
    if { exec 3<>"/dev/tcp/127.0.0.1/$p"; } 2>/dev/null; then
      exec 3<&- 3>&- # in use; try another
    else
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

# Wait until the guest sshd answers with its banner. We probe the raw port (not a full
# ssh session) because the sshd ForceCommand would otherwise launch claude on every probe.
wait_for_boot() {
  # Cold TCG (software emulation) boots are far slower than KVM and vary with host load, so
  # a ~36s cap (120 × 0.3s) produces spurious "boot failed" under tcg (the box may still be
  # booting). Give TCG a much longer budget; KVM keeps the snappy cap. CCVM_BOOT_TRIES
  # overrides for pathological cases. Each try is ~0.3s sleep + connect/read overhead.
  # The spinner (if any) animates in the background — see spinner_start — so this loop just
  # probes and sleeps; it never touches the terminal itself.
  local _ banner tries="${CCVM_BOOT_TRIES:-120}"
  [[ -z ${CCVM_BOOT_TRIES:-} && ${ACCEL:-} == tcg ]] && tries=600
  for _ in $(seq 1 "$tries"); do
    kill -0 "$QEMU_PID" 2>/dev/null || return 1
    # Brace group, not a bare `exec … 2>/dev/null`: the connect is attempted before a
    # trailing redirect applies, leaking "Connection refused" to the terminal on every
    # pre-boot probe. See pick_port for the full explanation.
    if { exec 3<>"/dev/tcp/127.0.0.1/$PORT"; } 2>/dev/null; then
      if IFS= read -r -t 2 banner <&3; then
        exec 3<&- 3>&-
        case "$banner" in SSH-*) return 0 ;; esac
      else
        exec 3<&- 3>&-
      fi
    fi
    sleep 0.3
  done
  return 1
}

# ---- argument handling -----------------------------------------------------
# Intercept ccvm-only flags; everything else is forwarded verbatim to claude.
# (We deliberately do NOT claim bare --debug so that `claude --debug` still passes
# through; ccvm's own debug is CCVM_DEBUG=1 or --ccvm-debug.)
SHELL_MODE=0
DEBUG="${CCVM_DEBUG:-0}"
# Host-side test hook: populate the seed and assemble the QEMU args, then stop before
# booting (see the dry-run block just before boot). Not a documented user flag.
DRYRUN="${CCVM_DRYRUN:-0}"
[[ ${CCVM_SHELL:-0} == 1 ]] && SHELL_MODE=1
MODE_OVERRIDE=""
FWD=()
for arg in "$@"; do
  case "$arg" in
    --shell) SHELL_MODE=1 ;;
    --ccvm-debug) DEBUG=1 ;;
    # ccvm-only file-sharing toggles. Consumed here (never appended to FWD), so they are
    # NOT forwarded to claude — claude still receives only the user's own arguments.
    --auto-update-files) MODE_OVERRIDE=rw ;;
    --no-auto-update-files) MODE_OVERRIDE=overlay ;;
    *) FWD+=("$arg") ;;
  esac
done

# File-sharing mode precedence: an explicit ccvm flag wins, else the CCVM_AUTOUPDATE env
# var, else the baked default (autoUpdateFiles, now true by default).
case "${CCVM_AUTOUPDATE:-}" in
  1 | true | yes) MODE=rw ;;
  0 | false | no) MODE=overlay ;;
esac
[[ -n $MODE_OVERRIDE ]] && MODE="$MODE_OVERRIDE"

# Host-config sharing precedence: CCVM_SHARE_CLAUDE_CONFIG overrides the baked default
# (shareClaudeConfig, now true by default). Lets `CCVM_SHARE_CLAUDE_CONFIG=0 ccvm` opt out — or
# `=1` opt back in — on any invocation, without rebuilding the package.
case "${CCVM_SHARE_CLAUDE_CONFIG:-}" in
  1 | true | yes) SHARECLAUDE=1 ;;
  0 | false | no) SHARECLAUDE=0 ;;
esac

# Project-history persistence precedence: CCVM_PERSIST_PROJECTS overrides the baked
# persistClaudeProjects default for one run (mounts host ~/.claude/projects read-write so
# session transcripts + memory survive — `claude --resume` across runs, persistent memory).
case "${CCVM_PERSIST_PROJECTS:-}" in
  1 | true | yes) PERSISTPROJECTS=1 ;;
  0 | false | no) PERSISTPROJECTS=0 ;;
esac

# Git-config sharing precedence: CCVM_SHARE_GIT_CONFIG overrides the baked shareGitConfig
# default for one run, same pattern as above.
case "${CCVM_SHARE_GIT_CONFIG:-}" in
  1 | true | yes) SHAREGIT=1 ;;
  0 | false | no) SHAREGIT=0 ;;
esac

# ccvm-context CLAUDE.md precedence: CCVM_CLAUDE_MD, if SET (even to empty), overrides the baked
# default file for one run — a path names an alternate context file; empty disables injection.
# `+x` distinguishes "set empty" (disable) from "unset" (use the baked @CLAUDEMD@).
[[ -n ${CCVM_CLAUDE_MD+x} ]] && CLAUDEMD="$CCVM_CLAUDE_MD"

# Guest-memory locking precedence: CCVM_MLOCK overrides the baked lockGuestMemory default for
# one run, same override pattern as the toggles above.
case "${CCVM_MLOCK:-}" in
  1 | true | yes) MEMLOCK=1 ;;
  0 | false | no) MEMLOCK=0 ;;
esac

# Guest RAM precedence: CCVM_MEMORY (MiB) overrides the baked `memory` default for one run.
# Memory is a runtime QEMU arg (no rebuild), so a heavy project can ask for more without
# touching config: CCVM_MEMORY=16384 ccvm … . Resolved before the mlock preflight, which
# sizes its RLIMIT_MEMLOCK check against MEMORY.
if [[ -n ${CCVM_MEMORY:-} ]]; then
  if [[ $CCVM_MEMORY =~ ^[1-9][0-9]*$ ]]; then
    MEMORY="$CCVM_MEMORY"
  else
    die "CCVM_MEMORY must be a positive integer (MiB); got '$CCVM_MEMORY'"
  fi
fi

# ---- preflight -------------------------------------------------------------
WORKDIR="$PWD"
[[ -d $WORKDIR ]] || die "current directory '$WORKDIR' is not a directory"

# KVM (near-native) when /dev/kvm is usable, else TCG software emulation. CCVM_ACCEL=tcg
# forces TCG even when /dev/kvm exists — needed under nested virt / CI where the device is
# present but broken.
if [[ ${CCVM_ACCEL:-} == tcg ]]; then
  ACCEL="tcg"
  CPU="max"
elif [[ -w /dev/kvm ]]; then
  ACCEL="kvm:tcg"
  CPU="host"
else
  warn "/dev/kvm is not writable — falling back to software emulation (TCG). This is correct but slow."
  ACCEL="tcg"
  CPU="max"
fi

# Auth is optional. If present, the API key rides the encrypted SSH channel via
# SendEnv -> AcceptEnv — never on disk or argv. With neither a key nor shared host
# config, claude simply starts unauthenticated: run its in-VM `/login` (web/OAuth)
# flow — copy the printed URL into your browser, paste the code back. Anything obtained
# that way lives only in the VM's tmpfs and evaporates on exit (ephemeral, by design).
if [[ $SHELL_MODE != 1 && $SHARECLAUDE != 1 && -z ${!APIKEYVAR:-} ]]; then
  warn "\$$APIKEYVAR is not set and shareClaudeConfig is off — starting Claude unauthenticated. Run /login inside the VM for web auth (its credentials stay in the VM and vanish on exit)."
fi

# mlock preflight: QEMU started with mem-lock=on aborts if it cannot lock the guest RAM, so
# surface a clear, loud hint early instead of a cryptic qemu failure when RLIMIT_MEMLOCK is
# too low. The required lock is the guest RAM plus QEMU's own overhead; we warn when the
# limit is below the guest size (a limit at or just above it can still be borderline).
if [[ $MEMLOCK == 1 ]]; then
  memlock_kib="$(ulimit -l)"
  if [[ $memlock_kib != unlimited ]] && ((memlock_kib < MEMORY * 1024)); then
    warn "============================================================================"
    warn "lockGuestMemory (mlock) is ON, but this shell's RLIMIT_MEMLOCK is too low:"
    warn "    limit:       ${memlock_kib} KiB"
    warn "    guest needs: $((MEMORY * 1024)) KiB (${MEMORY} MiB) + QEMU overhead"
    warn "QEMU will almost certainly fail to start with 'mlock: Cannot allocate memory'."
    warn "Fix it one of these ways:"
    warn "  - this shell only:   ulimit -l unlimited   (then re-run ccvm)"
    warn "  - systemd user units: set LimitMEMLOCK=infinity"
    warn "  - PAM/limits.conf:   add '<user> - memlock unlimited' (then re-login)"
    warn "  - skip locking once: CCVM_MLOCK=0 ccvm ...   (RAM may reach host swap)"
    warn "See README 'Locking guest memory' for details."
    warn "============================================================================"
  fi
fi

# ---- scratch dir + trap ----------------------------------------------------
TMP="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/ccvm.XXXXXX")"
trap cleanup EXIT INT TERM HUP

# ---- ephemeral SSH identities ---------------------------------------------
ssh-keygen -t ed25519 -N "" -q -f "$TMP/id"      # client identity
ssh-keygen -t ed25519 -N "" -q -f "$TMP/hostkey" # guest host key (pinned below)

PORT="$(pick_port)" || die "could not find a free localhost port"

# We generated the guest's host key ourselves, so we can pin it and keep
# StrictHostKeyChecking=yes — no blind TOFU.
printf '[127.0.0.1]:%s %s\n' "$PORT" "$(cat "$TMP/hostkey.pub")" >"$TMP/known_hosts"

# ---- seed (read-only 9p share the guest consumes) --------------------------
SEED="$TMP/seed"
mkdir -p "$SEED"
cp "$TMP/id.pub" "$SEED/authorized_keys"
cp "$TMP/hostkey" "$SEED/ssh_host_ed25519_key"
chmod 600 "$SEED/ssh_host_ed25519_key"
cp "$TMP/hostkey.pub" "$SEED/ssh_host_ed25519_key.pub"
printf '%s' "$WORKDIR" >"$SEED/workdir"
printf '%s' "$MODE" >"$SEED/mode"
printf '%s' "$SHELL_MODE" >"$SEED/shell"
# Host user identity. The guest remaps its agent user (ccvm) to these so 9p passthrough
# (security_model=none) yields correct workspace ownership in rw mode: a host uid != 1000
# would otherwise see the project owned by a foreign uid (agent can't write its own files)
# and create files owned by 1000 on the host. Non-secret integers — never the API key.
printf '%s' "$(id -u)" >"$SEED/host-uid"
printf '%s' "$(id -g)" >"$SEED/host-gid"
# Forwarded argv, NUL-separated so spaces/quotes/globs survive (reconstructed in the
# guest with `mapfile -d ''`). Never reassembled by string-splitting.
if ((${#FWD[@]})); then
  printf '%s\0' "${FWD[@]}" >"$SEED/claude-args"
else
  : >"$SEED/claude-args"
fi
# NOTE: the API key is deliberately absent from the seed.

# ---- assemble QEMU device args --------------------------------------------
MACHINE="${CCVM_MACHINE:-@DEFAULTMACHINE@}"
if [[ $MACHINE == microvm ]]; then
  MACHINE_ARG="microvm,accel=$ACCEL,rtc=on" # rtc=on so the guest clock is correct for TLS
  BUS="device"                              # virtio-mmio transport
else
  MACHINE_ARG="$MACHINE,accel=$ACCEL"
  BUS="pci"
fi

# Root store: a self-contained read-only squashfs by default (max isolation), or the
# host /nix/store shared read-only when mountHostNixStore is set (smaller/faster).
STORE_ARGS=()
if [[ $MOUNTHOSTSTORE == 1 ]]; then
  STORE_ARGS+=(-fsdev "local,id=nixstore,path=$HOSTSTOREPATH,security_model=none,readonly=on")
  STORE_ARGS+=(-device "virtio-9p-$BUS,fsdev=nixstore,mount_tag=ccvm-nixstore")
else
  STORE_ARGS+=(-drive "id=store,file=$STOREIMG,format=raw,if=none,readonly=on")
  STORE_ARGS+=(-device "virtio-blk-$BUS,drive=store")
fi

# Workspace share. security_model=none (passthrough) — not mapped-xattr — so files
# created in rw mode are owned by the host user with real perms (truly native), and no
# .virtfs_metadata pollution is scattered across the project.
WS_FSDEV="local,id=ws,path=$WORKDIR,security_model=none"
[[ $MODE == overlay ]] && WS_FSDEV="$WS_FSDEV,readonly=on"

# Optional: the host's Claude config, read-only — reuse your host login, settings, custom
# commands and global memory inside the VM. The ~/.claude directory rides a read-only 9p
# mount, so the OAuth credential it contains is never copied into the scratch dir. The
# separate home-root ~/.claude.json (non-secret config) is staged through the seed. The
# guest overlays both onto a writable tmpfs, so claude's writes are ephemeral and never
# reach the host.
CONFIG_ARGS=()
if [[ $SHARECLAUDE == 1 ]]; then
  if [[ -d "$HOME/.claude" ]]; then
    # Resolve the root so a home-manager-symlinked ~/.claude is exported as the real dir.
    CFGPATH="$(readlink -f "$HOME/.claude")"
    CONFIG_ARGS+=(-fsdev "local,id=cfg,path=$CFGPATH,security_model=none,readonly=on")
    CONFIG_ARGS+=(-device "virtio-9p-$BUS,fsdev=cfg,mount_tag=ccvm-config")
    printf '1' >"$SEED/share-claude-config"

    # home-manager (and other dotfile managers) populate ~/.claude with symlinks whose
    # targets live OUTSIDE the tree — e.g. settings.json -> /nix/store/…-home-manager-files/…
    # Those targets are absent from the guest, so the symlinks dangle on the read-only 9p
    # mount and claude can't read its config. Stage the *dereferenced contents* of every
    # escaping symlink into the seed; the guest lays them over the overlay so the config is
    # actually readable. .credentials.json is never followed — the OAuth secret keeps riding
    # the read-only 9p mount and is never copied into the seed (§3.7).
    while IFS= read -r -d '' link; do
      rel="${link#"$CFGPATH/"}"
      [[ $rel == ".credentials.json" ]] && continue
      tgt="$(readlink -f "$link" 2>/dev/null)" || continue
      [[ -e $tgt && -r $tgt ]] || continue
      case "$tgt/" in "$CFGPATH/"*) continue ;; esac # internal link: already resolves on 9p
      mkdir -p "$SEED/config-deref/$(dirname "$rel")"
      cp -rL "$link" "$SEED/config-deref/$rel"
    done < <(find "$CFGPATH" -type l -print0 2>/dev/null)
    # Defense in depth: the per-link guard above matches only a *top-level*
    # .credentials.json, but `cp -rL` of an escaping directory symlink can drag a nested
    # one in. The OAuth secret must never reach the on-disk seed (it rides the read-only
    # 9p mount only — §3.7), so strip any .credentials.json the staging produced, at any
    # depth. Invariant check: grep the seed for the credential -> zero hits.
    find "$SEED/config-deref" -name '.credentials.json' -delete 2>/dev/null || true
  fi
  [[ -f "$HOME/.claude.json" ]] && cp "$HOME/.claude.json" "$SEED/claude-json"
fi

# ---- persist ~/.claude/projects (opt-in) -----------------------------------
# Claude stores per-project SESSION TRANSCRIPTS (read by `claude --resume`) and per-project
# MEMORY under ~/.claude/projects/<cwd-slug>/. With shareClaudeConfig those live on the
# read-only overlay lower, so in-VM writes go to the ephemeral tmpfs upper and vanish — a
# session started in ccvm can't be resumed later, and memories don't survive. When opted in we
# mount the host's ~/.claude/projects read-WRITE over that subpath so those writes persist back.
# Scoped to projects/ ONLY: the OAuth credential (~/.claude/.credentials.json, at the ~/.claude
# ROOT, not under projects/) is never in this share, so it is still never written to the host.
PROJECTS_ARGS=()
if [[ $PERSISTPROJECTS == 1 ]]; then
  PROJDIR="$HOME/.claude/projects"
  mkdir -p "$PROJDIR" # create on the host so the share exists even on a first-ever run
  PROJECTS_ARGS+=(-fsdev "local,id=cproj,path=$PROJDIR,security_model=none")
  PROJECTS_ARGS+=(-device "virtio-9p-$BUS,fsdev=cproj,mount_tag=ccvm-claude-projects")
  printf '1' >"$SEED/persist-claude-projects"
fi

# ---- git config passthrough (default on) -----------------------------------
# Native devex: in-VM `git` should commit as you, with your aliases and global ignores —
# like native claude. We stage a SANITIZED copy of your GLOBAL git config into the seed (the
# guest lays it at ~/.config/git/config). Sanitized because home-manager writes absolute
# /nix/store/… paths for the editor/pager/diff tools and the gh credential helper — those
# paths don't exist in the guest, so carried verbatim they would dangle (broken pager) or
# fail commits. So we:
#   * drop any setting whose value points into /nix/store (host-only tool paths),
#   * drop credential.* entirely (no host credentials cross into the VM; ~/.ssh and gh tokens
#     are never shared — `git commit` works, `git push` to an SSH remote is out of scope),
#   * stage core.excludesfile's resolved CONTENT to the guest's default ignore path,
#   * force-disable commit/tag signing (the signing key is deliberately not carried; a leftover
#     gpgsign=true would otherwise break `git commit` in the guest).
# Non-secret config only — never the API key or any credential. Best-effort: a hiccup here must
# not block the launch. Runtime override: CCVM_SHARE_GIT_CONFIG=0|1.
if [[ $SHAREGIT == 1 ]] && command -v git >/dev/null 2>&1 &&
  [[ -n "$(git config --global --list 2>/dev/null)" ]]; then
  staged="$SEED/gitconfig"
  : >"$staged"
  # Global key/value pairs, NUL-delimited (key\nvalue\0) so values with spaces/newlines
  # survive. Keep everything except host-only/store-path settings and credentials.
  while IFS= read -r -d '' pair; do
    key="${pair%%$'\n'*}"
    val="${pair#*$'\n'}"
    case "$key" in
      credential.*) continue ;;                 # no host credentials inside the VM
      core.excludesfile) continue ;;            # staged separately as the default ignore file
      commit.gpgsign | tag.gpgsign) continue ;; # forced off below
    esac
    case "$val" in
      */nix/store/*) continue ;; # home-manager tool path — would dangle in the guest
    esac
    git config --file "$staged" "$key" "$val" || true
  done < <(git config --global --list -z 2>/dev/null)
  # The signing key lives in ~/.ssh / the host keyring and is never shared, so disable signing
  # or `git commit` would fail in the guest.
  git config --file "$staged" commit.gpgsign false || true
  git config --file "$staged" tag.gpgsign false || true
  # Drop the file if nothing survived sanitization beyond the forced gpgsign lines (keeps the
  # guest from installing a near-empty config). user.name/aliases/etc. make it worth staging.
  if [[ "$(git config --file "$staged" --list 2>/dev/null | grep -cv '^\(commit\|tag\)\.gpgsign=')" == 0 ]]; then
    rm -f "$staged"
  fi
  # Global ignore: stage the RESOLVED contents at the guest's XDG-default ignore path so your
  # personal ignores apply even though the host excludesfile path doesn't exist in the guest.
  ex="$(git config --global --path core.excludesfile 2>/dev/null || true)"
  if [[ -n $ex ]]; then
    exreal="$(readlink -f "$ex" 2>/dev/null || true)"
    [[ -n $exreal && -r $exreal ]] && cp -L "$exreal" "$SEED/gitignore"
  fi
fi

# ---- ccvm-context CLAUDE.md (default on) -----------------------------------
# Stage the agent-facing "you are inside ccvm" global memory into the seed; the guest lays it
# at ~/.claude/CLAUDE.md (appending to any host-shared one). Staged via the seed — never a
# claude flag — so transparent passthrough holds. We PREPEND a runtime-accurate note about the
# current file-sharing mode, which the build-time-baked file cannot know (mode is resolved per
# run via flags / CCVM_AUTOUPDATE). Empty CLAUDEMD (extraClaudeMd="" or CCVM_CLAUDE_MD=) => skip.
if [[ -n $CLAUDEMD && -r $CLAUDEMD ]]; then
  {
    printf '# ccvm session\n\n'
    if [[ $MODE == rw ]]; then
      printf 'File edits in the project directory are written LIVE to the host filesystem (autoUpdateFiles=true) — treat changes here as real edits to the user'\''s working tree.\n\n'
    else
      printf 'File edits are kept in an ephemeral overlay and are DISCARDED when the VM exits — they do NOT reach the host (autoUpdateFiles=false). Anything worth keeping must be exported before exit (e.g. committed and pushed, or copied out by the user).\n\n'
    fi
    cat "$CLAUDEMD"
  } >"$SEED/claude-md"
fi

# ---- egress allowlist (opt-in) --------------------------------------------
# Empty baked list => open egress (the native default; no firewall, nothing written to the
# seed). A non-empty list switches the guest to default-deny egress: we resolve any FQDNs
# HERE (the host has working DNS) into IP rules, pass bare IPs/CIDRs through unchanged, and
# hand the guest the resolved set + ports via the seed. api.anthropic.com is always included
# so authentication never breaks even if the user forgot to list it.
if [[ -n ${EGRESSALLOW// /} ]]; then
  : >"$SEED/egress-allow"
  # The "lock down" marker: present whenever the user opted in, independent of how many IPs
  # actually resolved. The guest enforces the firewall on THIS file, not on a non-empty
  # allow set, so an empty allow set fails CLOSED (deny-all) instead of silently reverting to
  # open egress — the allowlist must never degrade into "no containment".
  printf '1' >"$SEED/egress-enforce"
  resolve_into_seed() {
    local entry="$1" ip _
    case "$entry" in
      */* | *:*) printf '%s\n' "$entry" >>"$SEED/egress-allow" ;; # CIDR or IPv6 literal — verbatim
      *[!0-9.]*)                                                   # has a non-IPv4 char => FQDN; resolve to A/AAAA
        while read -r ip _; do
          [[ -n $ip ]] && printf '%s\n' "$ip" >>"$SEED/egress-allow"
        done < <(getent ahosts "$entry" 2>/dev/null)
        ;;
      *) printf '%s\n' "$entry" >>"$SEED/egress-allow" ;; # bare IPv4 — verbatim
    esac
  }
  resolve_into_seed api.anthropic.com
  # Explicit word-split of the space-separated allowlist into an array (keeps shellcheck
  # happy — SC2086 — and makes the intent unambiguous).
  read -ra _egress_entries <<<"$EGRESSALLOW"
  for entry in "${_egress_entries[@]}"; do resolve_into_seed "$entry"; done
  sort -u "$SEED/egress-allow" -o "$SEED/egress-allow"
  # Fail closed, loudly, if the user opted in but NOTHING resolved (no literal IP/CIDR and
  # total DNS failure — even api.anthropic.com). Booting on would either (a) leave egress
  # open were the guest gating on a non-empty set, or (b) start a VM that can't reach the API
  # anyway. Refuse with an actionable message instead. (The guest still fails closed via the
  # enforce marker as defense in depth; this just turns a dead VM into a clear error.)
  if [[ ! -s "$SEED/egress-allow" ]]; then
    die "egressAllowlist is set but nothing resolved (host DNS down?) — refusing to boot rather than run with an unenforceable allowlist. Fix DNS, or add a literal IP/CIDR to the allowlist."
  fi
  # Ports as an nft-ready comma list (squeeze runs of spaces to single commas, trim edges).
  ports_csv="$(printf '%s' "${EGRESSPORTS:-443}" | tr -s ' ' ',')"
  ports_csv="${ports_csv#,}"
  printf '%s' "${ports_csv%,}" >"$SEED/egress-ports"
fi

QEMU_ARGS=(
  -machine "$MACHINE_ARG"
  -cpu "$CPU"
  -m "$MEMORY"
  -smp "$CORES"
  -kernel "$KERNEL"
  -initrd "$INITRD"
  -append "$APPEND"
  "${STORE_ARGS[@]}"
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22"
  -device "virtio-net-$BUS,netdev=net0"
  -fsdev "local,id=seed,path=$SEED,security_model=none,readonly=on"
  -device "virtio-9p-$BUS,fsdev=seed,mount_tag=ccvm-seed"
  -fsdev "$WS_FSDEV"
  -device "virtio-9p-$BUS,fsdev=ws,mount_tag=ccvm-workspace"
  "${CONFIG_ARGS[@]}"
  "${PROJECTS_ARGS[@]}"
  -device "virtio-rng-$BUS"
  -display none
  -monitor none
  -serial "file:$TMP/console.log"
  -no-reboot
)

# Optionally mlock the guest RAM (lockGuestMemory / CCVM_MLOCK) so it can never be paged out
# to the host's possibly-unencrypted swap — keeping in-VM secrets (the API key in the guest
# environment, /login credentials in tmpfs) off host disk. Off by default; QEMU aborts at
# startup if RLIMIT_MEMLOCK is too small (see the preflight warning above).
[[ $MEMLOCK == 1 ]] && QEMU_ARGS+=(-overcommit mem-lock=on)

# ---- dry run (host-side test hook) -----------------------------------------
# CCVM_DRYRUN=1 performs every host-side step — generate keys, populate the seed, run the
# real config-staging loop, assemble the QEMU args — then stops before booting QEMU and
# prints the scratch dir. This is how the security-critical host guarantees are checked
# automatically without a VM: that the API key and the OAuth credential never reach the
# seed, that the forwarded argv round-trips verbatim, that the mode/share flags resolve
# correctly, and that escaping host-config symlinks are staged. The scratch dir is kept
# (the EXIT trap skips the rm under dry run) for the caller to grep, then remove.
if [[ $DRYRUN == 1 ]]; then
  printf '%s\n' "$TMP"
  warn "dry-run: seed populated at $SEED; no VM booted. Scratch kept at $TMP."
  exit 0
fi

# ---- boot ------------------------------------------------------------------
# Enable the boot spinner now (past the dry-run early-exit, so it never runs under a test).
# Only when stderr is a TTY and not in debug mode (whose console tail owns stderr already).
[[ -t 2 && $DEBUG != 1 ]] && PROGRESS=1
boot_msg="booting microVM, waiting for guest sshd…"
[[ $ACCEL == tcg ]] && boot_msg="booting microVM (software emulation — slow), waiting for guest sshd…"

# qemu runs headless in the background with stdio detached from the terminal so it never
# touches the TTY the user's claude session will own.
@QEMU@ "${QEMU_ARGS[@]}" </dev/null >"$TMP/qemu.log" 2>&1 &
QEMU_PID=$!

# In debug mode stream the guest console while it boots (killed before we hand the
# terminal to the TUI, so it never corrupts the screen).
if [[ $DEBUG == 1 ]]; then
  ( tail -n +1 -F "$TMP/console.log" >&2 2>/dev/null ) &
  TAILPID=$!
fi

# Spin while we wait (background; no-op unless PROGRESS=1). Stopped on both paths below.
spinner_start "$boot_msg"
if ! wait_for_boot; then
  spinner_stop # clear the spinner line so the failure dump starts clean
  warn "guest did not come up within timeout. Last console output:"
  tail -n 40 "$TMP/console.log" 2>/dev/null >&2 || true
  tail -n 20 "$TMP/qemu.log" 2>/dev/null >&2 || true
  die "boot failed"
fi
spinner_stop # boot succeeded — clear the line before handing the terminal to ssh -tt

# Stop the debug tail before handing the terminal to the interactive session.
if [[ -n ${TAILPID:-} ]]; then
  kill "$TAILPID" 2>/dev/null || true
  TAILPID=""
fi

# ---- connect (FOREGROUND — never exec, so the trap can tear down the VM) ----
ssh -tt -p "$PORT" -i "$TMP/id" \
  -o UserKnownHostsFile="$TMP/known_hosts" \
  -o StrictHostKeyChecking=yes \
  -o SendEnv="$APIKEYVAR" \
  -o LogLevel=ERROR \
  -o ConnectTimeout=5 \
  ccvm@127.0.0.1
RC=$?

exit "$RC"
