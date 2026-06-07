# Single source of truth for ccvm's default configuration VALUES.
#
# Imported by BOTH lib/mkccvm.nix (the merge baseline for an explicit `mkCcvm { … }` call)
# and modules/home-manager.nix (each programs.ccvm.* option's `default`), so the two can
# never drift. Keep the user-facing option DESCRIPTIONS in the home-manager module; keep the
# VALUES (and only a one-line reminder of what each is) here.
{ pkgs }:
{
  package = pkgs.claude-code; # the claude-code package to run inside the VM (unfree)
  autoUpdateFiles = true; # true = live host edits (rw, native); false = ephemeral overlay
  memory = 4096; # guest RAM in MiB (runtime QEMU arg; CCVM_MEMORY overrides per run)
  cores = 4; # guest vCPUs
  extraPackages = [ ]; # extra toolchains available inside the VM (a base set is always present)
  nixInVm = false; # build-time: enable in-VM nix (writable /nix/store overlay + nix.enable). User-facing: programs.ccvm.nix.enable
  useHostStoreAsCache = false; # programs.ccvm.nix.useHostStoreAsCache — host store as a build substituter. DECLARED but not implemented yet (design §3.11 L2)
  apiKeyVariable = "ANTHROPIC_API_KEY"; # host env var carrying the key (rides SendEnv only)
  shareClaudeConfig = true; # reuse the host ~/.claude (login/settings/memory), read-only
  persistClaudeProjects = false; # persist ~/.claude/projects back to the host (resume + memory)
  shareGitConfig = true; # stage a sanitized host git config so in-VM git commits as you
  extraClaudeMd = builtins.readFile ./ccvm-context.md; # guest ~/.claude/CLAUDE.md ("you're in ccvm")
  lockGuestMemory = false; # mlock guest RAM so it can't reach host swap
  vmDiskSize = 0; # GiB; 0=off. >0 attaches an encrypted ephemeral disk pool (/scratch; later writable store)
  egressAllowlist = [ ]; # opt-in egress allowlist; empty = open egress (native default)
  egressPorts = [ 443 ]; # dst ports the allowlist permits (only when egressAllowlist is set)
  extraGuestModules = [ ]; # extra NixOS modules merged into the guest (escape hatch)
}
