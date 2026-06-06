# Builds a ccvm wrapper whose `claude` is the stub in stub-claude.sh, for tests/boot.sh.
#
# nixpkgs (pinned, allowUnfree) comes from the flake input; the guest/wrapper sources come
# from the working tree via the relative import of lib/mkccvm.nix — so the boot test
# exercises exactly the code you have checked out. Build it with:
#
#   nix build --impure -f tests/boot.nix
let
  flake = builtins.getFlake (toString ../.);
  pkgs = import flake.inputs.nixpkgs {
    system = builtins.currentSystem;
    config.allowUnfree = true;
  };
  stub = pkgs.writeShellScriptBin "claude" (builtins.readFile ./stub-claude.sh);
in
(import ../lib/mkccvm.nix { inherit pkgs; } { package = stub; }).wrapper
