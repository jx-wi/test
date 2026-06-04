{
  description = "ccvm — run Claude Code in a throw-away microVM with zero setup";

  inputs = {
    # nixos-unstable: claude-code is unfree and moves fast.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true; # claude-code is unfree
      };

      # Default-config ccvm build products for each system (wrapper + guest artifacts).
      partsAll = forAllSystems (system:
        (import ./lib/mkccvm.nix { pkgs = pkgsFor system; }) { });
    in
    {
      # `nix run github:jx-wi/ccvm` works standalone with secure defaults.
      packages = forAllSystems (system: {
        ccvm = partsAll.${system}.wrapper;
        default = partsAll.${system}.wrapper;
        guest-store = partsAll.${system}.storeImage; # buildable artifact for checks
      });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${partsAll.${system}.wrapper}/bin/ccvm";
        };
        ccvm = {
          type = "app";
          program = "${partsAll.${system}.wrapper}/bin/ccvm";
        };
      });

      devShells = forAllSystems (system:
        let pkgs = pkgsFor system; in {
          default = pkgs.mkShell {
            packages = with pkgs; [ qemu openssh shellcheck nixpkgs-fmt ];
          };
        });

      # `nix flake check` builds the guest image and (via writeShellApplication)
      # shellchecks the wrapper.
      checks = forAllSystems (system: {
        guest-image = partsAll.${system}.storeImage;
        wrapper = partsAll.${system}.wrapper;
      });

      # The home-manager module that exposes programs.ccvm.* and installs `ccvm`.
      homeManagerModules.default = import ./modules/home-manager.nix;
      homeManagerModules.ccvm = self.homeManagerModules.default;

      # Bring-up / debug handle: raw boot artifacts and intermediate derivations.
      #   nix eval  .#ccvmParts.x86_64-linux.append --raw
      #   nix build .#ccvmParts.x86_64-linux.storeImage
      ccvmParts = partsAll;
    };
}
