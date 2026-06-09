{
  description = "ccvm — run Claude Code in a throw-away microVM with zero setup";

  inputs = {
    # nixos-unstable: claude-code is unfree and moves fast.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  # Optional but high-value before going public: a public binary cache so
  # `nix run github:jx-wi/ccvm` pulls the prebuilt guest image instead of compiling the
  # whole NixOS closure on first use (otherwise a newcomer's first run is a multi-minute
  # build). Fill in your cache URL + public key and uncomment; have CI push to the same
  # cache (e.g. cachix). Until then, first run builds locally and is cached only on that host.
  # nixConfig = {
  #   extra-substituters = [ "https://YOUR-CACHE.cachix.org" ];
  #   extra-trusted-public-keys = [ "YOUR-CACHE.cachix.org-1:REPLACE_WITH_PUBLIC_KEY=" ];
  # };

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
      # `nix run github:jx-wi/ccvm` works standalone; defaults mirror native claude
      # (live host edits + shared host config), with isolation available opt-in.
      packages = forAllSystems (system: {
        ccvm = partsAll.${system}.wrapper;
        default = partsAll.${system}.wrapper;
        guest-store = partsAll.${system}.storeImage; # buildable artifact for checks
      });

      apps = forAllSystems (system:
        let
          # `meta` on an app silences the `nix flake check` "lacks attribute 'meta'" warning
          # and gives `nix run`/search a description. Reuse the wrapper's package meta.
          app = {
            type = "app";
            program = "${partsAll.${system}.wrapper}/bin/ccvm";
            meta = partsAll.${system}.meta;
          };
        in
        {
          default = app;
          ccvm = app;
        });

      devShells = forAllSystems (system:
        let pkgs = pkgsFor system; in {
          default = pkgs.mkShell {
            packages = with pkgs; [ qemu openssh shellcheck nixpkgs-fmt ];
          };
        });

      # `nix flake check` builds the guest image, shellchecks the wrapper (via
      # writeShellApplication), and runs the host-side guarantee tests (secret hygiene,
      # config staging, verbatim argv, mode selection) against the real wrapper script
      # driven by its dry-run hook — see tests/.
      checks = forAllSystems (system:
        let pkgs = pkgsFor system; in {
          guest-image = partsAll.${system}.storeImage;
          wrapper = partsAll.${system}.wrapper;
        } // (import ./tests { inherit pkgs; }));

      # The home-manager module that exposes programs.ccvm.* and installs `ccvm`.
      homeManagerModules.default = import ./modules/home-manager.nix;
      homeManagerModules.ccvm = self.homeManagerModules.default;

      # Bring-up / debug handle: raw boot artifacts and intermediate derivations.
      #   nix eval  .#ccvmParts.x86_64-linux.append --raw
      #   nix build .#ccvmParts.x86_64-linux.storeImage
      ccvmParts = partsAll;
    };
}
