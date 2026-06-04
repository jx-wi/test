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
      dangerouslySkipPermissions apiKeyVariable shareHostCredentials extraGuestModules;
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
      default = false;
      description = ''
        false (default, secure): the host project is read-only to the agent; edits are
        ephemeral and vanish on exit; export via `git push`. true: the host project is
        mounted read-write; edits land on the host live — identical to native `claude`.
      '';
    };

    memory = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4096;
      description = "VM RAM in MiB.";
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

    dangerouslySkipPermissions = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run Claude Code with --dangerously-skip-permissions. Default true: the VM is the
        safety boundary, which is the entire premise of ccvm. With autoUpdateFiles=false the
        agent cannot touch the host at all; with true it is confined to the project directory.
      '';
    };

    apiKeyVariable = lib.mkOption {
      type = lib.types.str;
      default = "ANTHROPIC_API_KEY";
      description = "Name of the host env var carrying the Anthropic API key. Passed to the VM only over the encrypted SSH channel (SendEnv); never written to disk or argv.";
    };

    shareHostCredentials = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Read-only mount host Claude credentials into the VM (for OAuth login instead of an API key). Token refresh will not persist back. Reduces isolation.";
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
