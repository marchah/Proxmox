#!/usr/bin/env bash
# Sets BIOS attributes on the ROMED8-2T through the BMC's Redfish API and boots the host with
# them. Runs on the authoring Mac, not the host: the host is down for part of it.
#
# The BMC accepts a BIOS write only while the host sits in UEFI Setup; once the OS has booted,
# PATCH .../Bios/SD returns HTTP 500 ("thread is dead"). So the script sets a one-time boot into
# Setup with in-band IPMI, reboots the host, retries the write until Setup accepts it,
# force-restarts the host so POST applies the pending values, waits for a new boot of the OS,
# and checks that the BIOS reports the requested values.
#
# Usage: bios-set.sh Attribute=Value [Attribute=Value ...]
#   bios-set.sh CbsDfCmnDramNps=CbsDfCmnDramNpsNPS4
# Names and values are checked against the BIOS's attribute registry before anything changes.
# DRY_RUN=true stops after that check. The BMC login is read from a curl netrc file, one line:
#   machine 192.168.1.7 login <user> password <password>
# Every guest on the host must be stopped. Bash 3.2 compatible (macOS /bin/bash).
set -Eeuo pipefail

BMC="${BMC:-192.168.1.7}"
BMC_NETRC="${BMC_NETRC:-${HOME}/.config/bmc/romed8.netrc}"
HOST="${HOST:-pve}"
DRY_RUN="${DRY_RUN:-false}"
DOWN_TIMEOUT_S="${DOWN_TIMEOUT_S:-300}"
SETUP_TIMEOUT_S="${SETUP_TIMEOUT_S:-900}"
BOOT_TIMEOUT_S="${BOOT_TIMEOUT_S:-1500}"
POLL_S=15
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date +%T)] $*"; }
usage() { sed -n '2,17p' "$0" >&2; exit 2; }

write_helper() {
  cat > "${WORK}/rf.py" <<'EOF'
import gzip, json, sys

def load(path):
    raw = open(path, "rb").read()
    if raw[:2] == b"\x1f\x8b":  # the registry file is served gzip-compressed
        raw = gzip.decompress(raw)
    return json.loads(raw)

cmd, args = sys.argv[1], sys.argv[2:]
if cmd == "field":  # FILE KEY
    print(load(args[0])[args[1]])
elif cmd == "location":  # REGISTRY_INDEX
    print(load(args[0])["Location"][0]["Uri"])
elif cmd == "etag":  # FILE
    print(load(args[0])["@odata.etag"])
elif cmd == "build":  # REGISTRY BIOS OUT NAME=VALUE...; exit 3 when nothing would change
    reg = {a["AttributeName"]: a for a in load(args[0])["RegistryEntries"]["Attributes"]}
    cur = load(args[1])["Attributes"]
    body, changes = {}, 0
    for arg in args[3:]:
        name, sep, value = arg.partition("=")
        a = reg.get(name)
        if not sep or a is None:
            sys.exit(f"not an attribute of this BIOS, or no '=': {arg}")
        if a.get("ReadOnly"):
            sys.exit(f"{name} is read-only")
        kind = a.get("Type")
        if kind == "Enumeration":
            allowed = [v["ValueName"] for v in a.get("Value", [])]
            if value not in allowed:
                sys.exit(f"{name}: {value} is not one of {allowed}")
        elif kind == "Integer":
            value = int(value)
        elif kind == "Boolean":
            if value not in ("true", "false"):
                sys.exit(f"{name} takes true or false")
            value = value == "true"
        body[name] = value
        changes += cur.get(name) != value
        state = "change" if cur.get(name) != value else "unchanged"
        print(f"  {name} ({a.get('DisplayName')}): {cur.get(name)} -> {value} [{state}]")
    json.dump({"Attributes": body}, open(args[2], "w"))
    sys.exit(0 if changes else 3)
elif cmd == "pending":  # BIOS SD; exit 1 when the BMC holds values not yet applied
    cur = load(args[0])["Attributes"]
    sd = load(args[1]).get("Attributes", {})
    diff = {k: v for k, v in sd.items() if cur.get(k) != v}
    for k, v in diff.items():
        print(f"  pending: {k}: {cur.get(k)} -> {v}")
    sys.exit(1 if diff else 0)
elif cmd == "check":  # STATE BODY; exit 1 when a requested value is not in STATE
    have = load(args[0])["Attributes"]
    want = load(args[1])["Attributes"]
    bad = 0
    for k, v in want.items():
        ok = have.get(k) == v
        bad += not ok
        print(f"  {k} = {have.get(k)}" + ("" if ok else f"  (requested {v})"))
    sys.exit(1 if bad else 0)
else:
    sys.exit(f"unknown helper command {cmd}")
EOF
}

py() { python3 -I "${WORK}/rf.py" "$@"; }

# GET a Redfish path to stdout; fails on an HTTP error.
rf_get() { curl -sSfk -m 60 --netrc-file "${BMC_NETRC}" "https://${BMC}$1"; }

# Send a Redfish request with a JSON body; the body of the reply goes to $3, the HTTP code to stdout.
rf_send() {
  local method="$1" path="$2" out="$3" body="$4"; shift 4
  curl -sSk -m 60 --netrc-file "${BMC_NETRC}" -X "${method}" -H 'Content-Type: application/json' \
    "$@" -d "${body}" -o "${out}" -w '%{http_code}' "https://${BMC}${path}"
}

on_host() { ssh -o BatchMode=yes -o ConnectTimeout=5 "${HOST}" "$@"; }
boot_id() { on_host cat /proc/sys/kernel/random/boot_id 2>/dev/null || true; }

fetch_state() {
  local name loc
  rf_get /redfish/v1/Systems/Self/Bios > "${WORK}/bios.json"
  name="$(py field "${WORK}/bios.json" AttributeRegistry)"
  rf_get "/redfish/v1/Registries/${name}" > "${WORK}/registry-index.json"
  loc="$(py location "${WORK}/registry-index.json")"
  rf_get "${loc}" > "${WORK}/registry.raw"
  rf_get /redfish/v1/Systems/Self/Bios/SD > "${WORK}/sd.json"
}

require_guests_stopped() {
  local running
  running="$(on_host "pct list | awk 'NR>1 && \$2 != \"stopped\"'; qm list | awk 'NR>1 && \$3 != \"stopped\"'")" \
    || die "cannot list guests on ${HOST}"
  [[ -z ${running} ]] || die "guests still running on ${HOST}:
${running}"
}

boot_to_setup() {
  on_host ipmitool chassis bootdev bios options=efiboot > /dev/null
  on_host ipmitool chassis bootparam get 5 | grep -q 'Force Boot into BIOS Setup' \
    || die "the one-time boot into Setup did not stick"
  log "next boot goes to BIOS Setup; rebooting ${HOST}"
  on_host systemctl reboot || true
}

wait_down() {
  local old="$1" t0 id
  t0="$(date +%s)"
  while :; do
    id="$(boot_id)"
    [[ -n ${id} && ${id} == "${old}" ]] || return 0
    (( $(date +%s) - t0 < DOWN_TIMEOUT_S )) || die "${HOST} did not go down within ${DOWN_TIMEOUT_S} s"
    sleep 5
  done
}

# Retry the write until the host is in Setup and the BMC accepts it (HTTP 500 until then).
write_in_setup() {
  local t0 etag code
  t0="$(date +%s)"
  while :; do
    rf_get /redfish/v1/Systems/Self/Bios/SD > "${WORK}/sd.json"
    etag="$(py etag "${WORK}/sd.json")"
    code="$(rf_send PATCH /redfish/v1/Systems/Self/Bios/SD "${WORK}/patch.out" \
      "$(cat "${WORK}/body.json")" -H "If-Match: ${etag}" || true)"
    case ${code} in
      200|202|204) log "BMC accepted the write (HTTP ${code})"; return 0 ;;
      500|000) ;;
      *) die "write refused with HTTP ${code}: $(head -c 400 "${WORK}/patch.out")" ;;
    esac
    (( $(date +%s) - t0 < SETUP_TIMEOUT_S )) \
      || die "no write accepted within ${SETUP_TIMEOUT_S} s; the host should be in Setup: set the values in iKVM"
    sleep "${POLL_S}"
  done
}

apply_and_boot() {
  local old="$1" code t0 id
  rf_get /redfish/v1/Systems/Self/Bios/SD > "${WORK}/sd.json"
  py check "${WORK}/sd.json" "${WORK}/body.json" > /dev/null \
    || die "the BMC accepted the write but does not list the values as pending"
  code="$(rf_send POST /redfish/v1/Systems/Self/Actions/ComputerSystem.Reset "${WORK}/reset.out" \
    '{"ResetType":"ForceRestart"}')"
  [[ ${code} == 2* ]] || die "restart refused with HTTP ${code}: $(head -c 400 "${WORK}/reset.out")"
  log "restarting from Setup to apply the values; waiting for ${HOST} to boot"
  t0="$(date +%s)"
  while :; do
    id="$(boot_id)"
    if [[ -n ${id} && ${id} != "${old}" ]]; then
      log "${HOST} is up ($(( $(date +%s) - t0 )) s after the restart)"
      return 0
    fi
    (( $(date +%s) - t0 < BOOT_TIMEOUT_S )) \
      || die "${HOST} did not boot within ${BOOT_TIMEOUT_S} s; check it in iKVM"
    sleep "${POLL_S}"
  done
}

verify() {
  rf_get /redfish/v1/Systems/Self/Bios > "${WORK}/bios.json"
  log "BIOS now reports:"
  py check "${WORK}/bios.json" "${WORK}/body.json" || die "the BIOS does not report the requested values"
  log "host:"
  # shellcheck disable=SC2016 # expands on the host
  on_host 'echo "  kernel $(uname -r), NUMA nodes $(ls -d /sys/devices/system/node/node* | wc -l)"
    for l in /dev/dri/by-path/pci-*-render; do echo "  $(basename "$l") -> $(readlink "$l")"; done'
}

main() {
  local rc=0 old
  (( $# > 0 )) || usage
  [[ -r ${BMC_NETRC} ]] || die "no BMC login file ${BMC_NETRC}"
  write_helper
  log "reading the BIOS registry and current values from ${BMC}"
  fetch_state
  py build "${WORK}/registry.raw" "${WORK}/bios.json" "${WORK}/body.json" "$@" || rc=$?
  case ${rc} in
    0) ;;
    3) log "every attribute already has the requested value; nothing to do"; return 0 ;;
    *) die "request rejected" ;;
  esac
  py pending "${WORK}/bios.json" "${WORK}/sd.json" \
    || die "the BMC already holds BIOS changes not yet applied (above)"
  require_guests_stopped
  if [[ ${DRY_RUN} == true ]]; then log "DRY_RUN: no change made"; return 0; fi

  old="$(boot_id)"
  [[ -n ${old} ]] || die "cannot reach ${HOST}"
  boot_to_setup
  wait_down "${old}"
  log "${HOST} is down; writing the values once Setup accepts them"
  write_in_setup
  apply_and_boot "${old}"
  verify
  log "done"
}

main "$@"
