# Automated checks for ccvm. Returns an attrset of derivations consumed by the flake's
# `checks` output (so `nix flake check` runs them).
#
# The host-side guarantees (secret hygiene, config staging, verbatim argv, mode selection)
# are tested against the *real* wrapper script driven by its CCVM_DRYRUN hook. We bake it
# with DUMMY boot artifacts here — the dry run stops before QEMU, so kernel/initrd/store
# are never touched — which means this check needs neither a guest build nor claude-code
# and runs in seconds. See tests/host.sh for the assertions and tests/boot.sh for the
# full-boot smoke test that genuinely needs a VM (run manually / locally under TCG).
{ pkgs }:
let
  # The same wrapper template the real build uses, with stand-in boot tokens. Scalars are
  # set to the production defaults (share-config on, rw mode) so the tests exercise the
  # default posture; per-run env vars in host.sh flip them to cover the other branches.
  dryRunWrapper = pkgs.writeShellApplication {
    name = "ccvm";
    runtimeInputs = with pkgs; [ coreutils openssh findutils ];
    text = builtins.replaceStrings
      [
        "@KERNEL@"
        "@INITRD@"
        "@STOREIMG@"
        "@APPEND@"
        "@MEMORY@"
        "@CORES@"
        "@MODE@"
        "@APIKEYVAR@"
        "@SHARECONFIG@"
        "@MOUNTHOSTSTORE@"
        "@HOSTSTOREPATH@"
        "@QEMU@"
        "@DEFAULTMACHINE@"
        "@MEMLOCK@"
      ]
      [
        "/dev/null" # KERNEL    } never read: the dry-run hook exits before boot.
        "/dev/null" # INITRD    }
        "/dev/null" # STOREIMG  }
        "console=ttyS0" # APPEND
        "4096" # MEMORY
        "4" # CORES
        "rw" # MODE          (production default: autoUpdateFiles=true)
        "ANTHROPIC_API_KEY" # APIKEYVAR
        "1" # SHARECONFIG    (production default: shareHostConfig=true)
        "0" # MOUNTHOSTSTORE
        "/nix/store" # HOSTSTOREPATH
        "true" # QEMU        (never invoked under dry run)
        "microvm" # DEFAULTMACHINE
        "0" # MEMLOCK
      ]
      (builtins.readFile ../wrapper/ccvm.sh);
  };
in
{
  host = pkgs.runCommand "ccvm-host-tests"
    {
      nativeBuildInputs = [ pkgs.bash dryRunWrapper ];
    }
    ''
      export CCVM=${dryRunWrapper}/bin/ccvm
      bash ${./host.sh}
      touch "$out"
    '';
}
