#!/usr/bin/env bash
# ============================================================
# Script B - Enhanced Ollama Health Monitor
# Sierra Valley Unified School District
# Author: Nick Medina   IT100 Summer 2026
#
# Extends the base health check with the two controls required
# by the district AI governance policy:
#
#   * UNAUTHORIZED MODEL DETECTION - compares installed models
#     against the approved model list and alerts on anything else
#   * NETWORK EXPOSURE ALERT - alerts if the API is bound to
#     0.0.0.0 instead of 127.0.0.1
#
# Plus the baseline checks: service running, API responding,
# disk usage, and journal errors.
#
# Alerts are sent to syslog always, and optionally by email and
# webhook. Designed to run from cron every 15 minutes.
#
# Exit codes:  0 = HEALTHY   1 = WARNING   2 = CRITICAL
#
# Usage:  chmod +x ScriptB-OllamaMonitor.sh
#         ./ScriptB-OllamaMonitor.sh
#         ./ScriptB-OllamaMonitor.sh --quiet     (cron mode)
# ============================================================

set -uo pipefail

# ---------------------------------------- Configuration
PORT="${OLLAMA_PORT:-11434}"
SERVICE_NAME='ollama'
DISK_THRESHOLD=80
DISK_CRITICAL=95

# Approved model list, per the SVUSD AI Model Governance Policy.
# Anything installed that is not on this list is UNAUTHORIZED.
# Update this list only through the documented approval process.
APPROVED_MODELS=(
  "llama3.1:8b"
  "qwen2.5:14b"
  "gemma3:12b"
  "qwen2.5:32b"
  "nomic-embed-text:latest"
)

# Alerting. Leave ALERT_EMAIL or ALERT_WEBHOOK empty to disable.
ALERT_EMAIL="${ALERT_EMAIL:-}"
ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"
SYSLOG_TAG='svusd-ollama-monitor'

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

# ---------------------------------------- Output helpers
if [[ -t 1 && $QUIET -eq 0 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

REPORT=()
ALERTS=()
CRITICAL_COUNT=0
WARNING_COUNT=0
PASS_COUNT=0

SUDO=''
if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  SUDO='sudo'
fi

say() { [[ $QUIET -eq 0 ]] && printf '%s\n' "$1"; return 0; }
out() { REPORT+=("$1"); say "$1"; }

pass() {
  REPORT+=("[PASS] $1"); REPORT+=("       $2")
  [[ $QUIET -eq 0 ]] && printf '%s %s\n       %s\n' "${GREEN}[PASS]${RESET}" "$1" "$2"
  PASS_COUNT=$((PASS_COUNT + 1)); return 0
}
warn() {
  REPORT+=("[WARN] $1"); REPORT+=("       $2"); ALERTS+=("WARNING: $1 - $2")
  [[ $QUIET -eq 0 ]] && printf '%s %s\n       %s\n' "${YELLOW}[WARN]${RESET}" "$1" "$2"
  WARNING_COUNT=$((WARNING_COUNT + 1)); return 0
}
crit() {
  REPORT+=("[CRIT] $1"); REPORT+=("       $2"); ALERTS+=("CRITICAL: $1 - $2")
  [[ $QUIET -eq 0 ]] && printf '%s %s\n       %s\n' "${RED}[CRIT]${RESET}" "${BOLD}$1${RESET}" "$2"
  CRITICAL_COUNT=$((CRITICAL_COUNT + 1)); return 0
}

dir_exists() {
  [[ -d "$1" ]] && return 0
  [[ -n "$SUDO" ]] && $SUDO test -d "$1" 2>/dev/null && return 0
  return 1
}

# ---------------------------------------- Header
out "============================================================"
out "        SVUSD OLLAMA MONITOR - AI SERVER HEALTH"
out "============================================================"
out "Host      : $(hostname)"
out "Generated : $(date '+%Y-%m-%d %H:%M:%S %Z')"
out "API Port  : ${PORT}"
out "Approved models on list: ${#APPROVED_MODELS[@]}"
out "============================================================"
out ""

# ============================================================
# CHECK 1 - SERVICE RUNNING
# ============================================================
out "CHECK 1: SERVICE STATUS"
out "------------------------------------------------------------"
SERVICE_STATE='unknown'
if command -v systemctl >/dev/null 2>&1; then
  SERVICE_STATE="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)"
fi
if [[ "$SERVICE_STATE" == "active" ]]; then
  SVC_PID="$(systemctl show "$SERVICE_NAME" -p MainPID --value 2>/dev/null)"
  pass "Ollama service is running" "systemctl is-active = active, PID ${SVC_PID:-unknown}"
elif pgrep -x ollama >/dev/null 2>&1; then
  warn "Ollama running outside systemd" "Process is alive but systemctl reports '${SERVICE_STATE}'. It will not restart after a reboot."
else
  crit "Ollama service is NOT running" "systemctl is-active = ${SERVICE_STATE}. Staff cannot access the AI service."
fi
out ""

# ============================================================
# CHECK 2 - NETWORK EXPOSURE (0.0.0.0 DETECTION)
# ============================================================
out "CHECK 2: NETWORK EXPOSURE"
out "------------------------------------------------------------"
LISTEN_LINES=''
if command -v ss >/dev/null 2>&1; then
  LISTEN_LINES="$(ss -tuln 2>/dev/null | grep ":${PORT}\b")"
elif command -v netstat >/dev/null 2>&1; then
  LISTEN_LINES="$(netstat -tuln 2>/dev/null | grep ":${PORT}\b")"
fi

if [[ -z "$LISTEN_LINES" ]]; then
  crit "Nothing is listening on port ${PORT}" "Cannot verify the bind address because no socket is open."
else
  EXPOSED=0
  LOOPBACK=0
  ADDR_LIST=''
  while IFS= read -r sockline; do
    [[ -z "$sockline" ]] && continue
    ADDR="$(awk '{print $5}' <<< "$sockline")"
    [[ -z "$ADDR" ]] && ADDR="$(awk '{print $4}' <<< "$sockline")"
    ADDR_LIST="${ADDR_LIST}${ADDR} "
    case "$ADDR" in
      127.0.0.1:*|\[::1\]:*)          LOOPBACK=1 ;;
      0.0.0.0:*|*\*:*|\[::\]:*|:::*)  EXPOSED=1 ;;
      *)                              EXPOSED=1 ;;
    esac
  done <<< "$LISTEN_LINES"

  if [[ $EXPOSED -eq 1 ]]; then
    crit "API IS EXPOSED TO THE NETWORK" "Listening on ${ADDR_LIST}instead of 127.0.0.1. Ollama has NO authentication. Any host that can reach this port can run inference, pull models, and DELETE models. Set OLLAMA_HOST=127.0.0.1:${PORT} in the systemd override and restart immediately."
  elif [[ $LOOPBACK -eq 1 ]]; then
    pass "API bound to loopback only" "Listening on ${ADDR_LIST}- not reachable from the network. Staff access is through the authenticating reverse proxy."
  else
    warn "Bind address could not be classified" "Raw socket data: ${ADDR_LIST}"
  fi
fi

# Confirm the firewall backstop is in place
if command -v ufw >/dev/null 2>&1; then
  UFW_STATE="$($SUDO ufw status 2>/dev/null | head -1)"
  if grep -qi 'active' <<< "$UFW_STATE"; then
    pass "UFW firewall is active" "Second layer of protection behind the loopback binding."
  else
    warn "UFW firewall is not active" "The bind address is the only thing preventing network access. Enable UFW with the district ruleset."
  fi
fi
out ""

# ============================================================
# CHECK 3 - API RESPONDING
# ============================================================
out "CHECK 3: API RESPONSE"
out "------------------------------------------------------------"
API_URL="http://localhost:${PORT}/api/tags"
API_BODY=''
API_RC=127
if command -v curl >/dev/null 2>&1; then
  API_BODY="$(curl -s --max-time 5 "$API_URL" 2>/dev/null)"
  API_RC=$?
fi
if [[ $API_RC -eq 127 ]]; then
  warn "Cannot test the API" "curl is not installed."
elif [[ $API_RC -ne 0 || -z "$API_BODY" ]]; then
  crit "API is not responding" "curl to ${API_URL} failed with exit ${API_RC}. The process may be alive but hung."
elif grep -q '"models"' <<< "$API_BODY"; then
  pass "API is responding" "${API_URL} returned a valid model list."
else
  warn "API returned an unexpected payload" "Response had no 'models' key."
fi
out ""

# ============================================================
# CHECK 4 - UNAUTHORIZED MODEL DETECTION
# ============================================================
out "CHECK 4: MODEL GOVERNANCE"
out "------------------------------------------------------------"

# Build the installed list from the CLI, falling back to the API
INSTALLED=''
if command -v ollama >/dev/null 2>&1; then
  INSTALLED="$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -v '^$')"
fi
if [[ -z "$INSTALLED" && -n "$API_BODY" ]]; then
  INSTALLED="$(grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]*"' <<< "$API_BODY" | awk -F'"' '{print $(NF-1)}')"
fi

is_approved() {
  local candidate="$1" approved
  for approved in "${APPROVED_MODELS[@]}"; do
    [[ "$candidate" == "$approved" ]] && return 0
    # Ollama reports 'name' and 'name:latest' interchangeably
    [[ "${candidate%:latest}" == "${approved%:latest}" ]] && return 0
  done
  return 1
}

if [[ -z "$INSTALLED" ]]; then
  warn "Could not enumerate installed models" "Neither the ollama CLI nor the API returned a model list. Governance cannot be verified."
else
  INSTALLED_COUNT="$(grep -c . <<< "$INSTALLED")"
  UNAUTHORIZED=''
  AUTHORIZED=''
  while IFS= read -r model; do
    [[ -z "$model" ]] && continue
    if is_approved "$model"; then
      AUTHORIZED="${AUTHORIZED}${model} "
    else
      UNAUTHORIZED="${UNAUTHORIZED}${model} "
    fi
  done <<< "$INSTALLED"

  out "Installed models : ${INSTALLED_COUNT}"
  out "Approved list    : ${APPROVED_MODELS[*]}"
  out ""

  if [[ -n "$UNAUTHORIZED" ]]; then
    UNAUTH_COUNT="$(wc -w <<< "$UNAUTHORIZED" | tr -d ' ')"
    crit "${UNAUTH_COUNT} UNAUTHORIZED MODEL(S) INSTALLED" "Not on the approved list: ${UNAUTHORIZED}- this violates the SVUSD AI Model Governance Policy. Only the IT administrator may pull models. Investigate how this was installed, then remove with: ollama rm <model>"
    for m in $UNAUTHORIZED; do
      out "    UNAUTHORIZED -> ${m}"
    done
  else
    pass "All installed models are approved" "${INSTALLED_COUNT} model(s), all on the governance list."
  fi

  # Approved models that are missing are worth knowing about too
  MISSING=''
  for approved in "${APPROVED_MODELS[@]}"; do
    if ! grep -qx -- "$approved" <<< "$INSTALLED" && ! grep -qx -- "${approved%:latest}" <<< "$INSTALLED"; then
      MISSING="${MISSING}${approved} "
    fi
  done
  if [[ -n "$MISSING" ]]; then
    out ""
    out "    Note: approved but not installed: ${MISSING}"
  fi
fi
out ""

# ============================================================
# CHECK 5 - MODEL DISK USAGE
# ============================================================
out "CHECK 5: MODEL DISK USAGE"
out "------------------------------------------------------------"
resolve_models_dir() {
  if [[ -n "${OLLAMA_MODELS:-}" ]] && dir_exists "${OLLAMA_MODELS}"; then
    printf '%s\n' "${OLLAMA_MODELS}"; return
  fi
  local pid owner userhome candidate
  pid="$(pgrep -x ollama 2>/dev/null | head -1)"
  if [[ -n "$pid" ]]; then
    owner="$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')"
    if [[ -n "$owner" ]]; then
      userhome="$(getent passwd "$owner" 2>/dev/null | cut -d: -f6)"
      if [[ -n "$userhome" ]] && dir_exists "${userhome}/.ollama/models"; then
        printf '%s\n' "${userhome}/.ollama/models"; return
      fi
    fi
  fi
  for candidate in "$HOME/.ollama/models" /usr/share/ollama/.ollama/models /var/lib/ollama/.ollama/models; do
    dir_exists "$candidate" && { printf '%s\n' "$candidate"; return; }
  done
  printf '%s\n' "$HOME/.ollama/models"
}
MODELS_DIR="$(resolve_models_dir)"

if ! dir_exists "$MODELS_DIR"; then
  warn "Model directory not found" "Checked \$OLLAMA_MODELS, the service owner's home, and standard paths. Last tried: ${MODELS_DIR}"
else
  MODELS_SIZE="$(du -sh "$MODELS_DIR" 2>/dev/null | cut -f1)"
  [[ -z "$MODELS_SIZE" && -n "$SUDO" ]] && MODELS_SIZE="$($SUDO du -sh "$MODELS_DIR" 2>/dev/null | cut -f1)"
  DF_LINE="$(df -hP "$MODELS_DIR" 2>/dev/null | tail -1)"
  if [[ -z "$DF_LINE" ]]; then
    warn "Could not read partition usage" "df returned nothing for ${MODELS_DIR}"
  else
    PCT="$(awk '{gsub(/%/,"",$5); print $5}' <<< "$DF_LINE")"
    AVAIL="$(awk '{print $4}' <<< "$DF_LINE")"
    DETAIL="${MODELS_DIR} using ${MODELS_SIZE:-unknown}, partition ${PCT}% full, ${AVAIL} free"
    if [[ ! "$PCT" =~ ^[0-9]+$ ]]; then
      warn "Could not parse disk usage" "$DETAIL"
    elif [[ "$PCT" -ge "$DISK_CRITICAL" ]]; then
      crit "Partition is ${PCT}% full" "$DETAIL. Free space now or the service will fail."
    elif [[ "$PCT" -gt "$DISK_THRESHOLD" ]]; then
      warn "Partition is ${PCT}% full" "$DETAIL. Threshold is ${DISK_THRESHOLD}%."
    else
      pass "Disk usage is ${PCT}%" "$DETAIL"
    fi
  fi
fi
out ""

# ============================================================
# CHECK 6 - JOURNAL ERRORS
# ============================================================
out "CHECK 6: JOURNAL ERRORS (LAST HOUR)"
out "------------------------------------------------------------"
if ! command -v journalctl >/dev/null 2>&1; then
  warn "Cannot check the journal" "journalctl is not available."
else
  JOURNAL_RAW="$($SUDO journalctl -u "$SERVICE_NAME" --since '1 hour ago' --no-pager -q 2>/dev/null)"
  if [[ -z "$JOURNAL_RAW" ]]; then
    pass "No journal entries in the last hour" "Service has been quiet, or the journal is not readable by this user."
  else
    ERROR_LINES="$(grep -iE 'error|fatal|panic' <<< "$JOURNAL_RAW")"
    if [[ -z "$ERROR_LINES" ]]; then
      pass "No errors in the last hour" "Scanned $(grep -c . <<< "$JOURNAL_RAW") journal line(s)."
    else
      warn "$(grep -c . <<< "$ERROR_LINES") error entr(ies) in the last hour" "Most recent: $(tail -1 <<< "$ERROR_LINES" | cut -c1-140)"
    fi
  fi
fi
out ""

# ============================================================
# VERDICT
# ============================================================
TOTAL=$((PASS_COUNT + WARNING_COUNT + CRITICAL_COUNT))
out "============================================================"
out "SUMMARY"
out "------------------------------------------------------------"
out "Checks passed   : ${PASS_COUNT} of ${TOTAL}"
out "Warnings        : ${WARNING_COUNT}"
out "Critical issues : ${CRITICAL_COUNT}"
out ""

if [[ $CRITICAL_COUNT -gt 0 ]]; then
  VERDICT='CRITICAL'; VCOLOR="$RED"; EXIT_CODE=2
  VNOTE='Service is down, unreachable, exposed to the network, or running unauthorized models.'
elif [[ $WARNING_COUNT -gt 0 ]]; then
  VERDICT='WARNING'; VCOLOR="$YELLOW"; EXIT_CODE=1
  VNOTE='Service is functioning but issues were found that need attention.'
else
  VERDICT='HEALTHY'; VCOLOR="$GREEN"; EXIT_CODE=0
  VNOTE='All checks passed. Service is running, private, responding, and compliant.'
fi

REPORT+=("OVERALL STATUS: ${VERDICT}")
REPORT+=("${VNOTE}")
[[ $QUIET -eq 0 ]] && printf '%s\n%s\n%s\n' "${VCOLOR}${BOLD}OVERALL STATUS: ${VERDICT}${RESET}" "$VNOTE" "============================================================"

# ============================================================
# ALERTING
# ============================================================
if [[ ${#ALERTS[@]} -gt 0 ]]; then
  ALERT_BODY="SVUSD Ollama Monitor - ${VERDICT} on $(hostname) at $(date '+%Y-%m-%d %H:%M:%S')"
  for a in "${ALERTS[@]}"; do
    ALERT_BODY="${ALERT_BODY}"$'\n'"  - ${a}"
  done

  # 1. syslog, always
  if command -v logger >/dev/null 2>&1; then
    PRIORITY='user.warning'
    [[ $CRITICAL_COUNT -gt 0 ]] && PRIORITY='user.crit'
    while IFS= read -r line; do
      logger -t "$SYSLOG_TAG" -p "$PRIORITY" -- "$line" 2>/dev/null
    done <<< "$ALERT_BODY"
  fi

  # 2. email, if configured
  if [[ -n "$ALERT_EMAIL" ]] && command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$ALERT_BODY" | mail -s "[${VERDICT}] SVUSD AI Server - $(hostname)" "$ALERT_EMAIL"
    say "Alert emailed to ${ALERT_EMAIL}"
  fi

  # 3. webhook, if configured
  if [[ -n "$ALERT_WEBHOOK" ]] && command -v curl >/dev/null 2>&1; then
    JSON_TEXT="$(printf '%s' "$ALERT_BODY" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}')"
    curl -s -X POST -H 'Content-Type: application/json' \
      -d "{\"text\":\"${JSON_TEXT}\"}" "$ALERT_WEBHOOK" >/dev/null 2>&1
    say "Alert posted to webhook."
  fi
fi

exit $EXIT_CODE
