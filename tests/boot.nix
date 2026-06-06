# Builds stub-`claude` ccvm wrappers for tests/boot.sh. Returns an attrset so the driver can
# build each posture by attribute:
#
#   nix build --impure -f tests/boot.nix open      # default: open egress, rw/overlay checks
#   nix build --impure -f tests/boot.nix egress     # opt-in allowlist, enforcement checks
#
# nixpkgs (pinned, allowUnfree) comes from the flake input; the guest/wrapper sources come
# from the working tree via the relative import of lib/mkccvm.nix — so the boot test
# exercises exactly the code you have checked out.
let
  flake = builtins.getFlake (toString ../.);
  pkgs = import flake.inputs.nixpkgs {
    system = builtins.currentSystem;
    config.allowUnfree = true;
  };
  stub = pkgs.writeShellScriptBin "claude" (builtins.readFile ./stub-claude.sh);
  mk = cfg: (import ../lib/mkccvm.nix { inherit pkgs; } ({ package = stub; } // cfg)).wrapper;
in
{
  open = mk { };
  # Allowlist example.com only; the stub probes both it (must reach) and a non-listed host
  # (must be blocked). api.anthropic.com is auto-included by the builder regardless.
  egress = mk { egressAllowlist = [ "example.com" ]; egressPorts = [ 443 ]; };
  # Opt-in encrypted disk pool; the stub asserts /scratch is a writable dm-crypt mount.
  # 1 GiB leaves room for the LUKS header + an ext4 (sparse, so it costs ~nothing on disk).
  scratch = mk { vmDiskSize = 1; };
}
