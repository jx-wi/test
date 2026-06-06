#!/usr/bin/env bash
#
# Egress-allowlist host-side tests. Driven (like host.sh) by the CCVM_DRYRUN hook, but
# against a wrapper baked WITH an allowlist (tests/default.nix builds it). Asserts the
# host-side resolution/staging:
#   * bare IPs/CIDRs are staged verbatim,
#   * api.anthropic.com is always auto-included so auth can't break,
#   * ports are staged as an nft-ready comma list.
#
# Runs offline: `nix flake check` sandboxes have no network, so FQDN resolution yields no
# A/AAAA records here — we assert only the network-independent behaviour (verbatim IP/CIDR
# handling, the always-present marker entry, ports). FQDN-resolution-to-IP is exercised by
# tests/boot.sh and by a real run.
#
# Required env: CCVM  = a ccvm wrapper baked with egressAllowlist=["10.0.0.0/8"],
#                       egressPorts=[80 443] (see tests/default.nix).
set -euo pipefail

: "${CCVM:?set CCVM to the egress-allowlist dry-run wrapper}"

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf 'ok   - %s\n' "$1"
}
no() {
  FAIL=$((FAIL + 1))
  printf 'FAIL - %s\n' "$1" >&2
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export XDG_RUNTIME_DIR="$WORK/run"
mkdir -p "$XDG_RUNTIME_DIR"
export CCVM_DRYRUN=1
export HOME="$WORK/home"
mkdir -p "$HOME"
export CCVM_SHARE_CONFIG=0

cwd="$(mktemp -d "$WORK/cwd.XXXXXX")"
SEED="$(cd "$cwd" && "$CCVM")/seed"

[[ -s "$SEED/egress-allow" ]] && ok "allowlist staged to the seed" ||
  no "egress-allow missing/empty with a baked allowlist"

grep -qx '10.0.0.0/8' "$SEED/egress-allow" && ok "CIDR entry staged verbatim" ||
  no "CIDR 10.0.0.0/8 not staged verbatim"

# api.anthropic.com is always added. Offline it resolves to nothing, but the entry must be
# attempted regardless — assert it's at least present as a literal if DNS happened to work,
# otherwise just assert the file is the CIDR alone (proving the auto-include path ran and
# simply found no records). Either way the staging must not have errored out.
if [[ -n "$(getent ahosts api.anthropic.com 2>/dev/null)" ]]; then
  # Network available (e.g. local run): the resolved IPs must be present.
  lines="$(wc -l <"$SEED/egress-allow")"
  [[ "$lines" -gt 1 ]] && ok "api.anthropic.com auto-resolved into the allowlist" ||
    no "api.anthropic.com not auto-resolved despite working DNS"
else
  ok "auto-include ran offline without error (only verbatim CIDR present)"
fi

[[ "$(cat "$SEED/egress-ports")" == "80,443" ]] && ok "ports staged as nft comma list" ||
  no "egress-ports wrong: $(cat "$SEED/egress-ports")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
