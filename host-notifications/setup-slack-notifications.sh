#!/usr/bin/env bash

set -Eeuo pipefail

# Route Proxmox notifications (backup failures, replication errors, fencing, package updates,
# ...) to Slack, in addition to the built-in mail-to-root target.
#
# WHY THIS EXISTS: the weekly backup job failed silently for four consecutive weeks after the
# WiFi-NAT cutover changed the host's IP and broke the NFS mount. Proxmox *did* notify — to
# root's local mailbox via postfix, which nobody reads. A notification nobody sees is not a
# notification.
#
# Run on the Proxmox host as root, passing a Slack INCOMING WEBHOOK URL:
#   ./setup-slack-notifications.sh 'https://hooks.slack.com/services/T00000/B00000/xxxxxxxx'
#
# Create that URL at api.slack.com/apps -> your app -> Incoming Webhooks -> Add New Webhook to
# Workspace, and pick the channel it should post to (the webhook is bound to one channel, so
# there is no channel setting here).
#
# Idempotent: re-running replaces the endpoint and matcher, so it is also how you rotate the URL.
# The URL is stored as a Proxmox notification SECRET (kept in a root-only privileged file and
# never echoed back by the API), not inline in notifications.cfg.

ENDPOINT_NAME="${ENDPOINT_NAME:-slack}"
MATCHER_NAME="${MATCHER_NAME:-slack-all}"
# Minimum severity to forward. Proxmox severities: info, notice, warning, error, unknown.
# Default `null` = forward everything (this host generates few notifications, and the failure
# mode being fixed here is precisely a message that got ignored).
MIN_SEVERITY="${MIN_SEVERITY:-}"

usage() {
  sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

b64() {
  # -w0: the API expects a single-line base64 value.
  printf '%s' "$1" | base64 -w0
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
    '') die "pass the Slack incoming-webhook URL (see --help)" ;;
  esac

  [[ ${EUID} -eq 0 ]] || die "run as root on the Proxmox host"
  command -v pvesh >/dev/null || die "pvesh not found — is this a Proxmox host?"

  local url="$1" token body
  # Only the path after /services/ is secret-worthy, and keeping the host visible in the URL
  # field means a glance at the config still shows where notifications go (this mirrors the
  # Discord example in the Proxmox notification docs).
  [[ ${url} == https://hooks.slack.com/services/* ]] \
    || die "expected a URL like https://hooks.slack.com/services/T.../B.../... (got: ${url%%/services/*}...)"
  token="${url#https://hooks.slack.com/services/}"
  [[ -n ${token} && ${token} != */ ]] || die "the webhook URL looks truncated after /services/"

  # Slack renders `text` as mrkdwn. `escape` JSON-escapes the value, so a message containing
  # quotes or newlines cannot produce a malformed body (which would fail silently — the exact
  # class of bug this script exists to prevent).
  # shellcheck disable=SC2016  # the {{ }} are Proxmox templates and the ``` are literal Slack
  # code fences — both must reach the API unexpanded, so single quotes are deliberate.
  body='{"text":"*{{ title }}*\n```{{ escape message }}```"}'

  log "Creating notification endpoint '${ENDPOINT_NAME}'"
  # Replace rather than update, so re-running is a clean rotation.
  pvesh delete "/cluster/notifications/endpoints/webhook/${ENDPOINT_NAME}" >/dev/null 2>&1 || true
  pvesh create /cluster/notifications/endpoints/webhook \
    --name "${ENDPOINT_NAME}" \
    --method post \
    --url 'https://hooks.slack.com/services/{{ secrets.token }}' \
    --header "name=Content-Type,value=$(b64 'application/json')" \
    --body "$(b64 "${body}")" \
    --secret "name=token,value=$(b64 "${token}")" \
    --comment 'Slack incoming webhook (URL path stored as the token secret)' \
    || die "failed to create the webhook endpoint"

  log "Creating matcher '${MATCHER_NAME}'"
  # A matcher with mode=all and no match rules matches everything. This is ADDITIONAL to the
  # builtin default-matcher, so mail-to-root keeps working; Proxmox delivers to the union of
  # every matching matcher's targets.
  pvesh delete "/cluster/notifications/matchers/${MATCHER_NAME}" >/dev/null 2>&1 || true
  local -a matcher_args=(
    --name "${MATCHER_NAME}"
    --mode all
    --target "${ENDPOINT_NAME}"
    --comment 'Forward notifications to Slack (in addition to mail-to-root)'
  )
  if [[ -n ${MIN_SEVERITY} ]]; then
    matcher_args+=(--match-severity "${MIN_SEVERITY}")
  fi
  pvesh create /cluster/notifications/matchers "${matcher_args[@]}" \
    || die "failed to create the matcher"

  log "Sending a test notification"
  if pvesh create "/cluster/notifications/targets/${ENDPOINT_NAME}/test" >/dev/null 2>&1; then
    printf 'Test notification sent — check the Slack channel.\n'
  else
    printf 'warning: the test call failed. Inspect with:\n' >&2
    printf '  pvesh create /cluster/notifications/targets/%s/test\n' "${ENDPOINT_NAME}" >&2
    printf '  journalctl -u pvedaemon -n 50 --no-pager\n' >&2
    exit 1
  fi

  log "Done"
  printf 'Endpoint: %s   Matcher: %s   Severity filter: %s\n' \
    "${ENDPOINT_NAME}" "${MATCHER_NAME}" "${MIN_SEVERITY:-<all>}"
  printf 'Notifications now go to BOTH Slack and mail-to-root.\n'
  printf '\nVerify the weekly backup job reports in:\n'
  printf '  pvesh get /cluster/notifications/matchers\n'
  printf '  vzdump 200 --storage Synology-Backup --mode stop   # a real job that will notify\n'
  printf '\nRotate the URL later by re-running this script with the new one.\n'
}

main "$@"
