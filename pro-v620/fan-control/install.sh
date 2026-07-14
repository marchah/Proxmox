#!/usr/bin/env bash
#
# Install GPU-temperature-based fan control for the Radeon Pro V620 cooler(s) on a
# Proxmox host with an MSI MAG B550 board. Runs one systemd instance per cooler
# (this host's two V620s share a single NF-F12 iPPC-3000 in a shroud — one @shroud
# instance cooling both cards, its curve tracking the hotter one), pinned by PCI address.
#
# Run on the Proxmox host as root. Idempotent — safe to re-run.
#
# What it does, in order:
#   1. Install kernel headers + DKMS build toolchain (if missing).
#   2. Install the out-of-tree nct6687 hwmon driver via DKMS — the in-tree
#      nct6683 is READ-ONLY on this board, so it cannot set fan PWM. Blacklist
#      nct6683 and load nct6687 at boot.
#   3. Install the gpu-fan-control daemon, its env file, and systemd unit.
#   4. Enable, then RESTART the service (so a re-run activates the new version),
#      and verify it is active.
#
# The nct6687 driver is built from an external repository (default
# https://github.com/Fred78290/nct6687d) — the de-facto Linux driver for the
# Nuvoton NCT6687D. This code is built and loaded into the kernel as root, so
# NCT6687D_REF must be a FULL 40-char commit SHA you have reviewed (a moving
# branch like `master` is rejected). To move to a newer driver, review the
# upstream diff and pin its commit SHA via NCT6687D_REF.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Out-of-tree driver source. Pinned to a full commit SHA known-good on kernel
# 7.0.12-1-pve. To bump, review the upstream diff and replace this SHA.
NCT6687D_REPO="${NCT6687D_REPO:-https://github.com/Fred78290/nct6687d}"
NCT6687D_REF="${NCT6687D_REF:-e069fac2107fb88d30be41375bd2c35ef17e3677}"

readonly SBIN_PATH="/usr/local/sbin/gpu-fan-control"
readonly UNIT_PATH="/etc/systemd/system/gpu-fan-control@.service"
readonly BLACKLIST_PATH="/etc/modprobe.d/nct6687.conf"
readonly MODLOAD_PATH="/etc/modules-load.d/nct6687.conf"
# Records the driver commit SHA we built, so a bumped NCT6687D_REF triggers a rebuild.
readonly DRIVER_SHA_FILE="/var/lib/gpu-fan-control.driver-sha"
# One systemd instance per COOLER; each reads its own /etc/gpu-fan-control-<i>.env
# (pins the GPU(s) it cools by PCI address + its fan pwm channel). Current hardware:
# one NF-F12 in a shared shroud cools BOTH V620s (curve = hottest of the two).
#   shroud -> both V620s (pwm3, FAN1)
# Reference env files for the prior per-GPU coolers (blower/arctic) are kept in the
# repo but not installed while INSTANCES lists only 'shroud'. Any enabled instance
# NOT listed here is retired on install (see install_service).
readonly INSTANCES=(shroud)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root (on the Proxmox host)"; }

# A writable nct6687 hwmon present means the driver is already in place.
nct6687_writable() {
  local h
  for h in /sys/class/hwmon/hwmon*; do
    [ -r "$h/name" ] || continue
    [ "$(cat "$h/name" 2>/dev/null)" = "nct6687" ] || continue
    [ -w "$h/pwm1_enable" ] && return 0
  done
  return 1
}

ensure_build_deps() {
  local kver headers
  kver="$(uname -r)"
  headers="proxmox-headers-${kver}"
  if dpkg -s dkms git build-essential "$headers" >/dev/null 2>&1; then
    log "build deps already present"
    return
  fi
  log "installing build deps: $headers dkms git build-essential"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$headers" dkms git build-essential \
    || die "failed installing build deps (is '$headers' available for kernel $kver?)"
  [ -d "/usr/src/linux-headers-${kver}" ] || die "kernel headers for $kver still missing after install"
}

# Refuse to build anything but a reviewed, immutable full commit SHA (the module
# runs as root in-kernel). Override only with eyes open via NCT6687D_ALLOW_UNPINNED=1.
validate_driver_ref() {
  if [ "${NCT6687D_ALLOW_UNPINNED:-0}" = "1" ]; then
    warn "NCT6687D_ALLOW_UNPINNED=1 — building '$NCT6687D_REF' without a pinned SHA (supply-chain risk)"
    return
  fi
  [[ "$NCT6687D_REF" =~ ^[0-9a-f]{40}$ ]] \
    || die "NCT6687D_REF must be a full 40-char commit SHA you have reviewed (got '$NCT6687D_REF'); set NCT6687D_ALLOW_UNPINNED=1 to override"
}

# Build + DKMS-install the pinned driver (clean: drops any stale registration).
build_driver() {
  validate_driver_ref
  local tmp; tmp="$(mktemp -d)"
  log "cloning $NCT6687D_REPO @ $NCT6687D_REF"
  git clone "$NCT6687D_REPO" "$tmp" >/dev/null 2>&1 || die "git clone failed"
  git -C "$tmp" checkout --quiet "$NCT6687D_REF" || die "checkout $NCT6687D_REF failed"
  # Confirm we built exactly the reviewed commit (no-op under ALLOW_UNPINNED branches).
  if [[ "$NCT6687D_REF" =~ ^[0-9a-f]{40}$ ]]; then
    [ "$(git -C "$tmp" rev-parse HEAD)" = "$NCT6687D_REF" ] || die "checked-out HEAD != $NCT6687D_REF"
  fi
  for f in dkms.conf Makefile nct6687.c; do
    [ -f "$tmp/$f" ] || die "driver source missing $f — upstream layout changed?"
  done
  log "building + installing nct6687 via DKMS"
  # Drop any stale registration so a new SHA / kernel rebuild starts clean.
  dkms status 2>/dev/null | grep -q '^nct6687d' && dkms remove nct6687d/1 --all >/dev/null 2>&1 || true
  rm -rf /usr/src/nct6687d-1
  install -d /usr/src/nct6687d-1
  # Install via DKMS directly (the upstream 'make dkms/install' target shells out
  # to sudo, which a minimal Proxmox host may not have — we are already root).
  cp "$tmp/dkms.conf" "$tmp/Makefile" "$tmp/nct6687.c" /usr/src/nct6687d-1/
  dkms install nct6687d/1 || die "DKMS build/install failed (see /var/lib/dkms/nct6687d/1/build/make.log)"
  # Record the SHA we actually built (resolved HEAD), so an unpinned branch ref is
  # stored as a real commit — not the literal "master" — and later pinning to that
  # exact commit correctly skips a rebuild.
  local built_sha; built_sha="$(git -C "$tmp" rev-parse HEAD 2>/dev/null)"
  rm -rf "$tmp"
  printf '%s\n' "${built_sha:-$NCT6687D_REF}" > "$DRIVER_SHA_FILE"
}

# Make nct6687 (the writable driver) the loaded module. On a rebuild, force a
# reload so the NEW build is live — modprobe alone won't replace a loaded module.
activate_driver() {  # $1 = 1 if we just (re)built
  modprobe -r nct6683 2>/dev/null || true
  if [ "${1:-0}" = "1" ] && lsmod | grep -q '^nct6687\b'; then
    # Release the chip: stop EVERY loaded fan-control consumer — ANY `gpu-fan-control@*`
    # instance (not just those in INSTANCES) plus the legacy single unit — so the rebuilt
    # module can replace the loaded one. Stopping only INSTANCES would let a STALE instance
    # from a prior setup (e.g. @blower / @arctic before the shroud) keep nct6687 open, so
    # `modprobe -r` would fail and the OLD build would stay live until reboot. Those stale
    # units are fully disabled/retired later in install_service; here we only need them
    # stopped. enable_service (later in main) restarts the current INSTANCES.
    local units
    units="$(systemctl list-units --full --all --no-legend 'gpu-fan-control@*.service' gpu-fan-control.service 2>/dev/null | awk '{print $1}')" || true
    if [ -n "$units" ]; then
      # shellcheck disable=SC2086  # word-splitting the unit list is intended
      systemctl stop $units 2>/dev/null || true
    fi
    modprobe -r nct6687 2>/dev/null \
      || warn "nct6687 still in use — the REBUILT driver only becomes active after a reboot (it is loaded at boot via /etc/modules-load.d)"
  fi
  modprobe nct6687 2>/dev/null || true
}

ensure_driver() {
  local kver; kver="$(uname -r)"
  local installed_sha=""; [ -f "$DRIVER_SHA_FILE" ] && installed_sha="$(cat "$DRIVER_SHA_FILE" 2>/dev/null)"
  local registered=0 built_here=0
  dkms status 2>/dev/null | grep -q '^nct6687d' && registered=1
  dkms status nct6687d 2>/dev/null | grep -F "$kver" | grep -q ': installed' && built_here=1

  # Rebuild when not registered, in unpinned mode (the ref is a moving target, so
  # always rebuild it), when the reviewed SHA changed, or when there is no module
  # for the running kernel (e.g. after a kernel upgrade). A bare registration check
  # would silently ignore a bumped NCT6687D_REF or an unpinned override.
  local need=0 reason=""
  if   (( ! registered )); then need=1; reason="not registered with DKMS"
  elif [ "${NCT6687D_ALLOW_UNPINNED:-0}" = "1" ]; then need=1; reason="unpinned mode (rebuilding $NCT6687D_REF)"
  elif [ "$NCT6687D_REF" != "$installed_sha" ]; then need=1; reason="driver SHA change (${installed_sha:-unknown} -> $NCT6687D_REF)"
  elif (( ! built_here )); then need=1; reason="no module built for kernel $kver"
  fi

  if (( need )); then
    log "installing nct6687d ($reason)"
    build_driver
  else
    log "nct6687d up to date (sha ${installed_sha:-?}, built for $kver)"
  fi

  # Prefer the writable out-of-tree nct6687 over the read-only in-tree nct6683.
  if [ ! -f "$BLACKLIST_PATH" ]; then
    log "blacklisting in-tree nct6683"
    printf '# Use out-of-tree nct6687 (writable PWM) instead of read-only in-tree nct6683\nblacklist nct6683\n' > "$BLACKLIST_PATH"
  fi
  if [ ! -f "$MODLOAD_PATH" ]; then
    log "loading nct6687 at boot"
    printf 'nct6687\n' > "$MODLOAD_PATH"
  fi
  activate_driver "$need"

  nct6687_writable || die "nct6687 present but PWM still not writable — check 'dmesg | grep nct6687' and that the chip is an NCT6687D"
  log "nct6687 writable PWM confirmed"
}

install_service() {
  log "installing daemon -> $SBIN_PATH"
  install -m 0755 "$SCRIPT_DIR/gpu-fan-control.sh" "$SBIN_PATH"

  local inst env_path src
  for inst in "${INSTANCES[@]}"; do
    env_path="/etc/gpu-fan-control-${inst}.env"
    src="$SCRIPT_DIR/gpu-fan-control-${inst}.env"
    [ -f "$src" ] || die "missing env source: $src"
    if [ -f "$env_path" ]; then
      warn "$env_path exists — leaving your settings untouched (delete it to reset to defaults)"
    else
      log "installing config -> $env_path"
      install -m 0644 "$src" "$env_path"
    fi
  done

  log "installing template unit -> $UNIT_PATH"
  install -m 0644 "$SCRIPT_DIR/gpu-fan-control@.service" "$UNIT_PATH"

  # Migrate off the old single-instance service if a prior install left it behind
  # (it drives only one fan and would fight the per-GPU instances for the chip).
  if [ -e /etc/systemd/system/gpu-fan-control.service ]; then
    log "removing superseded single-instance gpu-fan-control.service"
    systemctl disable --now gpu-fan-control.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/gpu-fan-control.service
  fi

  # Retire any enabled instances no longer in INSTANCES (e.g. a previous per-GPU
  # blower/arctic setup replaced by a single shroud fan) so they don't keep driving
  # now-empty channels or fight the current instance for the chip.
  local link ename want keep
  for link in /etc/systemd/system/multi-user.target.wants/gpu-fan-control@*.service; do
    [ -e "$link" ] || continue
    ename="$(basename "$link")"; ename="${ename#gpu-fan-control@}"; ename="${ename%.service}"
    keep=0; for want in "${INSTANCES[@]}"; do [ "$ename" = "$want" ] && keep=1; done
    (( keep )) || { log "retiring stale instance gpu-fan-control@${ename}"; systemctl disable --now "gpu-fan-control@${ename}.service" >/dev/null 2>&1 || true; }
  done
  systemctl daemon-reload
}

enable_service() {
  local inst; local -a units=() jargs=()
  for inst in "${INSTANCES[@]}"; do units+=("gpu-fan-control@${inst}.service"); jargs+=(-u "gpu-fan-control@${inst}.service"); done
  log "enabling + (re)starting: ${units[*]}"
  systemctl enable "${units[@]}" >/dev/null 2>&1 || die "failed to enable the units"
  # restart (not enable --now): on a re-run --now leaves the OLD process running,
  # so installed safety fixes would not take effect until reboot/manual restart.
  systemctl restart "${units[@]}"
  sleep 4
  for inst in "${INSTANCES[@]}"; do
    systemctl is-active --quiet "gpu-fan-control@${inst}.service" \
      || die "gpu-fan-control@${inst} failed to start — see: journalctl -u gpu-fan-control@${inst} -n 30"
  done
  log "active. Recent log:"
  journalctl "${jargs[@]}" -n 6 -o cat || true
}

main() {
  require_root
  ensure_build_deps
  ensure_driver
  install_service
  enable_service
  log "done. Tune a curve in /etc/gpu-fan-control-<instance>.env, then: systemctl restart gpu-fan-control@<instance>"
}

main "$@"
