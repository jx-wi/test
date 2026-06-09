# ccvm

**CLI for isolating and securing the Claude Code experience with little-to-no added friction**

***100% reproducible from this repository.***

(CI widget here) [![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

**[About](#About) · [Requirements](#Requirements) · [Usage](#Usage) · [Options](#Options) · [Installation](#Installation) · [Roadmap](#Roadmap) · [License](#License)**

---

## About

  `ccvm` aims to be a drop-in replacement for running `claude`

  Running `ccvm` will automatically whip up a RAM-only NixOS microVM and drop you into the same TUI that running `claude` would.

---

## Requirements

  - Linux
  - Nix

---

## Usage

  ```bash
  ccvm
  ```

---

## Options

  > [!NOTE]
  > This section will describe ccvm options based on their home-manager module's names. See [alternate option declarations](#Alternate option declarations) for configuration via environment variables and/or flags.

  > [!WARNING]
  > Egress is open by default (like native `claude`), so a compromised agent could exfiltrate
  > data — including your OAuth credential when `shareClaudeConfig` is on. Lock it down with
  > `egressAllowlist`, or auth via API key with `shareClaudeConfig = false`. Full threat model: docs/design.md.

  - `enable`: install the `ccvm` command (default: `false`) (types: `true`/`false`)
  - `acceleration`: which acceleration type to use (default: `"auto"`) (types: `"auto"`, `"kvm"`, or `"tcg"`)
  - `apiKeyVariable`: host env var carrying the Anthropic API key, passed to the VM only over SSH (default: `"ANTHROPIC_API_KEY"`) (types: string)
  - `autoUpdateFiles`: sync the CWD `ccvm` is ran in to and from the host and guest (default: `true`) (types: `true`/`false`)
  - `cores`: how many vCPUs to allocate to the VM (default: `4`) (types: positive integers)
  - `egressAllowlist`: FQDN/IP/CIDR egress allowlist — empty = open egress, non-empty = default-deny firewall (default: `[]`) (types: list of strings)
  - `egressPorts`: destination ports the allowlist permits (default: `[ 443 ]`) (types: list of ports)
  - `extraClaudeMd`: markdown staged as the guest's `~/.claude/CLAUDE.md` telling the agent it's in ccvm (default: built-in blurb) (types: lines; `""` disables)
  - `extraGuestModules`: extra NixOS modules merged into the guest, an escape hatch (default: `[]`) (types: list of modules)
  - `extraPackages`: additional packages to install into the VM (default: `[]`) (types: list of strings)
  - `lockGuestMemory`: mlock guest RAM so secrets can't be paged to host swap (default: `false`) (types: `true`/`false`)
  - `memory`: how much RAM in MiB to allocate to the VM (default: `4096`) (types: positive integers)
  - `package`: the claude-code package to run in the VM (default: `pkgs.claude-code`) (types: package)
  - `persistClaudeProjects`: mount `~/.claude/projects` read-write so transcripts + memory persist back (cross-run `--resume`); scoped to `projects/` so the OAuth credential never crosses (default: `false`) (types: `true`/`false`)
  - `shareClaudeConfig`: read-only mount the host `~/.claude` so the VM reuses your login, settings, commands and memory (default: `true`) (types: `true`/`false`)
  - `shareGitConfig`: stage a sanitized copy of your global git config so in-VM `git` commits as you (no credentials/signing keys cross) (default: `true`) (types: `true`/`false`)
  - `vmDiskSize`: GiB of opt-in encrypted ephemeral disk at `/scratch`; `0` keeps pure RAM (default: `0`) (types: non-negative integer)
  - `nix.enable`: enable Nix in the VM (default: `false`) (types: `true`/`false`)
  - `nix.substituters`: extra binary caches for in-VM Nix (default: `[]`) (types: list of strings)
  - `nix.trustedPublicKeys`: public keys that verify paths from `nix.substituters` (default: `[]`) (types: list of strings)

### Alternate option declarations

  Per-run env overrides (`CCVM_X == option`):

  - `CCVM_AUTOUPDATE` == `autoUpdateFiles`
  - `CCVM_ACCEL` == `acceleration`
  - `CCVM_MEMORY` == `memory`
  - `CCVM_SHARE_CLAUDE_CONFIG` == `shareClaudeConfig`
  - `CCVM_PERSIST_PROJECTS` == `persistClaudeProjects`
  - `CCVM_SHARE_GIT_CONFIG` == `shareGitConfig`
  - `CCVM_CLAUDE_MD` == `extraClaudeMd`
  - `CCVM_MLOCK` == `lockGuestMemory`
  - `CCVM_VM_DISK_SIZE` == `vmDiskSize`

  ccvm-only flags (consumed, never forwarded to `claude`):

  - `--auto-update-files` / `--no-auto-update-files` == `autoUpdateFiles` (== `CCVM_AUTOUPDATE`)
  - `--shell` (debug shell), `--ccvm-debug` (stream console), `--ccvm-help`, `--ccvm-version`

---

## Installation

### home-manager example

  1. Install Nix

  You can find the installer at [nixos.org/download](https://nixos.org/download/).
  You don't need NixOS to use Nix or ccvm. If you aren't on NixOS and don't plan on switching (yet), use the install *script* found at the linked webpage.

  2. Flake configuration

  If you don't already have a repo for your dotfiles, that's fine for now; just make a directory for the flake:

  ```bash
  mkdir -p ~/Projects/yourConfigRepo
  ```

  You'll also need nix-command and flakes enabled. To do this on the user-level, add this to `~/.config/nix/nix.conf`:

  ```
  experimental-features = nix-command flakes
  ```

  In `yourConfigRepo/flake.nix` (ensure you replace all instances of `yourUsername`):

  ```nix
  {
    inputs = {
      nixpkgs.url = "nixpkgs/nixos-unstable";
      ccvm = {
        url = "github:jx-wi/ccvm";
        inputs.nixpkgs.follows = "nixpkgs";
      };
      home-manager = {
        url = "github:nix-community/home-manager";
        inputs.nixpkgs.follows = "nixpkgs";
      };
    };
    outputs = {
      nixpkgs,
      ccvm,
      home-manager,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
      };
    in
    {
      homeConfigurations.yourUsername = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ccvm.homeManagerModules.default
          ./yourUsername/home.nix
        ];
      };
    };
  }
  ```

  Now update the lock file:

  ```bash
  cd ~/Projects/yourConfigRepo && nix flake update
  ```

  3. home-manager configuration

  Make a folder in the config repo for your home-manager configuration files if you don't already have one:

  ```bash
  mkdir -p ~/Projects/yourConfigRepo/yourUsername
  ```

  In `yourConfigRepo/yourUsername/home.nix` (replace all instances of `yourUsername` again):

  ```nix
  {
    pkgs,
    lib,
    ...
  }:
  {
    home = {
      stateVersion = "26.05";
      username = "yourUsername";
      homeDirectory = "/home/yourUsername";
    };
    programs.ccvm = {
      enable = true;
      autoUpdateFiles = true;
      cores = 4;
      memory = 8192;
      nix.enable = true;
      extraPackages = with pkgs; [
        bottom
        delta
        eza
        yazi
      ];
    };
    nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
      "claude-code"
    ];
  }
  ```

  Now switch to your new configuration:

  ```bash
  nix run nixpkgs#nh -- home switch ~/Projects/yourConfigRepo
  ```

---

## Roadmap

  - [X] Baseline one-command microVM for Claude Code
  - [X] Network egress controls
  - [X] Encrypted disk support
  - [ ] Authenticated binary cache support
  - [ ] Dedicated CI server for the boot tests

---

## License

  MIT © 2026 Jaxxen. See [LICENSE](LICENSE).
