# home-manager module: programs.ccvm.* -> installs the `ccvm` command.
#
# Each option feeds lib/mkccvm.nix, which builds a self-contained guest image and bakes
# it into the wrapper. Changing memory/cores is cheap (runtime QEMU args); changing
# package/extraPackages/mountHostNixStore rebuilds the guest closure.
{ config, lib, pkgs, ... }:
let
  cfg = config.programs.ccvm;
  mkCcvm = import ../lib/mkccvm.nix { inherit pkgs; };
  ccvmPkg = (mkCcvm {
    inherit (cfg)
      package autoUpdateFiles memory cores extraPackages mountHostNixStore
      apiKeyVariable shareClaudeConfig shareGitConfig lockGuestMemory
      egressAllowlist egressPorts extraGuestModules;
  }).wrapper;
in
{
  options.programs.ccvm = {
    enable = lib.mkEnableOption "ccvm — ephemeral microVM wrapper for Claude Code";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.claude-code;
      defaultText = lib.literalExpression "pkgs.claude-code";
      description = "The claude-code package to run inside the VM (unfree; override/pin as you like).";
    };

    autoUpdateFiles = lib.mkOption {
      type = lib.types.bool;
      default = true;
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
      default = 4096;
      description = ''
        VM RAM in MiB. Per-run override without a rebuild: `CCVM_MEMORY=<MiB> ccvm …`
        (memory is a runtime QEMU arg) — handy for a heavy `nix develop` / build closure.
      '';
    };

    cores = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "VM vCPUs.";
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "with pkgs; [ go gopls nodejs python3 ]";
      description = "Extra packages available inside the VM (project toolchains). A sensible base set is always included.";
    };

    mountHostNixStore = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Share the host /nix/store read-only instead of building a self-contained image (smaller/faster, less isolated).";
    };

    apiKeyVariable = lib.mkOption {
      type = lib.types.str;
      default = "ANTHROPIC_API_KEY";
      description = "Name of the host env var carrying the Anthropic API key. Passed to the VM only over the encrypted SSH channel (SendEnv); never written to disk or argv.";
    };

    shareClaudeConfig = lib.mkOption {
      type = lib.types.bool;
      default = true;
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

    shareGitConfig = lib.mkOption {
      type = lib.types.bool;
      default = true;
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

    lockGuestMemory = lib.mkOption {
      type = lib.types.bool;
      default = false;
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
      default = [ ];
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
      default = [ 443 ];
      description = "Destination ports the egress allowlist permits (only used when egressAllowlist is non-empty). Add 80 for plain-HTTP mirrors/redirects.";
    };

    extraGuestModules = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [ ];
      description = "Extra NixOS modules merged into the guest configuration (escape hatch).";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ ccvmPkg ];
  };
}
