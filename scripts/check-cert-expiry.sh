#!/usr/bin/env bash
#
# Synopsis:
#   Monitor TLS certificate expiry for one or more HTTPS endpoints and alert
#   through Pushover when a certificate nears expiry or an endpoint is
#   unreachable.
#
# Description:
#   For each target, the script opens a TLS connection with SNI, reads the
#   served leaf certificate notAfter date, and computes the remaining days.
#   Targets are classified OK, WARN, CRITICAL, or UNREACHABLE against two day
#   thresholds. Any non-OK target produces a single aggregated Pushover message
#   listing all affected targets, rather than one message per target. The
#   certificate is read without trust verification, so the check behaves
#   identically against Let's Encrypt staging and production certificates.
#
#   Intended to run on a schedule. On TrueNAS, register it as a UI Cron Job so
#   it persists across updates; a custom systemd unit on the host filesystem
#   does not. Recommendation: run the monitor from a host other than the one it
#   watches, so a full outage of the monitored system still produces an alert.
#
#   Pushover credentials must not be embedded. Supply them through environment
#   variables PUSHOVER_TOKEN and PUSHOVER_USER, or a credentials file sourced
#   with --credentials. The credentials file must be mode 600 and contain:
#       PUSHOVER_TOKEN=<application token>
#       PUSHOVER_USER=<user or group key>
#
# Parameters:
#   -H, --host HOST[:PORT]   Target to check. Repeatable. Default port 443.
#   -f, --hosts-file FILE    Read targets (one HOST[:PORT] per line) from FILE.
#                            Blank lines and lines starting with # are ignored.
#       --credentials FILE   Source Pushover credentials from FILE.
#   -w, --warn-days N        Warning threshold in days. Default 21.
#   -c, --crit-days N        Critical threshold in days. Default 7.
#   -t, --timeout SECONDS    Per-target TLS connection timeout. Default 10.
#   -T, --title TEXT         Pushover notification title. Default "TLS certificate alert".
#   -q, --quiet              Suppress the per-target summary on stdout.
#       --notify-ok          Send a Pushover even when all targets are OK.
#   -n, --dry-run            Check and report but send no Pushover.
#   -d, --debug              Verbose tracing to stderr.
#   -h, --help               Show this help text and exit.
#
# Exit status:
#   0  All targets OK.
#   1  At least one target in WARN.
#   2  At least one target CRITICAL or UNREACHABLE.
#   3  Usage, dependency, or credential error.
#
# Examples:
#   ./check-cert-expiry.sh -H proxy.example.com
#   ./check-cert-expiry.sh -f /mnt/tank/scripts/cert-hosts.txt \
#       --credentials /mnt/tank/scripts/pushover.cred -q
#   PUSHOVER_TOKEN=xxx PUSHOVER_USER=yyy ./check-cert-expiry.sh \
#       -H a.example.com -H b.example.com:8443 --dry-run
#

set -uo pipefail

# Defaults.
declare -a target_spec_list=()
hosts_file_path=""
credentials_file_path=""
warn_threshold_days=21
crit_threshold_days=7
connect_timeout_seconds=10
notification_title="TLS certificate alert"
flag_quiet=0
flag_notify_ok=0
flag_dry_run=0
flag_debug=0

readonly pushover_endpoint="https://api.pushover.net/1/messages.json"

log_line() {
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" >&2
}
log_info()  { log_line "INFO"  "$1"; }
log_warn()  { log_line "WARN"  "$1"; }
log_error() { log_line "ERROR" "$1"; }
log_debug() { [ "${flag_debug}" -eq 1 ] && log_line "DEBUG" "$1" || true; }

print_usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

# Argument parsing.
while [ $# -gt 0 ]; do
    case "$1" in
        -H|--host)
            [ $# -ge 2 ] || { log_error "Option $1 requires a value."; exit 3; }
            target_spec_list+=("$2"); shift 2 ;;
        -f|--hosts-file)
            [ $# -ge 2 ] || { log_error "Option $1 requires a value."; exit 3; }
            hosts_file_path="$2"; shift 2 ;;
        --credentials)
            [ $# -ge 2 ] || { log_error "Option $1 requires a value."; exit 3; }
            credentials_file_path="$2"; shift 2 ;;
        -w|--warn-days)
            [ $# -ge 2 ] || { log_error "Option $1 requires a value."; exit 3; }
            warn_threshold_days="$2"; shift 2 ;;
        -c|--crit-days)
            [ $# -ge 2 ] || { log_error "Option $1 requires a value."; exit 3; }
            crit_threshold_days="$2"; shift 2 ;;
        -t|--timeout)
            [ $# -ge 2 ] || { log_error "Option $1 requires a value."; exit 3; }
            connect_timeout_seconds="$2"; shift 2 ;;
        -T|--title)
            [ $# -ge 2 ] || { log_error "Option $1 requires a value."; exit 3; }
            notification_title="$2"; shift 2 ;;
        -q|--quiet)      flag_quiet=1; shift ;;
        --notify-ok)     flag_notify_ok=1; shift ;;
        -n|--dry-run)    flag_dry_run=1; shift ;;
        -d|--debug)      flag_debug=1; shift ;;
        -h|--help)       print_usage; exit 0 ;;
        *) log_error "Unknown argument: $1"; exit 3 ;;
    esac
done

# Dependency check.
for required_cmd in openssl curl date timeout sed; do
    command -v "${required_cmd}" >/dev/null 2>&1 || {
        log_error "Required command not found on PATH: ${required_cmd}"
        exit 3
    }
done

# Numeric validation.
for numeric_pair in "warn:${warn_threshold_days}" "crit:${crit_threshold_days}" "timeout:${connect_timeout_seconds}"; do
    numeric_value="${numeric_pair#*:}"
    case "${numeric_value}" in
        ''|*[!0-9]*) log_error "Threshold/timeout must be a non-negative integer: ${numeric_pair}"; exit 3 ;;
    esac
done
if [ "${crit_threshold_days}" -gt "${warn_threshold_days}" ]; then
    log_error "Critical threshold (${crit_threshold_days}) must not exceed warning threshold (${warn_threshold_days})."
    exit 3
fi

# Load Pushover credentials. File takes precedence; environment is the fallback.
if [ -n "${credentials_file_path}" ]; then
    [ -r "${credentials_file_path}" ] || { log_error "Credentials file not readable: ${credentials_file_path}"; exit 3; }
    # shellcheck disable=SC1090
    . "${credentials_file_path}"
    log_debug "Sourced credentials from ${credentials_file_path}"
fi
pushover_token="${PUSHOVER_TOKEN:-}"
pushover_user="${PUSHOVER_USER:-}"

# Assemble the target list from repeated -H options and an optional hosts file.
if [ -n "${hosts_file_path}" ]; then
    [ -r "${hosts_file_path}" ] || { log_error "Hosts file not readable: ${hosts_file_path}"; exit 3; }
    while IFS= read -r hosts_file_line; do
        hosts_file_line="${hosts_file_line%%#*}"
        hosts_file_line="$(printf '%s' "${hosts_file_line}" | tr -d '[:space:]')"
        [ -n "${hosts_file_line}" ] && target_spec_list+=("${hosts_file_line}")
    done < "${hosts_file_path}"
fi
[ "${#target_spec_list[@]}" -gt 0 ] || { log_error "No targets specified. Use -H or -f."; exit 3; }

# Read the served leaf certificate notAfter date for one target.
# Output: the raw notAfter string on success, empty on failure.
read_notafter() {
    local host_arg="$1" port_arg="$2" raw_output=""
    raw_output="$(timeout "${connect_timeout_seconds}" \
        openssl s_client -connect "${host_arg}:${port_arg}" -servername "${host_arg}" </dev/null 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null)"
    printf '%s' "${raw_output#notAfter=}"
}

# Evaluation loop.
now_epoch="$(date +%s)"
declare -a summary_rows=()
declare -a alert_lines=()
worst_exit=0
have_critical=0

for target_spec in "${target_spec_list[@]}"; do
    target_host="${target_spec%%:*}"
    if [ "${target_spec}" = "${target_host}" ]; then
        target_port=443
    else
        target_port="${target_spec##*:}"
    fi
    log_debug "Checking ${target_host}:${target_port}"

    notafter_string="$(read_notafter "${target_host}" "${target_port}")"

    if [ -z "${notafter_string}" ]; then
        summary_rows+=("$(printf 'UNREACHABLE\t%s\t%s\t-\t-' "${target_host}" "${target_port}")")
        alert_lines+=("UNREACHABLE  ${target_host}:${target_port}  TLS connection or certificate read failed")
        worst_exit=2; have_critical=1
        log_warn "UNREACHABLE ${target_host}:${target_port}"
        continue
    fi

    expiry_epoch="$(date -d "${notafter_string}" +%s 2>/dev/null || true)"
    if [ -z "${expiry_epoch}" ]; then
        summary_rows+=("$(printf 'UNREACHABLE\t%s\t%s\t-\t-' "${target_host}" "${target_port}")")
        alert_lines+=("UNREACHABLE  ${target_host}:${target_port}  could not parse notAfter '${notafter_string}'")
        worst_exit=2; have_critical=1
        log_warn "Unparseable notAfter for ${target_host}:${target_port}: ${notafter_string}"
        continue
    fi

    expiry_iso="$(date -d "${notafter_string}" +%Y-%m-%d 2>/dev/null || echo '-')"
    days_remaining=$(( (expiry_epoch - now_epoch) / 86400 ))

    if [ "${days_remaining}" -lt 0 ]; then
        target_status="CRITICAL"
        human_remaining="expired $(( -days_remaining )) days ago"
    elif [ "${days_remaining}" -le "${crit_threshold_days}" ]; then
        target_status="CRITICAL"
        human_remaining="expires in ${days_remaining} days"
    elif [ "${days_remaining}" -le "${warn_threshold_days}" ]; then
        target_status="WARN"
        human_remaining="expires in ${days_remaining} days"
    else
        target_status="OK"
        human_remaining="expires in ${days_remaining} days"
    fi

    summary_rows+=("$(printf '%s\t%s\t%s\t%s\t%s' \
        "${target_status}" "${target_host}" "${target_port}" "${days_remaining}" "${expiry_iso}")")

    case "${target_status}" in
        CRITICAL)
            alert_lines+=("CRITICAL  ${target_host}:${target_port}  ${human_remaining} (${expiry_iso})")
            worst_exit=2; have_critical=1
            log_warn "CRITICAL ${target_host}:${target_port} ${human_remaining}" ;;
        WARN)
            alert_lines+=("WARN  ${target_host}:${target_port}  ${human_remaining} (${expiry_iso})")
            [ "${worst_exit}" -lt 1 ] && worst_exit=1
            log_warn "WARN ${target_host}:${target_port} ${human_remaining}" ;;
        OK)
            log_debug "OK ${target_host}:${target_port} ${human_remaining}" ;;
    esac
done

# Per-target summary (TSV) on stdout.
if [ "${flag_quiet}" -eq 0 ]; then
    printf 'status\thost\tport\tdays_remaining\tnot_after\n'
    for summary_row in "${summary_rows[@]}"; do
        printf '%s\n' "${summary_row}"
    done
fi

# Send a Pushover message via the API. Returns 0 on accepted, 1 otherwise.
send_pushover() {
    local message_arg="$1" priority_arg="$2" api_response=""
    api_response="$(curl -s --max-time 20 \
        --form-string "token=${pushover_token}" \
        --form-string "user=${pushover_user}" \
        --form-string "title=${notification_title}" \
        --form-string "message=${message_arg}" \
        --form-string "priority=${priority_arg}" \
        "${pushover_endpoint}" 2>/dev/null || true)"
    case "${api_response}" in
        *'"status":1'*) return 0 ;;
        *) log_error "Pushover send failed. Response: ${api_response:-<none>}"; return 1 ;;
    esac
}

# Decide whether to notify, and at what priority. Priority 1 bypasses quiet
# hours for critical conditions; warnings go at normal priority.
notification_body=""
notification_priority=0
if [ "${#alert_lines[@]}" -gt 0 ]; then
    notification_body="$(printf '%s\n' "${alert_lines[@]}")"
    [ "${have_critical}" -eq 1 ] && notification_priority=1
elif [ "${flag_notify_ok}" -eq 1 ]; then
    notification_body="All monitored certificates are healthy (${#target_spec_list[@]} checked)."
    notification_priority=0
fi

if [ -n "${notification_body}" ]; then
    if [ "${flag_dry_run}" -eq 1 ]; then
        log_info "Dry run. Would send Pushover (priority ${notification_priority}):"
        printf '%s\n' "${notification_body}" >&2
    elif [ -z "${pushover_token}" ] || [ -z "${pushover_user}" ]; then
        log_error "Alert condition present but Pushover credentials are missing. Set PUSHOVER_TOKEN/PUSHOVER_USER or use --credentials."
        exit 3
    else
        if send_pushover "${notification_body}" "${notification_priority}"; then
            log_info "Pushover notification sent (priority ${notification_priority})."
        fi
    fi
else
    log_debug "No alert condition and --notify-ok not set. No notification sent."
fi

exit "${worst_exit}"
