# home-manager module: programs.ccvm.* -> installs the `ccvm` command.
#
# Each option feeds lib/mkccvm.nix, which builds a self-contained guest image and bakes
# it into the wrapper. Changing memory/cores is cheap (runtime QEMU args); changing
# package/extraPackages/nix.enable rebuilds the guest closure.
{ config, lib, pkgs, ... }:
let
  cfg = config.programs.ccvm;
  mkCcvm = import ../lib/mkccvm.nix { inherit pkgs; };
  # Option defaults come from the SAME source mkccvm.nix uses, so a default can't drift
  # between the two. Only the user-facing descriptions live here.
  defaults = import ../lib/defaults.nix { inherit pkgs; };
  ccvmPkg = (mkCcvm {
    inherit (cfg)
      package autoUpdateFiles memory cores extraPackages
      apiKeyVariable shareClaudeConfig persistClaudeProjects shareGitConfig extraClaudeMd
      lockGuestMemory vmDiskSize egressAllowlist egressPorts extraGuestModules
      # programs.ccvm.nix.{enable,substituters,trustedPublicKeys} passes straight through — the
      # internal config and the guest use the SAME nested `nix` name (no nixInVm mapping anymore).
      nix;
  }).wrapper;
in
{
  options.programs.ccvm = {
    enable = lib.mkEnableOption "ccvm — ephemeral microVM wrapper for Claude Code";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaults.package;
      defaultText = lib.literalExpression "pkgs.claude-code";
      description = "The claude-code package to run inside the VM (unfree; override/pin as you like).";
    };

    autoUpdateFiles = lib.mkOption {
      type = lib.types.bool;
      default = defaults.autoUpdateFiles;
      description = ''
        true (default): the host project is mounted read-write; edits land on the host
        live — identical to native `claude`. false (secure): the host project is read-only
        to the agent; edits are ephemeral and vanish on exit; export via `git push`.
        Per-run override: `ccvm --no-auto-update-files` / `--auto-update-files`, or
        `CCVM_AUTOUPDATE=0|1`.
      '';
    };

    memory = lib.mkOption {
      type = lib.types.ints.positive;
      default = defaults.memory;
      description = ''
        VM RAM in MiB. Per-run override without a rebuild: `CCVM_MEMORY=<MiB> ccvm …`
        (memory is a runtime QEMU arg) — handy for a heavy `nix develop` / build closure.
      '';
    };

    cores = lib.mkOption {
      type = lib.types.ints.positive;
      default = defaults.cores;
      description = "VM vCPUs.";
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = defaults.extraPackages;
      example = lib.literalExpression "with pkgs; [ go gopls nodejs python3 ]";
      description = "Extra packages available inside the VM (project toolchains). A sensible base set is always included.";
    };

    nix = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = defaults.nix.enable;
        description = ''
          Enable a usable `nix` inside the VM (in-VM `nix develop`/`nix build`). Off by default —
          the default guest is RAM-only with a read-only /nix/store. When on, the guest is built with
          `nix.enable` and a WRITABLE /nix/store overlay (the read-only store image as the lower, a
          writable upper); nix realises new paths into the upper. Build-time (rebuilds the guest), not
          a runtime env var, because a writable store must be set up in the initrd. The upper is
          tmpfs (RAM) by default — a large `nix develop` will exhaust guest RAM until you also set
          `vmDiskSize`, which relocates the upper onto the encrypted ephemeral disk. Everything stays
          wipe-on-exit.
        '';
      };

      substituters = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = defaults.nix.substituters;
        example = lib.literalExpression ''[ "https://cache.example.com" ]'';
        description = ''
          Extra binary caches (nix substituters) for in-VM nix to pull pre-built paths from, instead
          of rebuilding them. Only meaningful with `nix.enable = true`. Each entry is a substituter
          URL — typically your own self-hosted cache of tweaked/private deps (attic, nix-serve, an S3
          bucket, …). These are appended to the default `cache.nixos.org` (set a per-URL
          `?priority=N` if you want to reorder), and pulled over HTTP at network speed — no mount, no
          host-store exposure. Paths must verify against `trustedPublicKeys`, so signatures stay on
          (require-sigs is NOT disabled). A PUBLIC-READ signed cache works with zero secrets; a cache
          behind a token/netrc is not yet supported (ccvm carries no host credentials — a sanitized
          netrc-staging path, like shareGitConfig, would be needed). Build-time (the URLs are baked
          into the guest's nix.conf); no per-run env override.
        '';
      };

      trustedPublicKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = defaults.nix.trustedPublicKeys;
        example = lib.literalExpression ''[ "cache.example.com:abc123…=" ]'';
        description = ''
          Public keys that verify paths fetched from `nix.substituters` (the `name:base64key` pairs
          a self-hosted cache prints on setup). Appended to nixpkgs' built-in trusted keys. Without
          the matching key, nix refuses a substituter's paths as untrusted — so set this alongside
          `substituters`. Only meaningful with `nix.enable = true`.
        '';
      };
    };

    apiKeyVariable = lib.mkOption {
      type = lib.types.str;
      default = defaults.apiKeyVariable;
      description = "Name of the host env var carrying the Anthropic API key. Passed to the VM only over the encrypted SSH channel (SendEnv); never written to disk or argv.";
    };

    shareClaudeConfig = lib.mkOption {
      type = lib.types.bool;
      default = defaults.shareClaudeConfig;
      description = ''
        true (default): read-only mount the host's ~/.claude config into the VM (and copy
        ~/.claude.json), so it reuses your host login, settings, custom commands and global
        memory instead of authenticating fresh — like native `claude`. home-manager symlinks
        (e.g. settings.json -> /nix/store/…) are dereferenced so they resolve inside the VM.
        Claude's writes go to an ephemeral overlay and do not persist back to the host; the
        OAuth credential is exposed read-only and never copied to disk. false: share nothing
        from ~/.claude (more isolated). Per-run override: `CCVM_SHARE_CLAUDE_CONFIG=0|1`.
      '';
    };

    persistClaudeProjects = lib.mkOption {
      type = lib.types.bool;
      default = defaults.persistClaudeProjects;
      description = ''
        false (default): Claude's writes to ~/.claude/projects inside the VM — per-project
        SESSION TRANSCRIPTS and MEMORY — land in the ephemeral config overlay and vanish on
        exit, so a session started in ccvm cannot be `claude --resume`d in a later run ("ID not
        found") and memories do not survive. true: mount the host's ~/.claude/projects into the
        VM read-WRITE so those writes persist back to the host, making cross-run resume and
        memory work like native `claude`. Deliberately scoped to projects/ ONLY — the OAuth
        credential (~/.claude/.credentials.json) is not under projects/, so it is still never
        written back to the host. Requires shareClaudeConfig in spirit (it is the host ~/.claude
        being shared); works independently too. Per-run override: CCVM_PERSIST_PROJECTS=0|1.
      '';
    };

    shareGitConfig = lib.mkOption {
      type = lib.types.bool;
      default = defaults.shareGitConfig;
      description = ''
        true (default): stage a SANITIZED copy of your global git config into the VM (laid at
        ~/.config/git/config) so in-VM `git` commits as you, with your aliases and global
        ignores — like native `claude`. "Sanitized" means host-only settings that would dangle
        or leak are dropped: any value pointing into /nix/store (home-manager's editor / pager /
        delta / gh credential-helper paths), all credential.* helpers (no host credentials cross
        the boundary — ~/.ssh and gh tokens are never shared), and signing is force-disabled
        (the signing key is deliberately not carried, so a leftover commit.gpgsign would only
        break commits). The global core.excludesfile is staged by content to the VM's default
        ignore path. Commits work as you; pushing to an SSH remote still needs credentials the
        VM does not have (by design). false: stage nothing. Per-run: CCVM_SHARE_GIT_CONFIG=0|1.
      '';
    };

    extraClaudeMd = lib.mkOption {
      type = lib.types.lines;
      default = defaults.extraClaudeMd;
      defaultText = lib.literalExpression "builtins.readFile ../lib/ccvm-context.md";
      description = ''
        Markdown staged as the guest's ~/.claude/CLAUDE.md (global memory) so the agent knows
        it is running inside ccvm — ephemeral, sandboxed, only the project directory shared —
        and adapts (it can be more autonomous; commits work but `git push` to an SSH remote
        does not). It is staged through the read-only seed and laid over the config overlay,
        NOT passed as a claude flag, so ccvm's transparent-passthrough invariant holds. When
        shareClaudeConfig brings a host ~/.claude/CLAUDE.md, this is APPENDED to it (the host
        file is never modified). The wrapper also prepends a runtime-accurate note about the
        current file-sharing mode (rw = edits are live on the host; overlay = edits are
        discarded on exit). Defaults to a sensible built-in blurb; set to "" to inject nothing,
        or replace it with your own. Per-run override: CCVM_CLAUDE_MD=<file> (empty disables).
      '';
    };

    vmDiskSize = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = defaults.vmDiskSize;
      example = 32;
      description = ''
        Opt-in encrypted ephemeral disk, in GiB. 0 (default) keeps the pure-RAM model; a positive
        size (e.g. 32) attaches a raw SPARSE virtio-blk image — created in a disk-backed dir on the
        host, NOT tmpfs — which the guest LUKS-encrypts with a key it generates in its OWN RAM (the
        key never crosses 9p; the host only ever sees ciphertext). It is the VM's writable disk
        POOL for bulk, non-secret data that would otherwise exhaust the RAM-backed tmpfs: currently
        a /scratch mount (build outputs, node_modules/target/.venv, caches), and — once the
        writable-store increment lands — an overlay upper for a writable /nix/store (in-VM `nix
        develop`/`nix build`). HOME and root stay tmpfs, so secrets (/login creds, API key, agent
        memory) never leave guest RAM. Wiped on exit: the key dies with guest RAM (leaving inert
        ciphertext) and the host image is removed. The host image dir is
        ''${XDG_CACHE_HOME:-~/.cache}/ccvm by default (override CCVM_SCRATCH_DIR); a tmpfs target is
        refused unless CCVM_SCRATCH_ALLOW_TMPFS=1. Sparse, so it only consumes what's written up to
        the cap. Per-run override: CCVM_VM_DISK_SIZE=<GiB>|0. See design §3.11.
      '';
    };

    lockGuestMemory = lib.mkOption {
      type = lib.types.bool;
      default = defaults.lockGuestMemory;
      description = ''
        Lock the VM's guest RAM into host memory (QEMU -overcommit mem-lock=on) so it can
        never be paged out to the host's (possibly unencrypted) swap — keeping in-VM secrets
        (the API key in the guest environment, /login credentials in tmpfs) off host disk.
        Off by default; requires a large enough RLIMIT_MEMLOCK or QEMU will not start.
        Per-run override: CCVM_MLOCK=0|1.
      '';
    };

    egressAllowlist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = defaults.egressAllowlist;
      example = lib.literalExpression ''[ "github.com" "registry.npmjs.org" "10.0.0.0/8" ]'';
      description = ''
        Opt-in network egress allowlist. Empty (default) keeps egress fully OPEN, so the
        agent reaches anything like native `claude` (this is the deliberate native-mirroring
        default). A non-empty list switches the guest to a DEFAULT-DENY egress firewall that
        permits only these destinations on `egressPorts`, plus DNS — closing the
        prompt-injection exfiltration channel. Entries may be FQDNs (resolved on the host at
        launch into IP rules; reliable for a session but IP-pins CDN-fronted hosts),
        bare IPs, or CIDRs. `api.anthropic.com` is always auto-included so auth never breaks.
      '';
    };

    egressPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = defaults.egressPorts;
      description = "Destination ports the egress allowlist permits (only used when egressAllowlist is non-empty). Add 80 for plain-HTTP mirrors/redirects.";
    };

    extraGuestModules = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = defaults.extraGuestModules;
      description = "Extra NixOS modules merged into the guest configuration (escape hatch).";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ ccvmPkg ];
  };
}
