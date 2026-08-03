#!/usr/bin/env bash
# ============================================================
# user-audit.sh - Script 3: User Audit
# Author: Nick Medina
#
#   1. Lists all users with a real login shell (excludes
#      /sbin/nologin, /usr/sbin/nologin, /bin/false, etc.)
#   2. Reports which of those users have sudo rights, via group
#      membership and via the sudoers files
#   3. Flags any account with UID 0 that is not root
#
# Output: ~/useraudit_[date].txt
#
# Usage:  chmod +x user-audit.sh
#         ./user-audit.sh
#
# Run with sudo for the complete picture - reading the sudoers
# files and password status requires root.
# ============================================================

set -uo pipefail

PASSWD_FILE="${PASSWD_FILE:-/etc/passwd}"
GROUP_FILE="${GROUP_FILE:-/etc/group}"
OUTFILE="${HOME}/useraudit_$(date +%F).txt"

# Groups that confer sudo rights, by distro:
#   sudo    - Debian, Ubuntu
#   wheel   - RHEL, Fedora, CentOS, Arch
#   admin   - older Ubuntu
SUDO_GROUPS='sudo wheel admin'

# ------------------------------------------------ Colours
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

REPORT=()
CRITICAL=0
WARNINGS=0

SUDO=''
if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
    SUDO='sudo'
fi

out()  { REPORT+=("$1"); printf '%s\n' "$1"; }
hdr()  { REPORT+=("$1"); printf '%s\n' "${CYAN}${BOLD}${1}${RESET}"; }
pass() { REPORT+=("  [ OK ] $1"); printf '  %s %s\n' "${GREEN}[ OK ]${RESET}" "$1"; }
warn() { REPORT+=("  [WARN] $1"); printf '  %s %s\n' "${YELLOW}[WARN]${RESET}" "$1"; WARNINGS=$((WARNINGS + 1)); }
crit() { REPORT+=("  [FLAG] $1"); printf '  %s %s\n' "${RED}[FLAG]${RESET}" "${BOLD}$1${RESET}"; CRITICAL=$((CRITICAL + 1)); }

# ============================================================
# HEADER
# ============================================================
out "============================================================"
out "                     USER AUDIT REPORT"
out "============================================================"
out "Host      : $(hostname)"
out "Run by    : $(whoami) (UID ${EUID})"
out "Generated : $(date '+%Y-%m-%d %H:%M:%S %Z')"
out "Source    : ${PASSWD_FILE}"
if [[ $EUID -ne 0 ]]; then
    out "NOTE      : not running as root - sudoers files and password"
    out "            status may be unreadable. Re-run with sudo for full detail."
fi
out "============================================================"
out ""

# ============================================================
# 1. USERS WITH LOGIN SHELLS
# ============================================================
hdr "[1] USERS WITH LOGIN SHELLS"
out "------------------------------------------------------------"

# A "login shell" is anything not in the deny list below. Matching on the
# deny list rather than on /etc/shells matters because an admin can set a
# shell that is absent from /etc/shells and still have a usable account.
is_login_shell() {
    case "$1" in
        */nologin|*/false|*/sync|*/halt|*/shutdown|/dev/null|'') return 1 ;;
        *) return 0 ;;
    esac
}

LOGIN_USERS=()
ALL_USERS=()

while IFS=: read -r uname _pw uid gid gecos home shell; do
    [[ -z "${uname:-}" ]] && continue
    [[ "$uname" == \#* ]] && continue
    ALL_USERS+=("${uname}:${uid}:${gid}:${shell}:${home}:${gecos}")
    if is_login_shell "$shell"; then
        LOGIN_USERS+=("${uname}:${uid}:${gid}:${shell}:${home}")
    fi
done < "$PASSWD_FILE"

out "$(printf '%-18s %7s %7s %-22s %s' 'USER' 'UID' 'GID' 'SHELL' 'HOME')"
out "$(printf '%-18s %7s %7s %-22s %s' '------------------' '-------' '-------' '----------------------' '----')"

for entry in "${LOGIN_USERS[@]}"; do
    IFS=: read -r u uid gid shell home <<< "$entry"
    out "$(printf '%-18s %7s %7s %-22s %s' "$u" "$uid" "$gid" "$shell" "$home")"
done

out ""
out "Accounts with a login shell : ${#LOGIN_USERS[@]}"
out "Accounts total              : ${#ALL_USERS[@]}"
out "Service accounts (no login) : $(( ${#ALL_USERS[@]} - ${#LOGIN_USERS[@]} ))"
out ""

# Regular (non-system) users are conventionally UID >= 1000
REGULAR_COUNT=0
for entry in "${LOGIN_USERS[@]}"; do
    IFS=: read -r u uid _rest <<< "$entry"
    if [[ "$uid" =~ ^[0-9]+$ ]] && [[ "$uid" -ge 1000 ]]; then
        REGULAR_COUNT=$((REGULAR_COUNT + 1))
    fi
done
out "Of those, regular users (UID >= 1000): ${REGULAR_COUNT}"
out ""

# ============================================================
# 2. SUDO RIGHTS
# ============================================================
hdr "[2] SUDO RIGHTS"
out "------------------------------------------------------------"

SUDOERS_USERS=''

# --- 2a. Membership in a sudo-conferring group
out "Group membership:"
FOUND_GROUP=0
# getent is preferred on a live system because it also resolves groups that
# come from LDAP or AD, not just /etc/group. But when GROUP_FILE has been
# pointed somewhere else, that explicit choice wins.
get_group_line() {
    local g="$1" line=''
    if [[ "$GROUP_FILE" != "/etc/group" ]]; then
        grep "^${g}:" "$GROUP_FILE" 2>/dev/null
        return
    fi
    line="$(getent group "$g" 2>/dev/null)"
    [[ -z "$line" ]] && line="$(grep "^${g}:" "$GROUP_FILE" 2>/dev/null)"
    printf '%s\n' "$line"
}

for grp in $SUDO_GROUPS; do
    GRP_LINE="$(get_group_line "$grp")"
    [[ -z "$GRP_LINE" ]] && continue
    FOUND_GROUP=1
    MEMBERS="$(cut -d: -f4 <<< "$GRP_LINE")"
    GRP_GID="$(cut -d: -f3 <<< "$GRP_LINE")"

    if [[ -z "$MEMBERS" ]]; then
        out "  ${grp} (gid ${GRP_GID}) : no members"
    else
        out "  ${grp} (gid ${GRP_GID}) : ${MEMBERS}"
        SUDOERS_USERS="${SUDOERS_USERS} $(tr ',' ' ' <<< "$MEMBERS")"
    fi

    # Users whose PRIMARY group is the sudo group do not appear in the
    # member list at all, so check the passwd GIDs too.
    for entry in "${ALL_USERS[@]}"; do
        IFS=: read -r u _uid gid _rest <<< "$entry"
        if [[ "$gid" == "$GRP_GID" ]]; then
            out "  ${grp} (primary group of ${u})"
            SUDOERS_USERS="${SUDOERS_USERS} ${u}"
        fi
    done
done
[[ $FOUND_GROUP -eq 0 ]] && out "  No sudo/wheel/admin group exists on this system."
out ""

# --- 2b. Direct entries in the sudoers files
out "Sudoers file entries:"
SUDOERS_READABLE=0
SUDOERS_RAW=''

if [[ -r /etc/sudoers ]]; then
    SUDOERS_RAW="$(cat /etc/sudoers 2>/dev/null)"
    SUDOERS_READABLE=1
elif [[ -n "$SUDO" ]]; then
    SUDOERS_RAW="$($SUDO cat /etc/sudoers 2>/dev/null)"
    [[ -n "$SUDOERS_RAW" ]] && SUDOERS_READABLE=1
fi

if [[ -d /etc/sudoers.d ]]; then
    EXTRA="$(cat /etc/sudoers.d/* 2>/dev/null)"
    [[ -z "$EXTRA" && -n "$SUDO" ]] && EXTRA="$($SUDO cat /etc/sudoers.d/* 2>/dev/null)"
    if [[ -n "$EXTRA" ]]; then
        SUDOERS_RAW="${SUDOERS_RAW}"$'\n'"${EXTRA}"
        SUDOERS_READABLE=1
    fi
fi

if [[ $SUDOERS_READABLE -eq 0 ]]; then
    warn "Could not read /etc/sudoers - re-run with sudo for complete results."
else
    # Strip comments and blank lines, keep privilege specification lines
    SUDO_RULES="$(grep -vE '^\s*#|^\s*$' <<< "$SUDOERS_RAW" | grep -E 'ALL\s*=|NOPASSWD')"
    if [[ -z "$SUDO_RULES" ]]; then
        out "  No explicit user rules found."
    else
        while IFS= read -r rule; do
            [[ -z "$rule" ]] && continue
            out "  ${rule}"
            PRINCIPAL="$(awk '{print $1}' <<< "$rule")"
            case "$PRINCIPAL" in
                %*|Defaults|Cmnd_Alias|User_Alias|Host_Alias|Runas_Alias) ;;
                *) SUDOERS_USERS="${SUDOERS_USERS} ${PRINCIPAL}" ;;
            esac
        done <<< "$SUDO_RULES"

        NOPASSWD_RULES="$(grep -i 'NOPASSWD' <<< "$SUDO_RULES")"
        if [[ -n "$NOPASSWD_RULES" ]]; then
            out ""
            while IFS= read -r nrule; do
                [[ -z "$nrule" ]] && continue
                warn "NOPASSWD rule: ${nrule}"
            done <<< "$NOPASSWD_RULES"
            out "         A NOPASSWD rule lets that principal run commands as root with"
            out "         no password prompt. Anyone who gets a shell as that user is root."
        fi
    fi
fi
out ""

# --- 2c. Consolidated list
out "Users with sudo rights (deduplicated):"
SUDO_LIST="$(tr ' ' '\n' <<< "$SUDOERS_USERS" | grep -v '^$' | sort -u)"

if [[ -z "$SUDO_LIST" ]]; then
    out "  None detected."
else
    while IFS= read -r su; do
        [[ -z "$su" ]] && continue
        USER_SHELL="$(awk -F: -v n="$su" '$1==n{print $7}' "$PASSWD_FILE")"
        USER_UID="$(awk -F: -v n="$su" '$1==n{print $3}' "$PASSWD_FILE")"
        if [[ -z "$USER_UID" ]]; then
            out "  ${su} (not a local user - may be a group or alias)"
        elif is_login_shell "$USER_SHELL"; then
            out "  ${su} (UID ${USER_UID}, shell ${USER_SHELL})"
        else
            out "  ${su} (UID ${USER_UID}, shell ${USER_SHELL}) - has sudo but cannot log in"
        fi
    done <<< "$SUDO_LIST"
fi
out ""

# ============================================================
# 3. UID 0 CHECK
# ============================================================
hdr "[3] UID 0 ACCOUNTS"
out "------------------------------------------------------------"

# Deliberately scans EVERY account, not just those with login shells.
# A UID 0 account with /sbin/nologin is still uid 0 to the kernel and can
# be reached through su, cron, or any service that runs as that name.
UID0_LIST=()
for entry in "${ALL_USERS[@]}"; do
    IFS=: read -r u uid _gid shell _home <<< "$entry"
    [[ "$uid" == "0" ]] && UID0_LIST+=("${u}:${shell}")
done

out "Accounts with UID 0: ${#UID0_LIST[@]}"
out ""
for item in "${UID0_LIST[@]}"; do
    IFS=: read -r u shell <<< "$item"
    if [[ "$u" == "root" ]]; then
        pass "root (UID 0, shell ${shell}) - expected"
    else
        crit "${u} has UID 0 - a second root account, shell ${shell}"
    fi
done

if [[ ${#UID0_LIST[@]} -eq 1 ]]; then
    out ""
    pass "Only root holds UID 0."
elif [[ ${#UID0_LIST[@]} -gt 1 ]]; then
    out ""
    out "  Any account with UID 0 IS root as far as the kernel is concerned."
    out "  The username is cosmetic - file ownership, permission checks, and"
    out "  capabilities all key off the numeric UID. A second UID 0 account is"
    out "  a classic persistence backdoor because it survives password changes"
    out "  to the real root account and is easy to miss in a user list."
fi

# --- Duplicate UIDs generally
DUP_UIDS="$(cut -d: -f3 "$PASSWD_FILE" | sort | uniq -d)"
if [[ -n "$DUP_UIDS" ]]; then
    out ""
    while IFS= read -r duid; do
        [[ -z "$duid" ]] && continue
        DUP_NAMES="$(awk -F: -v n="$duid" '$3==n{printf "%s ", $1}' "$PASSWD_FILE")"
        if [[ "$duid" == "0" ]]; then
            continue   # already reported above
        fi
        warn "UID ${duid} is shared by: ${DUP_NAMES}"
    done <<< "$DUP_UIDS"
fi

# --- Accounts with an empty password field in /etc/passwd
EMPTY_PW="$(awk -F: '$2==""{print $1}' "$PASSWD_FILE")"
if [[ -n "$EMPTY_PW" ]]; then
    out ""
    while IFS= read -r epw; do
        [[ -z "$epw" ]] && continue
        crit "${epw} has an empty password field in ${PASSWD_FILE}"
    done <<< "$EMPTY_PW"
fi
out ""

# ============================================================
# SUMMARY
# ============================================================
SUDO_COUNT="$(grep -c . <<< "$SUDO_LIST" 2>/dev/null)"
[[ -z "$SUDO_LIST" ]] && SUDO_COUNT=0

out "============================================================"
out "SUMMARY"
out "------------------------------------------------------------"
out "Users with login shells : ${#LOGIN_USERS[@]}"
out "Regular users (UID>=1000): ${REGULAR_COUNT}"
out "Users with sudo rights  : ${SUDO_COUNT}"
out "UID 0 accounts          : ${#UID0_LIST[@]}"
out "Flags raised            : ${CRITICAL}"
out "Warnings                : ${WARNINGS}"
out ""

if [[ $CRITICAL -gt 0 ]]; then
    printf '%s\n' "${RED}${BOLD}RESULT: ${CRITICAL} critical finding(s). Investigate immediately.${RESET}"
    REPORT+=("RESULT: ${CRITICAL} critical finding(s). Investigate immediately.")
    EXIT_CODE=2
elif [[ $WARNINGS -gt 0 ]]; then
    printf '%s\n' "${YELLOW}${BOLD}RESULT: ${WARNINGS} warning(s). Review recommended.${RESET}"
    REPORT+=("RESULT: ${WARNINGS} warning(s). Review recommended.")
    EXIT_CODE=1
else
    printf '%s\n' "${GREEN}${BOLD}RESULT: No issues found.${RESET}"
    REPORT+=("RESULT: No issues found.")
    EXIT_CODE=0
fi
out "============================================================"

# ============================================================
# SAVE REPORT
# ============================================================
if printf '%s\n' "${REPORT[@]}" > "$OUTFILE" 2>/dev/null; then
    printf '\n%s\n' "${CYAN}Report saved to: ${OUTFILE}${RESET}"
else
    printf '\n%s\n' "${RED}Could not write report to ${OUTFILE}${RESET}"
fi

exit $EXIT_CODE
