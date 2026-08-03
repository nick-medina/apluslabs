#!/usr/bin/env bash
# ============================================================
# sysinfo.sh - Script 1: System Info Summary
# Author: Nick Medina
#
# Reports:
#   1. Hostname, IP address, OS version, kernel, uptime
#   2. Disk usage for every mounted filesystem, flagging any
#      filesystem above 80% used
#   3. Memory totals and CPU model
#
# Output: ~/sysinfo_[date].txt
#
# Usage:  chmod +x sysinfo.sh
#         ./sysinfo.sh
# ============================================================

set -uo pipefail

DISK_THRESHOLD=80
OUTFILE="${HOME}/sysinfo_$(date +%F).txt"

# ------------------------------------------------ Output helpers
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

REPORT=()
FLAGS=0

# Plain line: goes to both the report file and the screen
out() { REPORT+=("$1"); printf '%s\n' "$1"; }

# Section header: plain in the file, cyan on screen
hdr() { REPORT+=("$1"); printf '%s\n' "${CYAN}${BOLD}${1}${RESET}"; }

# Flagged line: plain in the file, red on screen, increments counter
flag() { REPORT+=("  [FLAG] $1"); printf '  %s\n' "${RED}[FLAG]${RESET} $1"; FLAGS=$((FLAGS + 1)); }

# Passing line: plain in the file, green on screen
pass() { REPORT+=("  [ OK ] $1"); printf '  %s\n' "${GREEN}[ OK ]${RESET} $1"; }

# ============================================================
# HEADER
# ============================================================
out "============================================================"
out "                  SYSTEM INFO SUMMARY"
out "============================================================"
out "Generated : $(date '+%Y-%m-%d %H:%M:%S %Z')"
out "Report by : $(whoami)"
out "============================================================"
out ""

# ============================================================
# 1. SYSTEM IDENTIFICATION
# ============================================================
hdr "[1] SYSTEM IDENTIFICATION"
out "------------------------------------------------------------"

# --- Hostname
HOSTNAME_SHORT="$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null)"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null)"
out "Hostname      : ${HOSTNAME_SHORT:-unknown}"
if [[ -n "$HOSTNAME_FQDN" && "$HOSTNAME_FQDN" != "$HOSTNAME_SHORT" ]]; then
    out "FQDN          : ${HOSTNAME_FQDN}"
fi

# --- IP addresses (all non-loopback IPv4)
IP_LIST=''
if command -v hostname >/dev/null 2>&1 && hostname -I >/dev/null 2>&1; then
    IP_LIST="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | grep -v '^127\.')"
fi
if [[ -z "$IP_LIST" ]] && command -v ip >/dev/null 2>&1; then
    IP_LIST="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
fi
if [[ -z "$IP_LIST" ]] && command -v ifconfig >/dev/null 2>&1; then
    IP_LIST="$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.')"
fi

if [[ -n "$IP_LIST" ]]; then
    FIRST_IP=1
    while IFS= read -r addr; do
        [[ -z "$addr" ]] && continue
        if [[ $FIRST_IP -eq 1 ]]; then
            out "IP Address    : ${addr}"
            FIRST_IP=0
        else
            out "                ${addr}"
        fi
    done <<< "$IP_LIST"
else
    out "IP Address    : none detected (no non-loopback IPv4)"
fi

# --- Default gateway and primary interface
if command -v ip >/dev/null 2>&1; then
    GW="$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')"
    IFACE="$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')"
    [[ -n "$GW" ]] && out "Gateway       : ${GW}"
    [[ -n "$IFACE" ]] && out "Interface     : ${IFACE}"
fi

# --- OS version
OS_NAME=''
if [[ -r /etc/os-release ]]; then
    OS_NAME="$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release)"
fi
if [[ -z "$OS_NAME" ]] && command -v lsb_release >/dev/null 2>&1; then
    OS_NAME="$(lsb_release -ds 2>/dev/null | tr -d '"')"
fi
[[ -z "$OS_NAME" ]] && OS_NAME="$(uname -o 2>/dev/null)"
out "OS Version    : ${OS_NAME:-unknown}"

# --- Kernel and architecture
out "Kernel        : $(uname -r 2>/dev/null)"
out "Architecture  : $(uname -m 2>/dev/null)"

# --- Uptime and boot time
UPTIME_PRETTY="$(uptime -p 2>/dev/null)"
if [[ -z "$UPTIME_PRETTY" && -r /proc/uptime ]]; then
    UP_SECS="$(cut -d. -f1 /proc/uptime)"
    UPTIME_PRETTY="up $((UP_SECS / 86400))d $(((UP_SECS % 86400) / 3600))h $(((UP_SECS % 3600) / 60))m"
fi
out "Uptime        : ${UPTIME_PRETTY:-unknown}"

BOOT_TIME="$(uptime -s 2>/dev/null)"
[[ -z "$BOOT_TIME" ]] && BOOT_TIME="$(who -b 2>/dev/null | awk '{print $3, $4}')"
[[ -n "$BOOT_TIME" ]] && out "Booted At     : ${BOOT_TIME}"

# --- Logged in users
USER_COUNT="$(who 2>/dev/null | wc -l | tr -d ' ')"
out "Users Online  : ${USER_COUNT:-0}"
out ""

# ============================================================
# 2. DISK USAGE
# ============================================================
hdr "[2] DISK USAGE (flagging above ${DISK_THRESHOLD}%)"
out "------------------------------------------------------------"

# -P forces POSIX single-line output so awk column positions stay stable.
# Pseudo-filesystems are excluded because their usage is meaningless here.
DF_OUT="$(df -hP -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | tail -n +2)"
if [[ -z "$DF_OUT" ]]; then
    DF_OUT="$(df -hP 2>/dev/null | tail -n +2)"
fi

if [[ -z "$DF_OUT" ]]; then
    out "Could not read filesystem information."
else
    out "$(printf '%-24s %8s %8s %8s %6s  %s' 'FILESYSTEM' 'SIZE' 'USED' 'AVAIL' 'USE%' 'MOUNTED ON')"

    # A bind-mounted filesystem appears once per mountpoint but is the same
    # physical device. Report each device once so one full disk does not
    # produce five identical flags.
    SEEN_DEVICES=''
    DUPES=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        FS="$(awk '{print $1}' <<< "$line")"
        if [[ " ${SEEN_DEVICES} " == *" ${FS} "* ]]; then
            DUPES=$((DUPES + 1))
            continue
        fi
        SEEN_DEVICES="${SEEN_DEVICES} ${FS}"
        SIZE="$(awk '{print $2}' <<< "$line")"
        USED="$(awk '{print $3}' <<< "$line")"
        AVAIL="$(awk '{print $4}' <<< "$line")"
        PCT_RAW="$(awk '{print $5}' <<< "$line")"
        MOUNT="$(awk '{print $6}' <<< "$line")"
        PCT="${PCT_RAW%\%}"
        out "$(printf '%-24s %8s %8s %8s %6s  %s' "$FS" "$SIZE" "$USED" "$AVAIL" "$PCT_RAW" "$MOUNT")"
        if [[ "$PCT" =~ ^[0-9]+$ ]] && [[ "$PCT" -gt "$DISK_THRESHOLD" ]]; then
            flag "${MOUNT} is ${PCT}% full on ${FS} (only ${AVAIL} free)."
        fi
    done <<< "$DF_OUT"

    if [[ $DUPES -gt 0 ]]; then
        out ""
        out "(${DUPES} bind mount(s) hidden - same device already listed above.)"
    fi

    out ""
    if [[ $FLAGS -eq 0 ]]; then
        pass "All filesystems are at or below ${DISK_THRESHOLD}% used."
    fi

    # Largest inode consumers are a common silent failure; report if tight
    INODE_OUT="$(df -iP -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2 | awk -v t="$DISK_THRESHOLD" '{gsub(/%/,"",$5); if ($5+0 > t) print $6" is "$5"% of inodes used"}')"
    if [[ -n "$INODE_OUT" ]]; then
        out ""
        while IFS= read -r iline; do
            [[ -n "$iline" ]] && flag "INODES: ${iline}"
        done <<< "$INODE_OUT"
    fi
fi
out ""

# ============================================================
# 3. MEMORY AND CPU
# ============================================================
hdr "[3] MEMORY AND CPU"
out "------------------------------------------------------------"

# --- Memory
if [[ -r /proc/meminfo ]]; then
    MEM_TOTAL_KB="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
    MEM_AVAIL_KB="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
    MEM_FREE_KB="$(awk '/^MemFree:/{print $2}' /proc/meminfo)"
    SWAP_TOTAL_KB="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)"
    SWAP_FREE_KB="$(awk '/^SwapFree:/{print $2}' /proc/meminfo)"

    if [[ -n "$MEM_TOTAL_KB" && "$MEM_TOTAL_KB" -gt 0 ]]; then
        MEM_USED_KB=$((MEM_TOTAL_KB - MEM_AVAIL_KB))
        MEM_PCT=$((MEM_USED_KB * 100 / MEM_TOTAL_KB))
        out "Memory Total  : $(awk -v k="$MEM_TOTAL_KB" 'BEGIN{printf "%.2f GB", k/1048576}')"
        out "Memory Used   : $(awk -v k="$MEM_USED_KB" 'BEGIN{printf "%.2f GB", k/1048576}') (${MEM_PCT}%)"
        out "Memory Avail  : $(awk -v k="$MEM_AVAIL_KB" 'BEGIN{printf "%.2f GB", k/1048576}')"
        out "Memory Free   : $(awk -v k="$MEM_FREE_KB" 'BEGIN{printf "%.2f GB", k/1048576}')"
    fi

    if [[ -n "$SWAP_TOTAL_KB" && "$SWAP_TOTAL_KB" -gt 0 ]]; then
        SWAP_USED_KB=$((SWAP_TOTAL_KB - SWAP_FREE_KB))
        SWAP_PCT=$((SWAP_USED_KB * 100 / SWAP_TOTAL_KB))
        out "Swap Total    : $(awk -v k="$SWAP_TOTAL_KB" 'BEGIN{printf "%.2f GB", k/1048576}')"
        out "Swap Used     : $(awk -v k="$SWAP_USED_KB" 'BEGIN{printf "%.2f GB", k/1048576}') (${SWAP_PCT}%)"
    else
        out "Swap          : none configured"
    fi
else
    out "Memory        : /proc/meminfo unreadable"
fi
out ""

# --- CPU
CPU_MODEL=''
if command -v lscpu >/dev/null 2>&1; then
    CPU_MODEL="$(lscpu 2>/dev/null | awk -F: '/^Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
fi
if [[ -z "$CPU_MODEL" && -r /proc/cpuinfo ]]; then
    CPU_MODEL="$(awk -F: '/^model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo)"
fi
[[ -z "$CPU_MODEL" ]] && CPU_MODEL='unknown'

CPU_CORES="$(nproc 2>/dev/null)"
[[ -z "$CPU_CORES" && -r /proc/cpuinfo ]] && CPU_CORES="$(grep -c '^processor' /proc/cpuinfo)"

out "CPU Model     : ${CPU_MODEL}"
out "CPU Cores     : ${CPU_CORES:-unknown}"

if command -v lscpu >/dev/null 2>&1; then
    CPU_ARCH="$(lscpu 2>/dev/null | awk -F: '/^Architecture/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    CPU_MHZ="$(lscpu 2>/dev/null | awk -F: '/^CPU MHz|^CPU max MHz/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    CPU_VENDOR="$(lscpu 2>/dev/null | awk -F: '/^Vendor ID/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    [[ -n "$CPU_VENDOR" ]] && out "CPU Vendor    : ${CPU_VENDOR}"
    [[ -n "$CPU_ARCH" ]] && out "CPU Arch      : ${CPU_ARCH}"
    [[ -n "$CPU_MHZ" ]] && out "CPU Speed     : ${CPU_MHZ} MHz"
fi

if [[ -r /proc/loadavg ]]; then
    LOAD="$(cut -d' ' -f1-3 /proc/loadavg)"
    out "Load Average  : ${LOAD}  (1m, 5m, 15m)"
    if [[ -n "${CPU_CORES:-}" && "$CPU_CORES" =~ ^[0-9]+$ ]]; then
        LOAD1="$(cut -d' ' -f1 /proc/loadavg)"
        LOAD_PCT="$(awk -v l="$LOAD1" -v c="$CPU_CORES" 'BEGIN{printf "%.0f", (l/c)*100}')"
        out "Load per Core : ${LOAD_PCT}% of capacity"
    fi
fi
out ""

# ============================================================
# SUMMARY
# ============================================================
out "============================================================"
out "SUMMARY"
out "------------------------------------------------------------"
if [[ $FLAGS -eq 0 ]]; then
    out "No filesystems above ${DISK_THRESHOLD}%. Nothing flagged."
else
    out "${FLAGS} item(s) flagged. See [FLAG] entries above."
fi
out "============================================================"
out "End of report"
out "============================================================"

# ============================================================
# WRITE REPORT FILE
# ============================================================
if printf '%s\n' "${REPORT[@]}" > "$OUTFILE" 2>/dev/null; then
    printf '\n%s\n' "${GREEN}Report saved to: ${OUTFILE}${RESET}"
else
    printf '\n%s\n' "${RED}Failed to write report to ${OUTFILE}${RESET}"
    exit 2
fi

exit $(( FLAGS > 0 ? 1 : 0 ))
