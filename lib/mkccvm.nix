# mkCcvm: turn a ccvm configuration into the `ccvm` host wrapper package.
#
# It evaluates the guest NixOS system (guest/default.nix) and extracts the four boot
# artifacts the wrapper needs — kernel, initrd, a read-only squashfs of the system
# closure, and the kernel cmdline — then bakes their store paths (plus the scalar
# config) into wrapper/ccvm.sh. The workspace 9p share and SSH port are NOT baked: they
# are only known at launch time, so the wrapper constructs those QEMU args at runtime
# (this is the microvm.nix runtime-share trap; see docs/design.md §3.8).
#
# Called from both the flake (standalone `nix run`) and the home-manager module, always
# with the caller's own `pkgs`, so guest and host stay on one nixpkgs.
{ pkgs }:
let
  lib = pkgs.lib;

  # Default config VALUES live in lib/defaults.nix — the single source of truth shared with
  # the home-manager module's option defaults, so the two can't drift. See that file for the
  # per-option semantics; the home-manager module carries the full user-facing descriptions.
  defaults = import ./defaults.nix { inherit pkgs; };
in
userConfig:
let
  # Shallow-merge the top level, then deep-merge the one nested attr (`nix`) so a caller passing
  # `nix = { enable = true; }` keeps the other `nix.*` defaults instead of replacing the whole attr.
  # NB: deliberately NOT lib.recursiveUpdate — it recurses into *any* two attrsets, and `package`
  # defaults to a derivation (which IS an attrset), so recursiveUpdate would silently deep-merge two
  # derivations into a broken Frankenstein. A targeted one-level merge of `nix` (whose children are
  # all scalars) is both safe and exactly what's needed.
  config = (defaults // userConfig) // {
    nix = defaults.nix // (userConfig.nix or { });
  };
  system = pkgs.stdenv.hostPlatform.system;

  # The wrapper is arch-specific: pick the matching qemu-system binary and a default
  # machine type the arch actually supports. `microvm` is x86-only; aarch64 uses `virt`.
  # On x86_64 these resolve to exactly the previous hardcoded values (qemu-system-x86_64,
  # microvm), so that path is unchanged.
  qemuBin = "qemu-system-${pkgs.stdenv.hostPlatform.qemuArch}";
  defaultMachine = if pkgs.stdenv.hostPlatform.isAarch64 then "virt" else "microvm";

  guestSystem = import "${pkgs.path}/nixos/lib/eval-config.nix" {
    inherit system;
    modules = [
      ../guest/default.nix
      {
        nixpkgs.pkgs = pkgs;
        ccvm = {
          inherit (config) apiKeyVariable extraPackages nix;
          claudePackage = config.package;
        };
      }
    ]
    ++ config.extraGuestModules;
  };

  gc = guestSystem.config;
  toplevel = gc.system.build.toplevel;
  kernel = "${gc.system.build.kernel}/${gc.system.boot.loader.kernelFile}";
  initrd = "${gc.system.build.initialRamdisk}/${gc.system.boot.loader.initrdFile}";

  # The full system closure as a read-only squashfs. Its root holds the store paths by
  # basename, so it mounts directly at /nix/store in the guest. zstd decompresses fast,
  # which matters for boot time.
  storeImage = pkgs.callPackage "${pkgs.path}/nixos/lib/make-squashfs.nix" {
    storeContents = [ toplevel ];
    comp = "zstd -Xcompression-level 6";
    fileName = "ccvm-store";
  };

  # Kernel cmdline for direct boot. init= points into the (now mounted) read-only store.
  append = lib.concatStringsSep " " (gc.boot.kernelParams ++ [ "init=${toplevel}/init" ]);

  # The ccvm-context CLAUDE.md baked to a store file; the wrapper copies it into the seed and
  # the guest lays it at ~/.claude/CLAUDE.md. Empty extraClaudeMd => bake an empty path so the
  # wrapper stages nothing (injection disabled).
  claudeMdFile = if config.extraClaudeMd == "" then "" else "${pkgs.writeText "ccvm-context.md" config.extraClaudeMd}";

  # ccvm's own version. Pre-public (no tagged release yet), surfaced by `ccvm --ccvm-version`
  # (baked into the wrapper as @VERSION@). Bump on release.
  version = "0.1.0";

  # Package metadata. Surfaced on the wrapper derivation (so `nix search` / `nix run` see a
  # description and the right binary) and reused by the flake's `apps` outputs to silence the
  # `nix flake check` "lacks attribute 'meta'" warnings. `mainProgram` matches the /bin name.
  meta = {
    description = "Run Claude Code in a throw-away, RAM-only QEMU microVM";
    homepage = "https://github.com/jx-wi/ccvm";
    license = lib.licenses.mit;
    mainProgram = "ccvm";
    maintainers = [{ github = "jx-wi"; name = "jx-wi"; }];
    platforms = lib.platforms.linux;
  };

  # useHostStoreAsCache (design §3.11 "L2"): expose the host /nix/store to the guest as a read-only
  # build substituter so in-VM `nix build`/`nix develop` reuse host-built paths instead of rebuilding.
  # Build-time + baked (it changes guest nix.settings AND makes the wrapper attach the host store as a
  # ro 9p share) — see @HOSTSTORECACHE@ below and guest/default.nix. Only meaningful with nix.enable;
  # warn (not a hard assert — keeps `nix flake check` evaluable) if set without it, since there is then
  # no in-VM nix to consume the cache.
  wrapper = lib.warnIf (config.nix.useHostStoreAsCache && !config.nix.enable)
    "ccvm: programs.ccvm.nix.useHostStoreAsCache has no effect without nix.enable = true (no in-VM nix to use the host-store cache)."
    (pkgs.writeShellApplication {
    name = "ccvm";
    inherit meta;
    runtimeInputs = with pkgs; [ qemu coreutils openssh findutils getent git ];
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
        "@SHARECLAUDE@"
        "@PERSISTPROJECTS@"
        "@SHAREGIT@"
        "@CLAUDEMD@"
        "@QEMU@"
        "@DEFAULTMACHINE@"
        "@MEMLOCK@"
        "@EGRESSALLOW@"
        "@EGRESSPORTS@"
        "@VERSION@"
        "@VMDISKSIZE@"
        "@HOSTSTORECACHE@"
      ]
      [
        kernel
        initrd
        "${storeImage}"
        append
        (toString config.memory)
        (toString config.cores)
        (if config.autoUpdateFiles then "rw" else "overlay")
        config.apiKeyVariable
        (if config.shareClaudeConfig then "1" else "0")
        (if config.persistClaudeProjects then "1" else "0")
        (if config.shareGitConfig then "1" else "0")
        claudeMdFile
        qemuBin
        defaultMachine
        (if config.lockGuestMemory then "1" else "0")
        (lib.concatStringsSep " " config.egressAllowlist)
        (lib.concatStringsSep " " (map toString config.egressPorts))
        version
        (toString config.vmDiskSize)
        (if config.nix.useHostStoreAsCache then "1" else "0")
      ]
      (builtins.readFile ../wrapper/ccvm.sh);
  });
in
{
  inherit wrapper guestSystem toplevel storeImage append kernel initrd config meta;
  kernelParams = gc.boot.kernelParams;
}
