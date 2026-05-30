#!/usr/bin/env bash
#
# Synopsis:
#   Pace upgrade searches across Sonarr and Radarr libraries to work through an
#   upgrade backlog (for example after a custom format or scoring change) without
#   exceeding indexer query quotas.
#
# Description:
#   Iterates monitored items in each application and triggers one search command
#   per item, sleeping a configurable interval between each so indexer query
#   volume stays low. Processed item IDs are recorded in a state file so an
#   interrupted run resumes instead of restarting. The applications are reached
#   over their reverse-proxy API paths, which bypass the forward-auth gate, so
#   this can run from a host shell that has no direct route to the internal
#   container network.
#
#   Modes:
#     all     - every monitored item that has a file. Re-evaluates each for
#               custom format / codec upgrades such as x265. Default.
#     cutoff  - only items below their quality cutoff (quality upgrades).
#
#   Search units:
#     Radarr  - one MoviesSearch per movie.
#     Sonarr  - one SeriesSearch per series in 'all' mode, or one EpisodeSearch
#               per episode in 'cutoff' mode. A SeriesSearch queries indexers for
#               every monitored episode of the series at once, so the per-item
#               delay should be sized with large series in mind.
#
# Parameters:
#   --app NAME           sonarr | radarr | both    (default: both)
#   --mode MODE          all | cutoff              (default: all)
#   --delay SECONDS      pause between search commands (default: 120)
#   --jitter SECONDS     random 0..N seconds added to each delay (default: 0)
#   --max-per-run N      stop after N searches; 0 means no limit (default: 0)
#   --loop               after finishing a pass, wait and rescan for new items
#   --loop-interval SEC  wait between loop passes (default: 3600)
#   --state-file PATH    progress/resume file (default: next to this script)
#   --config PATH        config file to source for URLs and API keys
#   --reset              clear the state file before starting
#   --dry-run            list what would be searched; trigger nothing
#   --debug              verbose tracing to stderr
#   -h | --help          show this help
#
# Configuration (config file sourced via --config, or environment variables):
#   SONARR_URL          base URL including the URL base, no trailing slash
#                       example: https://dvr.example.com/sonarr
#   SONARR_API_KEY      optional; if unset, read from SONARR_CONFIG_XML
#   SONARR_CONFIG_XML   path to the Sonarr config.xml for API key extraction
#   RADARR_URL, RADARR_API_KEY, RADARR_CONFIG_XML   same for Radarr
#
# Examples:
#   # Crawl everything at 2 minute spacing, resumable, inside a screen session:
#   screen -S arrpace ./arr-upgrade-pacer.sh --config ./arr-upgrade-pacer.conf --delay 120
#
#   # Quality-cutoff-unmet movies only, 50 per run, preview first:
#   ./arr-upgrade-pacer.sh --app radarr --mode cutoff --max-per-run 50 --dry-run
#

set -o errexit
set -o nounset
set -o pipefail

# --- Defaults --------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARG_APP="both"
ARG_MODE="all"
ARG_DELAY=120
ARG_JITTER=0
ARG_MAX_PER_RUN=0
ARG_LOOP=0
ARG_LOOP_INTERVAL=3600
ARG_STATE_FILE="${SCRIPT_DIR}/arr-upgrade-pacer.state.tsv"
ARG_CONFIG=""
ARG_RESET=0
ARG_DRY_RUN=0
ARG_DEBUG=0

# Configuration placeholders. Override via --config or environment.
SONARR_URL="${SONARR_URL:-https://dvr.example.com/sonarr}"
SONARR_API_KEY="${SONARR_API_KEY:-}"
SONARR_CONFIG_XML="${SONARR_CONFIG_XML:-/path/to/sonarr/config.xml}"
RADARR_URL="${RADARR_URL:-https://dvr.example.com/radarr}"
RADARR_API_KEY="${RADARR_API_KEY:-}"
RADARR_CONFIG_XML="${RADARR_CONFIG_XML:-/path/to/radarr/config.xml}"

STOP_REQUESTED=0
SEARCHES_THIS_RUN=0

# --- Logging ---------------------------------------------------------------

log() {
    printf '%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

log_debug() {
    if [[ "${ARG_DEBUG}" -eq 1 ]]; then
        printf '%s\tDEBUG\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
    fi
}

die() {
    printf '%s\tERROR\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
    exit 1
}

usage() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# --- Signal handling -------------------------------------------------------

request_stop() {
    STOP_REQUESTED=1
    log "Stop requested. Finishing current item, then exiting cleanly."
}
trap request_stop INT TERM

# --- Argument parsing ------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app)            ARG_APP="$2"; shift 2 ;;
            --mode)           ARG_MODE="$2"; shift 2 ;;
            --delay)          ARG_DELAY="$2"; shift 2 ;;
            --jitter)         ARG_JITTER="$2"; shift 2 ;;
            --max-per-run)    ARG_MAX_PER_RUN="$2"; shift 2 ;;
            --loop)           ARG_LOOP=1; shift ;;
            --loop-interval)  ARG_LOOP_INTERVAL="$2"; shift 2 ;;
            --state-file)     ARG_STATE_FILE="$2"; shift 2 ;;
            --config)         ARG_CONFIG="$2"; shift 2 ;;
            --reset)          ARG_RESET=1; shift ;;
            --dry-run)        ARG_DRY_RUN=1; shift ;;
            --debug)          ARG_DEBUG=1; shift ;;
            -h|--help)        usage 0 ;;
            *)                die "Unknown argument: $1 (use --help)" ;;
        esac
    done

    case "${ARG_APP}" in sonarr|radarr|both) ;; *) die "--app must be sonarr, radarr, or both" ;; esac
    case "${ARG_MODE}" in all|cutoff) ;; *) die "--mode must be all or cutoff" ;; esac
    [[ "${ARG_DELAY}" =~ ^[0-9]+$ ]] || die "--delay must be an integer"
    [[ "${ARG_JITTER}" =~ ^[0-9]+$ ]] || die "--jitter must be an integer"
    [[ "${ARG_MAX_PER_RUN}" =~ ^[0-9]+$ ]] || die "--max-per-run must be an integer"
}

# --- Dependency and config resolution --------------------------------------

require_dependencies() {
    command -v curl >/dev/null 2>&1 || die "curl is required but not found"
    command -v jq >/dev/null 2>&1 || die "jq is required but not found"
}

load_config() {
    if [[ -n "${ARG_CONFIG}" ]]; then
        [[ -f "${ARG_CONFIG}" ]] || die "Config file not found: ${ARG_CONFIG}"
        # shellcheck disable=SC1090
        source "${ARG_CONFIG}"
        log_debug "Sourced config: ${ARG_CONFIG}"
    fi
}

# Read an API key from a Sonarr/Radarr config.xml if not already set.
resolve_api_key() {
    local current_key="$1"
    local config_xml_path="$2"
    local label="$3"
    if [[ -n "${current_key}" ]]; then
        printf '%s' "${current_key}"
        return 0
    fi
    if [[ -f "${config_xml_path}" ]]; then
        local extracted_key
        extracted_key="$(grep -oE '<ApiKey>[^<]+</ApiKey>' "${config_xml_path}" | sed -E 's/<\/?ApiKey>//g' | head -n1)"
        if [[ -n "${extracted_key}" ]]; then
            log_debug "${label} API key read from ${config_xml_path}"
            printf '%s' "${extracted_key}"
            return 0
        fi
    fi
    die "${label} API key not set and could not be read from ${config_xml_path}"
}

# --- API helpers -----------------------------------------------------------

api_get() {
    local base_url="$1"
    local api_key="$2"
    local path="$3"
    curl -sS --fail --max-time 60 \
        -H "X-Api-Key: ${api_key}" \
        "${base_url}/api/v3/${path}"
}

api_post_command() {
    local base_url="$1"
    local api_key="$2"
    local json_body="$3"
    curl -sS --fail --max-time 60 \
        -H "X-Api-Key: ${api_key}" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "${json_body}" \
        "${base_url}/api/v3/command" >/dev/null
}

# Verify connectivity and key before crawling.
verify_app() {
    local base_url="$1"
    local api_key="$2"
    local label="$3"
    if api_get "${base_url}" "${api_key}" "system/status" >/dev/null 2>&1; then
        log "${label} reachable at ${base_url}"
    else
        die "${label} not reachable at ${base_url}/api/v3 (check URL, base path, and API key)"
    fi
}

# --- Unit list builders (output TSV: unit_id<TAB>title) --------------------

build_radarr_units() {
    local base_url="$1" api_key="$2" mode="$3"
    if [[ "${mode}" == "cutoff" ]]; then
        local page=1 page_size=1000 count
        while true; do
            local body
            body="$(api_get "${base_url}" "${api_key}" "wanted/cutoff?page=${page}&pageSize=${page_size}&sortKey=title&monitored=true")"
            count="$(printf '%s' "${body}" | jq '.records | length')"
            printf '%s' "${body}" | jq -r '.records[] | [(.id|tostring), .title] | @tsv'
            [[ "${count}" -lt "${page_size}" ]] && break
            page=$((page + 1))
        done
    else
        api_get "${base_url}" "${api_key}" "movie" \
            | jq -r '.[] | select(.monitored == true and .hasFile == true) | [(.id|tostring), .title] | @tsv'
    fi
}

build_sonarr_units() {
    local base_url="$1" api_key="$2" mode="$3"
    if [[ "${mode}" == "cutoff" ]]; then
        local page=1 page_size=1000 count
        while true; do
            local body
            body="$(api_get "${base_url}" "${api_key}" "wanted/cutoff?page=${page}&pageSize=${page_size}&sortKey=series.title&monitored=true&includeSeries=true")"
            count="$(printf '%s' "${body}" | jq '.records | length')"
            printf '%s' "${body}" | jq -r '.records[] | [(.id|tostring), ((.series.title // "Unknown") + " - S" + (.seasonNumber|tostring) + "E" + (.episodeNumber|tostring))] | @tsv'
            [[ "${count}" -lt "${page_size}" ]] && break
            page=$((page + 1))
        done
    else
        api_get "${base_url}" "${api_key}" "series" \
            | jq -r '.[] | select(.monitored == true) | [(.id|tostring), .title] | @tsv'
    fi
}

# --- Search triggers -------------------------------------------------------

trigger_radarr() {
    local base_url="$1" api_key="$2" unit_id="$3"
    api_post_command "${base_url}" "${api_key}" "{\"name\":\"MoviesSearch\",\"movieIds\":[${unit_id}]}"
}

trigger_sonarr() {
    local base_url="$1" api_key="$2" mode="$3" unit_id="$4"
    if [[ "${mode}" == "cutoff" ]]; then
        api_post_command "${base_url}" "${api_key}" "{\"name\":\"EpisodeSearch\",\"episodeIds\":[${unit_id}]}"
    else
        api_post_command "${base_url}" "${api_key}" "{\"name\":\"SeriesSearch\",\"seriesId\":${unit_id}}"
    fi
}

# --- State file ------------------------------------------------------------

state_seen() {
    local app="$1" unit_id="$2"
    [[ -f "${ARG_STATE_FILE}" ]] || return 1
    awk -F'\t' -v a="${app}" -v i="${unit_id}" '$2==a && $4==i {found=1} END{exit found?0:1}' "${ARG_STATE_FILE}"
}

state_record() {
    local app="$1" unit_type="$2" unit_id="$3" title="$4"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "${app}" "${unit_type}" "${unit_id}" "${title}" \
        >> "${ARG_STATE_FILE}"
}

# --- Sleep with jitter and stop awareness ----------------------------------

paced_sleep() {
    local base="$1"
    local extra=0
    if [[ "${ARG_JITTER}" -gt 0 ]]; then
        extra=$(( RANDOM % (ARG_JITTER + 1) ))
    fi
    local total=$(( base + extra ))
    log_debug "Sleeping ${total}s (base ${base} + jitter ${extra})"
    local elapsed=0
    while [[ "${elapsed}" -lt "${total}" ]]; do
        [[ "${STOP_REQUESTED}" -eq 1 ]] && return 0
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

# --- Per-app processing ----------------------------------------------------

process_app() {
    local app="$1" base_url="$2" api_key="$3"
    local unit_type units total idx=0 processed=0 skipped=0

    if [[ "${app}" == "radarr" ]]; then
        unit_type="movie"
        units="$(build_radarr_units "${base_url}" "${api_key}" "${ARG_MODE}")"
    else
        unit_type="$([[ "${ARG_MODE}" == "cutoff" ]] && echo episode || echo series)"
        units="$(build_sonarr_units "${base_url}" "${api_key}" "${ARG_MODE}")"
    fi

    total="$(printf '%s\n' "${units}" | grep -c . || true)"
    log "${app}: ${total} ${unit_type} unit(s) found for mode '${ARG_MODE}'"
    [[ "${total}" -eq 0 ]] && return 0

    while IFS=$'\t' read -r unit_id title; do
        [[ -z "${unit_id}" ]] && continue
        idx=$((idx + 1))

        if [[ "${STOP_REQUESTED}" -eq 1 ]]; then
            log "${app}: stop requested, halting at ${idx}/${total}"
            break
        fi

        if state_seen "${app}" "${unit_id}"; then
            skipped=$((skipped + 1))
            log_debug "${app}: skip already-processed ${unit_type} ${unit_id} (${title})"
            continue
        fi

        if [[ "${ARG_MAX_PER_RUN}" -gt 0 && "${SEARCHES_THIS_RUN}" -ge "${ARG_MAX_PER_RUN}" ]]; then
            log "${app}: reached --max-per-run ${ARG_MAX_PER_RUN}, stopping this pass"
            break
        fi

        if [[ "${ARG_DRY_RUN}" -eq 1 ]]; then
            log "DRY-RUN ${app}: would search ${unit_type} ${unit_id} - ${title}"
            continue
        fi

        log "${app}: searching ${unit_type} ${unit_id} - ${title}  [${idx}/${total}]"
        if [[ "${app}" == "radarr" ]]; then
            if trigger_radarr "${base_url}" "${api_key}" "${unit_id}"; then
                state_record "${app}" "${unit_type}" "${unit_id}" "${title}"
                processed=$((processed + 1)); SEARCHES_THIS_RUN=$((SEARCHES_THIS_RUN + 1))
            else
                log "${app}: search command failed for ${unit_type} ${unit_id}; not recording, will retry next pass"
            fi
        else
            if trigger_sonarr "${base_url}" "${api_key}" "${ARG_MODE}" "${unit_id}"; then
                state_record "${app}" "${unit_type}" "${unit_id}" "${title}"
                processed=$((processed + 1)); SEARCHES_THIS_RUN=$((SEARCHES_THIS_RUN + 1))
            else
                log "${app}: search command failed for ${unit_type} ${unit_id}; not recording, will retry next pass"
            fi
        fi

        paced_sleep "${ARG_DELAY}"
    done <<< "${units}"

    log "${app}: pass complete - searched ${processed}, skipped ${skipped} of ${total}"
}

# --- Main ------------------------------------------------------------------

run_pass() {
    SEARCHES_THIS_RUN=0
    if [[ "${ARG_APP}" == "radarr" || "${ARG_APP}" == "both" ]]; then
        process_app "radarr" "${RADARR_URL}" "${RADARR_API_KEY}"
        [[ "${STOP_REQUESTED}" -eq 1 ]] && return 0
    fi
    if [[ "${ARG_APP}" == "sonarr" || "${ARG_APP}" == "both" ]]; then
        process_app "sonarr" "${SONARR_URL}" "${SONARR_API_KEY}"
    fi
}

main() {
    parse_args "$@"
    require_dependencies
    load_config

    if [[ "${ARG_RESET}" -eq 1 && -f "${ARG_STATE_FILE}" ]]; then
        log "Resetting state file: ${ARG_STATE_FILE}"
        : > "${ARG_STATE_FILE}"
    fi
    touch "${ARG_STATE_FILE}" 2>/dev/null || die "Cannot write state file: ${ARG_STATE_FILE}"

    log "Config: app=${ARG_APP} mode=${ARG_MODE} delay=${ARG_DELAY}s jitter=${ARG_JITTER}s max-per-run=${ARG_MAX_PER_RUN} loop=${ARG_LOOP} dry-run=${ARG_DRY_RUN}"
    log "State file: ${ARG_STATE_FILE}"

    # Resolve keys and verify connectivity for the apps in scope.
    if [[ "${ARG_APP}" == "radarr" || "${ARG_APP}" == "both" ]]; then
        RADARR_API_KEY="$(resolve_api_key "${RADARR_API_KEY}" "${RADARR_CONFIG_XML}" "Radarr")"
        verify_app "${RADARR_URL}" "${RADARR_API_KEY}" "Radarr"
    fi
    if [[ "${ARG_APP}" == "sonarr" || "${ARG_APP}" == "both" ]]; then
        SONARR_API_KEY="$(resolve_api_key "${SONARR_API_KEY}" "${SONARR_CONFIG_XML}" "Sonarr")"
        verify_app "${SONARR_URL}" "${SONARR_API_KEY}" "Sonarr"
    fi

    while true; do
        run_pass
        if [[ "${STOP_REQUESTED}" -eq 1 ]]; then
            log "Exiting on stop request. Progress saved in ${ARG_STATE_FILE}"
            break
        fi
        if [[ "${ARG_LOOP}" -eq 1 ]]; then
            log "Loop pass complete. Waiting ${ARG_LOOP_INTERVAL}s before next pass."
            local waited=0
            while [[ "${waited}" -lt "${ARG_LOOP_INTERVAL}" ]]; do
                [[ "${STOP_REQUESTED}" -eq 1 ]] && break
                sleep 5; waited=$((waited + 5))
            done
            [[ "${STOP_REQUESTED}" -eq 1 ]] && { log "Exiting on stop request."; break; }
        else
            log "All passes complete."
            break
        fi
    done
}

main "$@"
