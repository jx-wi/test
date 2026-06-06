# Guest-side runtime glue, all driven by the read-only "seed" 9p share the host
# wrapper populates per invocation (/run/ccvm-seed):
#
#   * ccvm-seed.service  — a boot oneshot (root) that mounts the seed, installs the
#     SSH host key + authorized_keys, and mounts the workspace per mode. Doing every
#     privileged mount here (ordered Before=sshd) means the ForceCommand launcher can
#     run completely unprivileged: it only cd's and exec's.
#
#   * ccvm-guest-launch  — the sshd ForceCommand. Reads the seed, cd's to the
#     workspace, and exec's either zsh (debug) or claude with the forwarded args.
{ config, lib, pkgs, ... }:
let
  cfg = config.ccvm;

  # 9p mount options shared by every share. msize=1M keeps 9p throughput tolerable
  # for editing source trees; access=any + security_model=none on the host side means
  # host uids pass straight through (uid 1000 host == ccvm in the guest).
  p9 = "trans=virtio,version=9p2000.L,msize=1048576,access=any";

  claudeBin = if cfg.claudePackage != null then "${cfg.claudePackage}/bin/claude" else "claude";

  launcher = pkgs.writeShellApplication {
    name = "ccvm-guest-launch";
    runtimeInputs = [ pkgs.coreutils pkgs.zsh ];
    text = ''
      seed=/run/ccvm-seed

      # Where the host CWD lives, mirrored at the identical absolute path (mounted by
      # ccvm-seed.service). Fall back to home so a misconfigured boot still lands somewhere.
      workdir="$(cat "$seed/workdir" 2>/dev/null || true)"
      [ -n "$workdir" ] && [ -d "$workdir" ] || workdir="$HOME"
      cd "$workdir"

      # Debug fidelity shell instead of claude.
      if [ "$(cat "$seed/shell" 2>/dev/null || echo 0)" = "1" ]; then
        # Non-interactive escape hatch: if the client sent a remote command (ssh host 'cmd'),
        # run it under a login shell rather than the interactive TUI. Gated on debug shell
        # mode, so normal claude launches can never be diverted into arbitrary command exec.
        if [ -n "''${SSH_ORIGINAL_COMMAND:-}" ]; then
          exec zsh -lc "$SSH_ORIGINAL_COMMAND"
        fi
        exec zsh -l
      fi

      # Reconstruct the forwarded argv. NUL-separated on the wire so spaces/quotes/globs
      # survive intact — never rebuilt by string-splitting.
      args=()
      if [ -f "$seed/claude-args" ]; then
        mapfile -t -d "" args < "$seed/claude-args"
      fi

      # The API key arrived over the encrypted SSH channel (SendEnv -> AcceptEnv) and is
      # already in our environment here; it is never read from the seed or any file.
      # No flags are injected — claude gets exactly the forwarded argv. The VM is the
      # safety boundary, so --dangerously-skip-permissions is yours to opt into via
      # `ccvm --dangerously-skip-permissions`, not something ccvm forces on you.
      exec ${claudeBin} "''${args[@]}"
    '';
  };

  seedSetup = pkgs.writeShellApplication {
    name = "ccvm-seed-setup";
    runtimeInputs = [ pkgs.coreutils pkgs.util-linux pkgs.shadow pkgs.gnugrep ];
    text = ''
      seed=/run/ccvm-seed
      mkdir -p "$seed"

      # No seed share attached (e.g. a bare debug boot)? Leave a usable system and bail
      # cleanly so the serial console still reaches a login.
      if ! mountpoint -q "$seed"; then
        mount -t 9p -o ${p9},ro ccvm-seed "$seed" 2>/dev/null || {
          echo "ccvm-seed: no seed share; skipping (debug boot)"; exit 0;
        }
      fi

      # SSH identity: copy to tmpfs with strict perms (sshd refuses group/world-readable
      # host keys, and the 9p uid mapping is not guaranteed to satisfy StrictModes).
      install -D -m 600 "$seed/ssh_host_ed25519_key"     /etc/ssh/ssh_host_ed25519_key
      install -D -m 644 "$seed/ssh_host_ed25519_key.pub" /etc/ssh/ssh_host_ed25519_key.pub
      install -D -m 644 -o root -g root "$seed/authorized_keys" /etc/ccvm/authorized_keys

      # Match the agent user (ccvm, baked uid 1000) to the *host* user's uid/gid so 9p
      # passthrough (security_model=none) gives correct ownership in rw mode. Without this a
      # host user whose uid != 1000 sees the workspace owned by a foreign uid — the agent
      # can't write its own project, and files it creates land on the host owned by 1000.
      # The ids are non-secret integers from the read-only seed (the wrapper wrote `id -u`/
      # `id -g`). Done BEFORE the workspace/config setup and Before=sshd, so every later
      # `chown ccvm`/`-o ccvm` and the login session pick up the remapped ids. Best-effort
      # and fail-open: a hiccup must NOT fail the oneshot and block sshd — we keep uid 1000.
      # usermod is safe here (no ccvm process exists yet; sshd hasn't started). `-o` permits
      # a non-unique id (this ephemeral guest has no conflicting accounts to protect).
      host_uid="$(cat "$seed/host-uid" 2>/dev/null || true)"
      host_gid="$(cat "$seed/host-gid" 2>/dev/null || true)"
      if printf '%s' "$host_uid" | grep -qxE '[0-9]+' && [ "$host_uid" != 0 ]; then
        if printf '%s' "$host_gid" | grep -qxE '[0-9]+' && [ "$host_gid" != 0 ] \
           && [ "$host_gid" != "$(id -g ccvm)" ]; then
          groupmod -o -g "$host_gid" users || true
        fi
        if [ "$host_uid" != "$(id -u ccvm)" ]; then
          usermod -o -u "$host_uid" ccvm || true
          # systemd-tmpfiles created /home/ccvm as the old uid; re-own it (small tmpfs home).
          chown -R "$host_uid:$(id -g ccvm)" /home/ccvm || true
        fi
      fi

      workdir="$(cat "$seed/workdir")"
      mode="$(cat "$seed/mode")"
      mkdir -p "$workdir"

      if [ "$mode" = "rw" ]; then
        # autoUpdateFiles=true: edits land on the host live.
        mount -t 9p -o ${p9} ccvm-workspace "$workdir"
      else
        # autoUpdateFiles=false (default): host tree read-only as the overlay lower,
        # a tmpfs upper for the agent's ephemeral edits. Writes never reach the host.
        mkdir -p /run/ccvm-lower /run/ccvm-upper /run/ccvm-work
        mount -t 9p -o ${p9},ro ccvm-workspace /run/ccvm-lower
        chown ccvm:users /run/ccvm-upper /run/ccvm-work
        mount -t overlay overlay \
          -o lowerdir=/run/ccvm-lower,upperdir=/run/ccvm-upper,workdir=/run/ccvm-work \
          "$workdir"
      fi

      # Optional host-config path: surface the host's ~/.claude (settings, custom commands,
      # global memory, OAuth credential) inside the VM as the read-only lower of an overlay,
      # with a tmpfs upper for claude's own writes — so its state is usable but ephemeral and
      # never persists back to the host. The home-root ~/.claude.json is staged via the seed
      # (it is config, not the secret token) and installed into the writable home.
      if [ -f "$seed/share-config" ]; then
        mkdir -p /run/ccvm-host-claude
        if mount -t 9p -o ${p9},ro ccvm-config /run/ccvm-host-claude 2>/dev/null; then
          install -d -m 700 -o ccvm -g users /home/ccvm/.claude
          mkdir -p /run/ccvm-claude-upper /run/ccvm-claude-work
          chown ccvm:users /run/ccvm-claude-upper /run/ccvm-claude-work
          mount -t overlay overlay \
            -o lowerdir=/run/ccvm-host-claude,upperdir=/run/ccvm-claude-upper,workdir=/run/ccvm-claude-work \
            /home/ccvm/.claude
          # Lay the host-dereferenced config files (home-manager symlinks the wrapper
          # resolved on the host) over the overlay. They land in the writable tmpfs upper,
          # shadowing the now-dangling symlinks the 9p lower carries, so claude can actually
          # read settings.json et al. Per-file chown (never `chown -R` the overlay root —
          # that would copy every lower file up into the tmpfs). Best-effort: a hiccup here
          # must not fail the oneshot and block sshd.
          if [ -d "$seed/config-deref" ]; then
            find "$seed/config-deref" -type f -print0 | while IFS= read -r -d "" f; do
              rel="''${f#"$seed/config-deref/"}"
              dst="/home/ccvm/.claude/$rel"
              mkdir -p "$(dirname "$dst")" && rm -f "$dst" \
                && cp "$f" "$dst" && chown ccvm:users "$dst"
            done || true
          fi
        fi
      fi
      # An `if` (not a trailing `[ -f … ] && …`): under `set -e` a bare conditional as the
      # script's final statement makes the whole oneshot exit non-zero when the file is
      # absent — the common case — which would fail ccvm-seed.service and block sshd.
      if [ -f "$seed/claude-json" ]; then
        install -m 600 -o ccvm -g users "$seed/claude-json" /home/ccvm/.claude.json
      fi
    '';
  };
in
{
  options.ccvm.launcherPackage = lib.mkOption {
    type = lib.types.package;
    internal = true;
    default = launcher;
    description = "The sshd ForceCommand target (cd + exec claude/zsh).";
  };

  config = {
    systemd.services.ccvm-seed = {
      description = "Mount ccvm seed + workspace and install SSH identity";
      wantedBy = [ "multi-user.target" ];
      before = [ "sshd.service" ];
      unitConfig.DefaultDependencies = false;
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${seedSetup}/bin/ccvm-seed-setup";
      };
    };
  };
}
