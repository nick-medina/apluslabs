#!/usr/bin/env bash
# ============================================================
# ollama-health.sh - Script 2: Ollama Health Check
# Author: Nick Medina
#
# Runs six checks against a local Ollama install and prints
# PASS or FAIL for each, then a final verdict:
#
#   1. Is the Ollama service running?
#   2. Is Ollama bound to 127.0.0.1 rather than 0.0.0.0?
#   3. Is the Ollama API responding?
#   4. How many models are installed?
#   5. Is model disk usage below 80% of its partition?
#   6. Any ERROR entries in the Ollama journal in the last hour?
#
# Verdict:  HEALTHY  - everything passed
#           WARNING  - non-critical issues found
#           CRITICAL - service down, API dead, or network-exposed
#
# Exit codes:  0 = HEALTHY   1 = WARNING   2 = CRITICAL
# (Nagios-style, so this drops straight into monitoring or cron.)
#
# Usage:  chmod +x ollama-health.sh
#         ./ollama-health.sh
# ============================================================

set -uo pipefail

PORT="${OLLAMA_PORT:-11434}"
DISK_THRESHOLD=80
DISK_CRITICAL=95
SERVICE_NAME='ollama'
OUTFILE="${HOME}/ollama_health_$(date +%F).txt"

# ------------------------------------------------ Colours
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

REPORT=()
CRITICAL_COUNT=0
WARNING_COUNT=0
PASS_COUNT=0

SUDO=''
if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
    SUDO='sudo'
fi

# ------------------------------------------------ Result helpers
# Each check reports through exactly one of these three so the
# counters and the printed status can never disagree.
out()  { REPORT+=("$1"); printf '%s\n' "$1"; }

pass() {
    REPORT+=("[PASS] $1")
    REPORT+=("       $2")
    printf '%s %s\n' "${GREEN}[PASS]${RESET}" "$1"
    [[ -n "${2:-}" ]] && printf '       %s\n' "$2"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail_warn() {
    REPORT+=("[FAIL] $1  (warning)")
    REPORT+=("       $2")
    printf '%s %s\n' "${YELLOW}[FAIL]${RESET}" "$1"
    [[ -n "${2:-}" ]] && printf '       %s\n' "$2"
    WARNING_COUNT=$((WARNING_COUNT + 1))
}

fail_crit() {
    REPORT+=("[FAIL] $1  (critical)")
    REPORT+=("       $2")
    printf '%s %s\n' "${RED}[FAIL]${RESET} ${BOLD}$1${RESET}"
    [[ -n "${2:-}" ]] && printf '       %s\n' "$2"
    CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
}

# A directory we lack traverse permission on is not the same as a
# missing directory. Retry through sudo before deciding it is absent.
dir_exists() {
    [[ -d "$1" ]] && return 0
    [[ -n "$SUDO" ]] && $SUDO test -d "$1" 2>/dev/null && return 0
    return 1
}

# ============================================================
# HEADER
# ============================================================
out "============================================================"
out "                OLLAMA HEALTH CHECK"
out "============================================================"
out "Host      : $(hostname)"
out "User      : $(whoami)"
out "Generated : $(date '+%Y-%m-%d %H:%M:%S %Z')"
out "API Port  : ${PORT}"
out "============================================================"
out ""

# ============================================================
# CHECK 1 - IS THE OLLAMA SERVICE RUNNING?
# ============================================================
out "CHECK 1: SERVICE STATUS"
out "------------------------------------------------------------"

SERVICE_STATE='unknown'
if command -v systemctl >/dev/null 2>&1; then
    SERVICE_STATE="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)"
fi

if [[ "$SERVICE_STATE" == "active" ]]; then
    SVC_PID="$(systemctl show "$SERVICE_NAME" -p MainPID --value 2>/dev/null)"
    SVC_SINCE="$(systemctl show "$SERVICE_NAME" -p ActiveEnterTimestamp --value 2>/dev/null)"
    pass "Ollama service is running" "systemctl is-active = active (PID ${SVC_PID:-unknown}), since ${SVC_SINCE:-unknown}"
elif pgrep -x ollama >/dev/null 2>&1 || pgrep -f 'ollama serve' >/dev/null 2>&1; then
    # Running, but not under systemd - a manual 'ollama serve' will not
    # survive a reboot, so this is a real finding even though it is up.
    MANUAL_PID="$(pgrep -x ollama 2>/dev/null | head -1)"
    [[ -z "$MANUAL_PID" ]] && MANUAL_PID="$(pgrep -f 'ollama serve' 2>/dev/null | head -1)"
    fail_warn "Ollama running outside systemd" "Process alive (PID ${MANUAL_PID}) but systemctl reports '${SERVICE_STATE}'. It will not restart on boot."
else
    fail_crit "Ollama service is NOT running" "systemctl is-active = ${SERVICE_STATE}. Start it with: sudo systemctl start ${SERVICE_NAME}"
fi
out ""

# ============================================================
# CHECK 2 - BIND ADDRESS (127.0.0.1 vs 0.0.0.0)
# ============================================================
out "CHECK 2: BIND ADDRESS SECURITY"
out "------------------------------------------------------------"

LISTEN_LINES=''
if command -v ss >/dev/null 2>&1; then
    LISTEN_LINES="$(ss -tuln 2>/dev/null | grep ":${PORT}\b")"
elif command -v netstat >/dev/null 2>&1; then
    LISTEN_LINES="$(netstat -tuln 2>/dev/null | grep ":${PORT}\b")"
fi

if [[ -z "$LISTEN_LINES" ]]; then
    fail_crit "Nothing is listening on port ${PORT}" "Cannot verify the bind address because no socket is open."
else
    BIND_ADDRS="$(awk '{print $5}' <<< "$LISTEN_LINES" | sed 's/.*://;d' 2>/dev/null)"
    EXPOSED=0
    LOOPBACK=0
    DETAIL=''
    while IFS= read -r sockline; do
        [[ -z "$sockline" ]] && continue
        ADDR="$(awk '{print $5}' <<< "$sockline")"
        [[ -z "$ADDR" ]] && ADDR="$(awk '{print $4}' <<< "$sockline")"
        DETAIL="${DETAIL}${ADDR} "
        case "$ADDR" in
            127.0.0.1:*|\[::1\]:*) LOOPBACK=1 ;;
            0.0.0.0:*|*\*:*|\[::\]:*|:::*) EXPOSED=1 ;;
            *) EXPOSED=1 ;;
        esac
    done <<< "$LISTEN_LINES"

    if [[ $EXPOSED -eq 1 ]]; then
        fail_crit "Ollama is exposed to the network" "Listening on: ${DETAIL}- Ollama has NO authentication. Anyone who can reach this port can run inference, pull models, and delete models. Set OLLAMA_HOST=127.0.0.1:${PORT} and restart."
    elif [[ $LOOPBACK -eq 1 ]]; then
        pass "Bound to loopback only" "Listening on: ${DETAIL}- not reachable from the network."
    else
        fail_warn "Bind address could not be classified" "Raw socket data: ${DETAIL}"
    fi
fi
out ""

# ============================================================
# CHECK 3 - IS THE API RESPONDING?
# ============================================================
out "CHECK 3: API RESPONSE"
out "------------------------------------------------------------"

API_URL="http://localhost:${PORT}/api/tags"
API_BODY=''
if command -v curl >/dev/null 2>&1; then
    API_BODY="$(curl -s --max-time 5 "$API_URL" 2>/dev/null)"
    API_RC=$?
else
    API_RC=127
fi

if [[ $API_RC -eq 127 ]]; then
    fail_warn "Cannot test the API" "curl is not installed. Install it with: sudo apt install curl"
elif [[ $API_RC -ne 0 || -z "$API_BODY" ]]; then
    fail_crit "API is not responding" "curl to ${API_URL} failed (exit ${API_RC}). The process may be alive but hung."
elif grep -q '"models"' <<< "$API_BODY"; then
    pass "API is responding" "${API_URL} returned a valid model list."
else
    fail_warn "API returned an unexpected payload" "Response did not contain a 'models' key: $(head -c 120 <<< "$API_BODY")"
fi
out ""

# ============================================================
# CHECK 4 - HOW MANY MODELS ARE INSTALLED?
# ============================================================
out "CHECK 4: INSTALLED MODELS"
out "------------------------------------------------------------"

MODEL_COUNT=-1
if command -v ollama >/dev/null 2>&1; then
    MODEL_COUNT="$(ollama list 2>/dev/null | tail -n +2 | grep -c '[^[:space:]]')"
fi

# Fall back to counting entries in the API response if the CLI is unavailable
if [[ "$MODEL_COUNT" -lt 0 && -n "$API_BODY" ]]; then
    MODEL_COUNT="$(grep -o '"name"' <<< "$API_BODY" | wc -l | tr -d ' ')"
fi

if [[ "$MODEL_COUNT" -gt 0 ]]; then
    # 'paste -d' treats its argument as a LIST of delimiters used cyclically,
    # so "-d ', '" alternates comma and space. Join with a comma, then space it.
    MODEL_NAMES="$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | paste -sd ',' - | sed 's/,/, /g')"
    # Tolerate both compact and pretty-printed JSON: "name":"x" and "name": "x"
    [[ -z "$MODEL_NAMES" ]] && MODEL_NAMES="$(grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]*"' <<< "$API_BODY" | awk -F'"' '{print $(NF-1)}' | paste -sd ',' - | sed 's/,/, /g')"
    pass "${MODEL_COUNT} model(s) installed" "${MODEL_NAMES:-names unavailable}"
elif [[ "$MODEL_COUNT" -eq 0 ]]; then
    fail_warn "No models installed" "Ollama is running but has nothing to serve. Pull one with: ollama pull llama3"
else
    fail_warn "Could not determine model count" "The 'ollama' binary was not found and the API gave no usable data."
fi
out ""

# ============================================================
# CHECK 5 - MODEL DISK USAGE BELOW 80%?
# ============================================================
out "CHECK 5: MODEL DISK USAGE"
out "------------------------------------------------------------"

# Installed as a systemd service, Ollama runs as its own 'ollama' user, so
# the models live in THAT user's home - not in the home of whoever runs
# this script. Resolve the real path rather than assuming ~/.ollama.
resolve_models_dir() {
    if [[ -n "${OLLAMA_MODELS:-}" ]] && dir_exists "${OLLAMA_MODELS}"; then
        printf '%s\n' "${OLLAMA_MODELS}"; return
    fi
    local pid owner userhome candidate
    pid="$(pgrep -x ollama 2>/dev/null | head -1)"
    [[ -z "$pid" ]] && pid="$(pgrep -f 'ollama serve' 2>/dev/null | head -1)"
    if [[ -n "$pid" ]]; then
        owner="$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')"
        if [[ -n "$owner" ]]; then
            userhome="$(getent passwd "$owner" 2>/dev/null | cut -d: -f6)"
            if [[ -n "$userhome" ]] && dir_exists "${userhome}/.ollama/models"; then
                printf '%s\n' "${userhome}/.ollama/models"; return
            fi
        fi
    fi
    for candidate in \
        "$HOME/.ollama/models" \
        /usr/share/ollama/.ollama/models \
        /var/lib/ollama/.ollama/models \
        /opt/ollama/.ollama/models
    do
        dir_exists "$candidate" && { printf '%s\n' "$candidate"; return; }
    done
    printf '%s\n' "$HOME/.ollama/models"
}

MODELS_DIR="$(resolve_models_dir)"

if ! dir_exists "$MODELS_DIR"; then
    fail_warn "Model directory not found" "Checked \$OLLAMA_MODELS, the service owner's home, and standard paths. Last tried: ${MODELS_DIR}"
else
    MODELS_SIZE="$(du -sh "$MODELS_DIR" 2>/dev/null | cut -f1)"
    [[ -z "$MODELS_SIZE" && -n "$SUDO" ]] && MODELS_SIZE="$($SUDO du -sh "$MODELS_DIR" 2>/dev/null | cut -f1)"

    DF_LINE="$(df -hP "$MODELS_DIR" 2>/dev/null | tail -1)"
    if [[ -z "$DF_LINE" ]]; then
        fail_warn "Could not read partition usage" "df returned nothing for ${MODELS_DIR}"
    else
        PART="$(awk '{print $1}' <<< "$DF_LINE")"
        PART_AVAIL="$(awk '{print $4}' <<< "$DF_LINE")"
        PCT="$(awk '{gsub(/%/,"",$5); print $5}' <<< "$DF_LINE")"
        MOUNT="$(awk '{print $6}' <<< "$DF_LINE")"
        DETAIL="Path: ${MODELS_DIR} (${MODELS_SIZE:-size unreadable}) on ${PART} mounted at ${MOUNT}, ${PART_AVAIL} free, ${PCT}% used"

        if [[ ! "$PCT" =~ ^[0-9]+$ ]]; then
            fail_warn "Could not parse disk usage" "$DETAIL"
        elif [[ "$PCT" -ge "$DISK_CRITICAL" ]]; then
            fail_crit "Partition is ${PCT}% full" "$DETAIL - free space now with: ollama rm <model>"
        elif [[ "$PCT" -gt "$DISK_THRESHOLD" ]]; then
            fail_warn "Partition is ${PCT}% full (threshold ${DISK_THRESHOLD}%)" "$DETAIL"
        else
            pass "Disk usage is ${PCT}% (below ${DISK_THRESHOLD}%)" "$DETAIL"
        fi
    fi
fi
out ""

# ============================================================
# CHECK 6 - ERRORS IN THE JOURNAL IN THE LAST HOUR
# ============================================================
out "CHECK 6: JOURNAL ERRORS (LAST HOUR)"
out "------------------------------------------------------------"

if ! command -v journalctl >/dev/null 2>&1; then
    fail_warn "Cannot check the journal" "journalctl is not available on this system."
else
    JOURNAL_RAW="$($SUDO journalctl -u "$SERVICE_NAME" --since '1 hour ago' --no-pager -q 2>/dev/null)"
    if [[ -z "$JOURNAL_RAW" ]]; then
        pass "No journal entries in the last hour" "Either the service has been quiet, or the journal is not readable by this user."
    else
        ERROR_LINES="$(grep -iE 'error|fatal|panic|failed' <<< "$JOURNAL_RAW")"
        ERROR_COUNT="$(grep -c . <<< "${ERROR_LINES}")"
        [[ -z "$ERROR_LINES" ]] && ERROR_COUNT=0

        if [[ "$ERROR_COUNT" -eq 0 ]]; then
            TOTAL_LINES="$(grep -c . <<< "$JOURNAL_RAW")"
            pass "No ERROR entries in the last hour" "Scanned ${TOTAL_LINES} journal line(s), none matched error patterns."
        else
            fail_warn "${ERROR_COUNT} error entr(ies) in the last hour" "Most recent shown below."
            out ""
            while IFS= read -r eline; do
                [[ -z "$eline" ]] && continue
                SHORT="$(cut -c1-160 <<< "$eline")"
                REPORT+=("       ${SHORT}")
                printf '       %s\n' "${RED}${SHORT}${RESET}"
            done <<< "$(tail -5 <<< "$ERROR_LINES")"
        fi
    fi
fi
out ""

# ============================================================
# FINAL VERDICT
# ============================================================
TOTAL_CHECKS=$((PASS_COUNT + WARNING_COUNT + CRITICAL_COUNT))

out "============================================================"
out "SUMMARY"
out "------------------------------------------------------------"
out "Checks passed   : ${PASS_COUNT} of ${TOTAL_CHECKS}"
out "Warnings        : ${WARNING_COUNT}"
out "Critical issues : ${CRITICAL_COUNT}"
out ""

if [[ $CRITICAL_COUNT -gt 0 ]]; then
    VERDICT='CRITICAL'
    VERDICT_COLOR="$RED"
    VERDICT_NOTE='Ollama is down, unreachable, or exposed to the network. Act now.'
    EXIT_CODE=2
elif [[ $WARNING_COUNT -gt 0 ]]; then
    VERDICT='WARNING'
    VERDICT_COLOR="$YELLOW"
    VERDICT_NOTE='Ollama is serving requests, but issues were found that need attention.'
    EXIT_CODE=1
else
    VERDICT='HEALTHY'
    VERDICT_COLOR="$GREEN"
    VERDICT_NOTE='All checks passed. Service is running, private, and responding.'
    EXIT_CODE=0
fi

REPORT+=("OVERALL STATUS: ${VERDICT}")
REPORT+=("${VERDICT_NOTE}")
REPORT+=("============================================================")

printf '%s\n' "${VERDICT_COLOR}${BOLD}OVERALL STATUS: ${VERDICT}${RESET}"
printf '%s\n' "${VERDICT_NOTE}"
printf '%s\n' "============================================================"

# ============================================================
# SAVE REPORT
# ============================================================
if printf '%s\n' "${REPORT[@]}" > "$OUTFILE" 2>/dev/null; then
    printf '\n%s\n' "${CYAN}Report saved to: ${OUTFILE}${RESET}"
else
    printf '\n%s\n' "${RED}Could not write report to ${OUTFILE}${RESET}"
fi

exit $EXIT_CODE
