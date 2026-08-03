# IT100 Systems Administration Scripts

**Course:** IT100 
**Semester:** Summer 2026
**Author:** Nick Medina

A collection of PowerShell and Bash automation scripts written for IT100, covering Windows
administration, Linux administration, and local AI infrastructure management. Every script was
written, executed, and validated against live systems - a Windows Server domain controller
(`WINDOWSBOX`, domain `sierralab.local`) and an Ubuntu host (`linuxbox`) running Ollama.

All scripts share a common design: run checks, print clear status per item, aggregate warnings,
write a timestamped report to disk, and exit with a meaningful status code so they can be
scheduled without a wrapper.

---

## Windows Scripts

### `Script1-SystemHealthCheck.ps1`
System health snapshot with configurable thresholds.

- Disk space on all fixed drives — warns below 20% free
- CPU load sampled once per second for 30 seconds, warns if the average exceeds 80%
- Physical memory — warns below 500 MB free
- Top 5 processes by CPU time
- Writes to `C:\Temp\healthcheck_[date].txt`

Filters to `DriveType=3` so mapped network drives and removable media don't skew results.
Reports peak and minimum CPU alongside the average, because a 79% average can hide a 100% spike.

### `Script2-UserAccountReport.ps1`
Local account audit exported to CSV.

- Every local user with name, enabled status, last logon, and Administrators membership
- Flags accounts that are **enabled but have never logged in**
- Escalates to `HIGH RISK` when a flagged account is also an administrator
- Writes to `C:\Temp\useraccounts_[date].csv`

Administrators membership is matched by **SID rather than username**, which survives account
renames and correctly handles `DOMAIN\user` entries. The script detects machine role first and
falls through three lookup methods — `Get-LocalGroupMember`, `Get-ADGroupMember -Recursive`,
then the ADSI `WinNT://` provider — because domain controllers have no local groups at all.

### `Script3-EventLogParser.ps1`
Security-focused event log summary for the previous 24 hours.

- System log Error events (Level 2), grouped by source and event ID
- Security log Event ID 4625 (failed logon), grouped by target account and by source IP
- Decodes logon types to plain English (type 3 = network/SMB, type 10 = RDP)
- Writes both sections to `C:\Temp\eventlog_report_[date].txt`

Failed-logon details are pulled from each event's XML by **field name** rather than by array
index, so the parser doesn't silently break if Microsoft reorders the `EventData` block.
Grouping is the actual analysis: 200 failures across 200 accounts is a scanner, 200 against one
account is a brute-force attempt.

---

## Linux Scripts

### `sysinfo.sh`
System information summary.

- Hostname, FQDN, all non-loopback IPv4 addresses, gateway, and primary interface
- OS version, kernel, architecture, uptime, and boot time
- Disk usage for every mounted filesystem — flags anything above 80%
- Memory totals and CPU model, cores, and load average
- Writes to `~/sysinfo_[date].txt`

Memory "used" is derived from `MemAvailable`, not `MemFree` — Linux deliberately fills unused
RAM with disk cache, so `MemFree` makes a healthy server look starved. Deduplicates bind mounts
so one full device produces one warning instead of five. Also checks inode exhaustion, which
causes "no space left on device" errors at 30% disk usage and never shows up in `df -h`.

### `ollama-health.sh`
Six-point health and security check for a local Ollama install, with a `HEALTHY` /
`WARNING` / `CRITICAL` verdict.

| # | Check | Failure severity |
|---|-------|------------------|
| 1 | Service running (`systemctl is-active ollama`) | CRITICAL |
| 2 | Bound to `127.0.0.1`, not `0.0.0.0` | CRITICAL |
| 3 | API responding (`/api/tags`) | CRITICAL |
| 4 | Number of models installed | WARNING if zero |
| 5 | Model disk usage below 80% of partition | WARNING (CRITICAL at 95%) |
| 6 | ERROR entries in the journal in the last hour | WARNING |

Exit codes follow the Nagios convention — `0` healthy, `1` warning, `2` critical — so the script
drops directly into cron or a monitoring agent.

**Why an exposed bind address is rated CRITICAL:** Ollama ships with no authentication of any
kind. A service bound to `0.0.0.0` is fully functional, so a naive check passes it — but anyone
who can reach that port can run inference on your hardware, pull arbitrary models, and delete
existing ones. A working-but-exposed service is more dangerous than a stopped one, so it carries
the same severity as an outage.

The script resolves the model directory from the **service account's** home rather than the
invoking user's, because Ollama installed via systemd runs as its own `ollama` user with models
under `/usr/share/ollama/.ollama/models`. Permission-denied directory tests are retried through
sudo so "I can't see it" is never reported as "it doesn't exist."

### `user-audit.sh`
Local account and privilege audit.

- Lists all users with a real login shell, excluding `nologin`, `false`, `sync`, `halt`
- Reports sudo rights from three sources: `sudo`/`wheel`/`admin` group membership, users whose
  *primary* GID is one of those groups, and direct entries in `/etc/sudoers` and `/etc/sudoers.d/`
- Flags `NOPASSWD` rules separately
- **Flags any account with UID 0 other than root**
- Bonus checks: duplicate UIDs, empty password fields
- Writes to `~/useraudit_[date].txt`

The UID 0 scan deliberately covers **every** account, including those with `nologin` shells. UID 0
is UID 0 to the kernel regardless of shell — such an account is still reachable through `su`,
cron, or any service configured to run under that name. A scan limited to login-shell users would
miss a `toor:x:0:0:...:/sbin/nologin` backdoor entirely. Login shells are matched against a
deny-list rather than `/etc/shells`, since a valid shell absent from that file would otherwise
produce a false negative.

---

## AI Infrastructure Skills

Working on this project, I learned to operate and secure a local LLM deployment:

- **Service lifecycle management** — verify Ollama's state with `systemctl is-active`, distinguish
  a systemd-managed service from a manual `ollama serve` that won't survive a reboot, and restart
  it safely
- **Network exposure auditing** — inspect the actual listening socket with `ss -tuln` rather than
  trusting the `OLLAMA_HOST` variable, and explain why an unauthenticated inference endpoint on
  `0.0.0.0` is a serious exposure
- **API health validation** — query `/api/tags` to confirm the service is genuinely responding, not
  just that a process exists; a hung process still shows up in `pgrep`
- **Model inventory and storage management** — enumerate installed models via CLI and API, locate
  the real model directory under the service account's home, measure consumption, and reclaim
  space with `ollama rm`
- **Log analysis** — pull service-scoped logs with `journalctl -u ollama --since` and filter for
  error conditions
- **Service account awareness** — understand that a daemon's files live in *its* home directory,
  not the administrator's, and that permission-denied is not the same as not-found
- **Monitoring integration** — express health as Nagios-style exit codes so checks compose with
  existing tooling

---

## Certifications Pursuing

**Next up: CompTIA Security+ (SY0-701)**

I'm going directly to Security+ after A+ rather than routing through Network+. Security+ is the
DoD 8570 IAT Level II baseline, which gates a large share of government and contractor roles, and
it's the most frequently requested certification in entry-level security job postings. The
networking fundamentals Network+ covers are prerequisites I'm filling in through coursework and
hands-on lab work instead of a separate exam.

The scripts in this repository map directly onto Security+ domains:

| Security+ domain | Where it shows up here |
|------------------|------------------------|
| General Security Concepts | Least privilege and service account separation in `ollama-health.sh` |
| Threats, Vulnerabilities & Mitigations | Failed-logon analysis in `Script3-EventLogParser.ps1`; UID 0 backdoor detection in `user-audit.sh` |
| Security Architecture | Network exposure and bind-address auditing |
| Security Operations | Account auditing, log analysis, and automated monitoring across all six scripts |

**Longer term:** Linux+ or CCNA, depending on whether I move toward systems administration or
network engineering. The bash work in this repository leans toward the former.

---

## Notes on Findings

Real issues surfaced by these scripts while testing against live systems:

- **A dormant administrator account.** `Script2-UserAccountReport.ps1` found an enabled account
  named `superman` on the domain controller that is a member of Administrators and has **never
  logged in**. Dormant privileged accounts are a well-known persistence mechanism — nobody
  notices they exist, and nobody notices when they're used.
- **The Guest account is enabled.** Guest ships disabled on every modern Windows install, so it
  was turned on deliberately. Non-admin, so lower severity, but it wouldn't survive an audit.
- **`Get-LocalGroupMember` fails on a domain controller.** Domain controllers have no local groups
  — the SAM is replaced by Active Directory, and `Administrators` becomes a `BUILTIN\` domain
  group. This caused the audit to report *every* account as non-administrator, including the
  built-in `Administrator`. Fixed with role detection and a three-method fallback chain.
- **Access control confirmed working.** `user-audit.sh` showed that `it100student` holds no sudo
  rights on `linuxbox` — only `atorres` does. That explains why the Ollama disk check reports
  "could not verify" rather than a size: the model directory genuinely isn't readable from an
  unprivileged account. The script reports what it couldn't check instead of guessing, which is
  the correct behavior for an audit tool.

---

## Usage

**PowerShell** — run from an elevated session for the Security log and full account detail:

```powershell
Set-ExecutionPolicy -Scope Process -Bypass
.\Script1-SystemHealthCheck.ps1
```

**Bash** — make executable, then run. `user-audit.sh` gives complete results under sudo:

```bash
chmod +x *.sh
./sysinfo.sh
./ollama-health.sh
sudo ./user-audit.sh
```

Every script writes a timestamped report and prints the same content to the terminal. Terminal
output is colorized; the saved report is plain ASCII with no escape sequences.
