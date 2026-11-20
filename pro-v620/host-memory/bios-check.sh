#!/usr/bin/env bash
# Reads BIOS attributes over the BMC's Redfish API and, given Attribute=Value pairs, checks
# them. Runs on the authoring Mac. The BMC refuses Redfish BIOS writes (README.md, "BIOS
# settings"), so settings change in iKVM and this script confirms what the BIOS reports.
#
# Usage: bios-check.sh                      the memory-related attributes
#        bios-check.sh Attribute ...         those attributes
#        bios-check.sh Attribute=Value ...   those attributes; exit 1 if any differs
# The BMC login is read from a curl netrc file, one line:
#   machine 192.168.1.7 login <user> password <password>
set -Eeuo pipefail

BMC="${BMC:-192.168.1.7}"
BMC_NETRC="${BMC_NETRC:-${HOME}/.config/bmc/romed8.netrc}"
DEFAULT_ATTRS="CbsDfCmnDramNps CbsCmnApbdis CbsCmnFixedSocPstate CbsCmnGnbSMUDfCstates"

die() { echo "ERROR: $*" >&2; exit 1; }

compare() {
  python3 -I -c '
import json, sys
have = json.load(sys.stdin)["Attributes"]
bad = 0
for arg in sys.argv[1:]:
    name, sep, want = arg.partition("=")
    if name not in have:
        print(f"{name}: not an attribute of this BIOS")
        bad += 1
        continue
    got = have[name] if isinstance(have[name], str) else json.dumps(have[name])
    ok = not sep or got == want
    bad += not ok
    print(f"{name} = {got}" + ("" if ok else f"  (expected {want})"))
sys.exit(1 if bad else 0)' "$@"
}

main() {
  [[ -r ${BMC_NETRC} ]] || die "no BMC login file ${BMC_NETRC}"
  if (( $# == 0 )); then
    # shellcheck disable=SC2086 # split the default list into arguments
    set -- ${DEFAULT_ATTRS}
  fi
  curl -sSfk -m 60 --netrc-file "${BMC_NETRC}" "https://${BMC}/redfish/v1/Systems/Self/Bios" \
    | compare "$@"
}

main "$@"
