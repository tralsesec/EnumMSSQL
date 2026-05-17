# EnumMSSQL

<img width="1176" height="261" alt="image" src="https://github.com/user-attachments/assets/fc883d83-bd5a-484b-aad6-75fca9ca284f" />

**EnumMSSQL** is a weaponized, military-grade, standalone bash wrapper for `impacket-mssqlclient`. It is designed to automate the MSSQL post-exploitation lifecycle, transforming standard enumeration into a highly visual, zero-dependency workflow.

It handles terminal layout healing, background listener management (Responder), port auditing, and LinPEAS-style colorized output for rapid identification of privilege escalation vectors.

This was originally developed as a private tool for my personal engagements and CTF workflows. I've decided to open-source it to streamline MSSQL post-exploitation for the community.

---

## 🎯 Features

* **The Ghost Hunter:** Dynamically maps Linked Servers and utilizes `TRY...CATCH` blocks and RPC calls to test remote execution capabilities and identify "ghost" DNS entries ripe for spoofing.
* **Triple-Threat Hash Capturing:** Automatically spins up a background `Responder` instance, safely isolates its database to prevent "hash skipping", and attempts forced NTLM authentication over both **SMB (445)** and **WebDAV (80)** to bypass strict egress firewalls.
* **Auto-Dump (`--dump`):** Bypasses T-SQL cursor limitations utilizing undocumented stored procedures (`sp_MSforeachdb` / `sp_MSforeachtable`) to seamlessly extract every table from every non-system database into a local flat file.
* **Visual Threat Parsing:** Aggressively filters Impacket's raw TDS rowset output and color-codes the results. High-value PrivEsc vectors (e.g., `is_trustworthy_on`, `xp_cmdshell`, `sysadmin`) are highlighted in **RED**, while system defaults are muted in **YELLOW**.
* **Pre-Flight Port Auditing:** Actively scans your local host for conflicting sockets (Port 80/443/445) before launching listeners, allowing you to selectively kill blocking processes on the fly.
* **Terminal Self-Healing:** Automatically restores TTY state (`stty sane / onlcr`) to prevent the dreaded "staircase" formatting corruption caused by overlapping background processes.

---

## 📦 Dependencies

This tool relies on standard offensive security packages natively available on Kali Linux/Parrot OS:

* `impacket-mssqlclient` (or `mssqlclient.py`)
* `responder`
* Standard Linux utilities: `ss`, `awk`, `sed`, `grep`

---

## 🚀 Usage

```bash
Usage: enum-mssql.sh -u <user> -p <pass> -r <rhost> -l <lhost_or_interface> [options]

Required:
  -u, --user          Username for MSSQL authentication
  -p, --pass          Password for MSSQL authentication
  -r, --rhost         Target IP or Hostname
  -l, --lhost         Local IP or Interface (e.g., tun0) for hash capture

Optional:
  -d, --domain        Domain name (Leave blank for local SQL auth)
  -P, --rport         Target MSSQL Port (Default: 1433)
  -w, --windows-auth  Use Windows Authentication
  -D, --dump          DUMP MODE: Extract all non-system databases to enum-mssql.dump
  -h, --help          Show the help menu

```

### Examples

**Standard Local SQL Authentication:**

```bash
enum-mssql.sh -u SQLGuest -p 'zDPBpaF4FywlqIv11vii' -r 10.129.46.200 -l tun0

```

**Active Directory / Windows Authentication:**

```bash
enum-mssql.sh -d MEGACORP -u sql_svc -p 'Winter2026!' -r 10.10.10.50 -l 10.10.14.5 -w

```

**Database Dump Mode (Extract all custom tables):**

```bash
enum-mssql.sh -u sa -p 'SuperSecret' -r 10.129.46.200 -l tun0 --dump

```

---

### 🦖 See it in Action

<img width="3840" height="2097" alt="image" src="https://github.com/user-attachments/assets/76875007-1eb9-4979-9010-c2c8b9ecced0" />

<img width="3838" height="2095" alt="image" src="https://github.com/user-attachments/assets/df60a172-f52d-4ff4-b782-e2c20c5dc144" />

<img width="3840" height="2098" alt="image" src="https://github.com/user-attachments/assets/d828d153-93a8-49b9-950b-428954b7b842" />

---

## 🛡️ Execution Phases

1. **Basic Server Recon:** Versioning, Hostname, Current User mapping.
2. **Privileges & Roles:** Server-level permissions and Impersonation rights.
3. **Trustworthy Status:** Maps `is_trustworthy_on` for potential DB Owner to Sysadmin escalation.
4. **Current Database Mapping:** Table extraction.
5. **Execution Vectors:** Audits local `xp_cmdshell` and OLE Automation procedures.
6. **CLR Assemblies:** Hunts for custom, user-defined .NET assemblies and extended procedures.
7. **Linked Server Ghost Hunter:** Audits remote links for RPC execution capabilities and dead DNS entries.
8. **Loot Extraction:** Casts varbinary `password_hash` fields to hex strings for direct Hashcat cracking.
9. **Forced NTLM Capture:** Executes `xp_dirtree`, `xp_subdirs`, and `xp_fileexist` over ports 445 and 80.

---

## ⚠️ Disclaimer

This tool is designed for educational purposes and authorized penetration testing / red teaming only. The author is not responsible for any misuse or damage caused by this script. Never run tools against infrastructure you do not explicitly own or have written permission to test.

---

**Author:** [tralsesec](https://github.com/tralsesec)

**License:** MIT

---
