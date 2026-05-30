#!/usr/bin/env bash
#
# Synopsis:
#   Set the reverse-proxy URL base and disable native authentication for local
#   addresses across the *arr applications by editing each config.xml while the
#   application is stopped. Access control is handled at the proxy; the apps are
#   reachable only over the internal network, so local requests need no prompt.
#
# Description:
#   For each selected app the script stops the TrueNAS app, backs up and edits
#   its config.xml (UrlBase, AuthenticationRequired, and AuthenticationMethod),
#   then starts it again. Existing Username and Password elements are left
#   untouched, so an already-configured credential keeps validating under Basic;
#   only the URL base, method, and requirement flags change. Editing is
#   performed only while the app is stopped, because a running *arr rewrites
#   config.xml from memory on shutdown and would discard a live edit. The schema
#   is identical across Sonarr, Radarr, Lidarr, Readarr, and Prowlarr, so one
#   routine covers all five.
#
#   Scope: this handles only the *arr apps. Sabnzbd (sabnzbd.ini) and Tautulli
#   (config.ini) use different formats and are handled separately. This script
#   does not touch inter-app connectors or network bindings.
#
#   The default mode is a dry run that reports current versus target values
#   without stopping anything. --apply performs the stop, edit, and start. The
#   operation is file-based and works with the host firewall left in place.
#
# Parameters:
#   -a, --app NAME       Limit to the named app. Repeatable. Default: all five.
#   -b, --base DIR       App-volumes parent directory. Default below.
#   --apply              Perform the changes. Without it, only report.
#   --no-backup          Skip the per-file backup (not recommended).
#   -t, --timeout SEC    Per-job timeout for stop/start. Default 300.
#   -d, --debug          Verbose tracing to stderr.
#   -h, --help           Show this help text and exit.
#
# Examples:
#   ./prep-arr-apps.sh
#   ./prep-arr-apps.sh --apply
#   ./prep-arr-apps.sh -a radarr -a readarr --apply
#

set -uo pipefail

# App name to URL base. Dataset is <base>/<app name>.
declare -a arr_app_list=(sonarr radarr lidarr readarr prowlarr)
app_volumes_base="/mnt/tank/app-volumes"
declare -a requested_app_list=()
flag_apply=0
flag_skip_backup=0
flag_debug=0
job_timeout_seconds=300
poll_interval_seconds=3

log_line() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" >&2; }
log_info()  { log_line "INFO"  "$1"; }
log_warn()  { log_line "WARN"  "$1"; }
log_error() { log_line "ERROR" "$1"; }
log_debug() { [ "${flag_debug}" -eq 1 ] && log_line "DEBUG" "$1" || true; }

print_usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        -a|--app)
            [ $# -ge 2 ] || { log_error "Option $1 requires a value."; exit 2; }
            requested_app_list+=("$2"); shift 2 ;;
        -b|--base)
            [ $# -ge 2 ] || { log_error "Option $1 requires a value."; exit 2; }
            app_volumes_base="$2"; shift 2 ;;
        --apply)      flag_apply=1; shift ;;
        --no-backup)  flag_skip_backup=1; shift ;;
        -t|--timeout)
            [ $# -ge 2 ] || { log_error "Option $1 requires a value."; exit 2; }
            job_timeout_seconds="$2"; shift 2 ;;
        -d|--debug)   flag_debug=1; shift ;;
        -h|--help)    print_usage; exit 0 ;;
        *) log_error "Unknown argument: $1"; exit 2 ;;
    esac
done

for required_cmd in midclt jq python3 find; do
    command -v "${required_cmd}" >/dev/null 2>&1 || { log_error "Required command not found: ${required_cmd}"; exit 3; }
done

# Resolve the working set.
declare -a working_app_list=()
if [ "${#requested_app_list[@]}" -gt 0 ]; then
    for requested_name in "${requested_app_list[@]}"; do
        if printf '%s\n' "${arr_app_list[@]}" | grep -Fxq "${requested_name}"; then
            working_app_list+=("${requested_name}")
        else
            log_error "Not a recognized *arr app: ${requested_name}"; exit 2
        fi
    done
else
    working_app_list=("${arr_app_list[@]}")
fi

# Poll a middleware job to a terminal state. Returns 0 on SUCCESS.
wait_for_job() {
    local job_id_local="$1" job_state_local="" elapsed_local=0
    while [ "${elapsed_local}" -lt "${job_timeout_seconds}" ]; do
        job_state_local="$(midclt call core.get_jobs "[[\"id\",\"=\",${job_id_local}]]" 2>/dev/null \
            | jq -r '.[0].state // "UNKNOWN"')"
        case "${job_state_local}" in
            SUCCESS) return 0 ;;
            FAILED|ABORTED) return 1 ;;
        esac
        sleep "${poll_interval_seconds}"
        elapsed_local=$(( elapsed_local + poll_interval_seconds ))
    done
    return 1
}

run_app_job() {
    local method_local="$1" app_local="$2" job_id_local=""
    job_id_local="$(midclt call "${method_local}" "${app_local}" 2>/dev/null || true)"
    case "${job_id_local}" in
        ''|*[!0-9]*) log_error "${method_local} for ${app_local}: no job id (got '${job_id_local}')"; return 1 ;;
    esac
    wait_for_job "${job_id_local}"
}

# Locate a *arr config.xml under a dataset (one carrying UrlBase/ApiKey).
find_arr_config() {
    local dataset_local="$1" candidate_local=""
    while IFS= read -r candidate_local; do
        if grep -q "<ApiKey>" "${candidate_local}" 2>/dev/null; then
            printf '%s' "${candidate_local}"; return 0
        fi
    done < <(find "${dataset_local}" -maxdepth 3 -name 'config.xml' 2>/dev/null)
    return 1
}

# Inspect or edit one config.xml. Prints TSV element rows. Writes only if apply=1.
edit_arr_config() {
    python3 - "$1" "$2" "$3" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
config_path, url_base_target, apply_flag = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
xml_tree = ET.parse(config_path)
xml_root = xml_tree.getroot()

def apply_element(tag_name, target_value, keep_if_set=False):
    element_node = xml_root.find(tag_name)
    current_value = element_node.text if element_node is not None else None
    resolved_target = target_value
    if keep_if_set and current_value and current_value.strip() and current_value.strip().lower() != "none":
        resolved_target = current_value
    is_change = (current_value or "") != (resolved_target or "")
    if apply_flag:
        if element_node is None:
            element_node = ET.SubElement(xml_root, tag_name)
        element_node.text = resolved_target
    print("%s\t%s\t%s\t%s" % (tag_name, current_value, resolved_target, "CHANGE" if is_change else "ok"))

apply_element("UrlBase", url_base_target)
apply_element("AuthenticationRequired", "DisabledForLocalAddresses")
apply_element("AuthenticationMethod", "Forms", keep_if_set=True)

if apply_flag:
    xml_tree.write(config_path, encoding="utf-8", xml_declaration=True)
PYEOF
}

printf 'app\tconfig\telement\told\tnew\tstatus\n'
exit_status=0

for current_app in "${working_app_list[@]}"; do
    app_dataset="${app_volumes_base}/${current_app}"
    url_base_value="/${current_app}"

    if [ ! -d "${app_dataset}" ]; then
        printf '%s\t-\t-\t-\t-\tNO-DATASET\n' "${current_app}"; exit_status=1; continue
    fi
    config_file="$(find_arr_config "${app_dataset}" || true)"
    if [ -z "${config_file}" ]; then
        printf '%s\t-\t-\t-\t-\tNO-CONFIG\n' "${current_app}"; exit_status=1; continue
    fi

    if [ "${flag_apply}" -eq 0 ]; then
        while IFS= read -r element_row; do
            printf '%s\t%s\t%s\n' "${current_app}" "${config_file}" "${element_row}"
        done < <(edit_arr_config "${config_file}" "${url_base_value}" "0")
        continue
    fi

    log_info "Stopping ${current_app}"
    if ! run_app_job app.stop "${current_app}"; then
        printf '%s\t%s\t-\t-\t-\tSTOP-FAILED\n' "${current_app}" "${config_file}"; exit_status=1; continue
    fi

    if [ "${flag_skip_backup}" -eq 0 ]; then
        cp -p "${config_file}" "${config_file}.bak.$(date +%Y%m%d-%H%M%S)"
    fi

    while IFS= read -r element_row; do
        printf '%s\t%s\t%s\n' "${current_app}" "${config_file}" "${element_row}"
    done < <(edit_arr_config "${config_file}" "${url_base_value}" "1")

    log_info "Starting ${current_app}"
    if ! run_app_job app.start "${current_app}"; then
        printf '%s\t%s\t-\t-\t-\tSTART-FAILED\n' "${current_app}" "${config_file}"; exit_status=1; continue
    fi
    log_info "${current_app} done"
done

exit "${exit_status}"
