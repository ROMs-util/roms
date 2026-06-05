# source.ps1 - Channel and Registry Source Orchestration
# Follows MODULARITY_STANDARDS.md and DESIGN_STANDARDS.md

# ---------------------------------------------
# SESSION IDENTIFICATION (Industrial Tree-Crawl)
# Finds the highest stable ancestor (Terminal/Shell) that exists 
# throughout the entire window session. 
#
# HOW IT WORKS:
# 1. Uses Get-CimInstance (fallback to WMI) to find the parent of the current process.
# 2. Recursively climbs the process tree as long as the parent is a known shell.
# 3. Stops at 'explorer' or the highest terminal host (e.g. WindowsTerminal).
# 4. Returns the ID of that stable process to act as a unique Session Key.
#
# RETURNS: [int] The stable Parent Process ID.
# ---------------------------------------------
function Get-RomsSessionID {
    $currentID = $PID
    $stableID = $PID
    try {
        # Loop to climb the process tree
        while ($true) {
            # Get parent ID using CIM (Universal standard)
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $currentID" -ErrorAction SilentlyContinue
            if (-not $proc -or -not $proc.ParentProcessId) { break }
            
            $ppid = $proc.ParentProcessId
            $parent = Get-Process -Id $ppid -ErrorAction SilentlyContinue
            
            # Stop if the parent is not a shell or terminal component
            if (-not $parent -or $parent.ProcessName -notmatch "powershell|pwsh|cmd|conhost|WindowsTerminal|explorer") { break }
            
            # Stop at explorer (desktop level)
            if ($parent.ProcessName -eq "explorer") { break }
            
            $currentID = $ppid
            $stableID = $ppid
        }
    } catch { }
    return $stableID
}

# ---------------------------------------------
# CHANNEL DISCOVERY (Hierarchical Precedence)
# Resolves the active channel for the current operation.
#
# HOW IT WORKS:
# 1. Checks internal process memory for overrides.
# 2. Checks for a window-isolated session file (temp/sessions/roms.<sid>.json).
# 3. Checks global sticky preference in sources.json.
# 4. Falls back to ecosystem default ("mainnet").
#
# RETURNS: [string] The name of the active channel.
# ---------------------------------------------
function Get-RomsActiveChannel {
    param([string]$PackageName)

    # 1. Persistent Shell Session
    try {
        $sid = Get-RomsSessionID
        $sessionFile = Join-Path $global:ROMs_TEMP "sessions\roms.$sid.json"
        
        if (Test-Path $sessionFile) {
            $sessionData = Get-Content $sessionFile -Raw | ConvertFrom-Json
            if ($null -ne $sessionData.channel) { 
                Write-Log "Session Channel Active: $($sessionData.channel) (Host: $sid)" "TRACE"
                return $sessionData.channel 
            }
        }
    } catch { }

    # 2. Sticky User Preference
    if (Test-Path $global:ROMs_SOURCES) {
        try {
            $registry = [System.IO.File]::ReadAllText($global:ROMs_SOURCES) | ConvertFrom-Json
            if ($null -ne $registry.preferred_channel) {
                return $registry.preferred_channel
            }
        } catch { }
    }

    return $global:ROMs_CHANNEL 
}

# ---------------------------------------------
# ACTIVE CHANNEL IDENTIFIERS (Isolation Enforcer)
# Returns a list of all qualified channel names (source.channel) that are 
# currently active (either globally ON or session-PICKED).
#
# HOW IT WORKS:
# 1. Parses sources.json to find all registered source/channel pairs.
# 2. Compares each channel against the session-active channel (from pick).
# 3. Only returns identifiers for channels that the user has authorized.
#
# RETURNS: [array] List of strings (e.g. ["official.mainnet"]).
# ---------------------------------------------
function Get-RomsActiveChannelIdentifiers {
    if (-not (Test-Path $global:ROMs_SOURCES)) { return @() }
    
    $registry = Get-Content $global:ROMs_SOURCES -Raw | ConvertFrom-Json
    if ($null -eq $registry -or $null -eq $registry.sources) { return @() }
    
    $activeSessionChannel = Get-RomsActiveChannel
    $activeIDs = @()

    foreach ($s in $registry.sources) {
        if ($null -eq $s.channels) { continue }
        $channels = $s.channels.PSObject.Properties.Name
        foreach ($c in $channels) {
            $chan = $s.channels.$c
            $isPicked = ($c -eq $activeSessionChannel)
            if ($chan.status -eq "on" -or $isPicked) {
                $activeIDs += "$($s.name).$c"
            }
        }
    }
    return $activeIDs
}

# ---------------------------------------------
# SOURCE COMMAND SUITE
# High-level entry point for managing repository sources and channels.
#
# USAGE: roms source <list | on | off | pick> [args]
# ---------------------------------------------
function Invoke-RomsSourceCommand {
    param(
        [string]$SubCommand,
        [string[]]$RemainingArgs
    )

    Initialize-Sources 

    switch ($SubCommand) {
        "list" { Show-RomsSourceList }
        "on"   { Set-RomsChannelStatus -Channel $RemainingArgs[0] -Status "on" }
        "off"  { Set-RomsChannelStatus -Channel $RemainingArgs[0] -Status "off" }
        "pick" { Set-RomsPreferredChannel -Channel $RemainingArgs[0] }
        Default {
            Write-Log "Usage: roms source <list | on | off | pick> [args]" "INFO"
        }
    }
}

# ---------------------------------------------
# SOURCE LIST DISPLAY
# Renders a Cyan/Yellow table of all registered sources and their statuses.
# Annotates the current session-active channel with an asterisk (*).
# ---------------------------------------------
function Show-RomsSourceList {
    if (-not (Test-Path $global:ROMs_SOURCES)) {
        Write-Log "Sources registry not found. Run 'roms update' first." "WARN"
        return
    }

    $registry = Get-Content $global:ROMs_SOURCES -Raw | ConvertFrom-Json
    if ($null -eq $registry -or $null -eq $registry.sources) {
        Write-Log "Sources registry is malformed." "ERROR"
        return
    }

    $activeChannel = Get-RomsActiveChannel
    Write-Host "`n----- Registered Sources -----" -ForegroundColor Cyan
    
    foreach ($s in $registry.sources) {
        if ($null -eq $s) { continue }
        Write-Host "Source: $($s.name)" -ForegroundColor Yellow
        Write-Host "  Base URL: $($s.base_url)"
        Write-Host "  Channels:"
        
        if ($null -ne $s.channels) {
            $channels = $s.channels.PSObject.Properties.Name
            foreach ($c in $channels) {
                $status = $s.channels.$c.status
                $color = if ($status -eq "on") { "Green" } else { "Gray" }
                $pref = if ($c -eq $activeChannel) { "*" } else { " " }
                Write-Host "    $pref [$($status.ToUpper())] $c" -ForegroundColor $color
            }
        }
        Write-Host ""
    }
    Write-Host "(*) Active Channel for this session: $activeChannel" -ForegroundColor Cyan
}

# ---------------------------------------------
# CHANNEL STATUS MANAGER
# Permanently enables or disables a channel in sources.json.
#
# HOW IT WORKS:
# 1. Modifies the 'status' field for the target channel across all sources.
# 2. Persists changes to disk. Requires UAC elevation via router.
# ---------------------------------------------
function Set-RomsChannelStatus {
    param([string]$Channel, [string]$Status)
    if (-not $Channel) { Write-Log "Channel name required." "ERROR"; return }

    try {
        if (-not (Test-Path $global:ROMs_SOURCES)) { Initialize-Sources }
        $registry = Get-Content $global:ROMs_SOURCES -Raw | ConvertFrom-Json
        
        if ($null -eq $registry -or $null -eq $registry.sources) {
            Write-Log "Sources registry is missing." "ERROR"
            return
        }

        $found = $false
        foreach ($s in $registry.sources) {
            if ($null -ne $s.channels -and $null -ne $s.channels.$Channel) {
                $s.channels.$Channel.status = $Status
                $found = $true
            }
        }

        if ($found) {
            $registry | ConvertTo-Json -Depth 10 | Out-File -FilePath $global:ROMs_SOURCES -Encoding utf8
            Write-Log "Channel '$Channel' set to $Status." "SUCCESS"
        } else {
            Write-Log "Channel '$Channel' not found." "ERROR"
        }
    } finally {
        Write-Log "Failed to update channel status: $($_.Exception.Message)" "ERROR"
        Exit-RomsTransaction
    }
}

# ---------------------------------------------
# SESSION CHANNEL SELECTOR (Pick)
# Activates a channel for the current terminal window only.
#
# HOW IT WORKS:
# 1. Validates that the channel exists in the registry.
# 2. Identifies the stable Ancestor Shell ID (sid).
# 3. Writes a session JSON file to temp/sessions/roms.<sid>.json.
# 4. Does NOT require Administrator privileges.
# ---------------------------------------------
function Set-RomsPreferredChannel {
    param([string]$Channel)
    if (-not $Channel) { Write-Log "Channel name required." "ERROR"; return }

    # Validate channel exists in any active source
    if (-not (Test-Path $global:ROMs_SOURCES)) { Initialize-Sources }
    $registry = Get-Content $global:ROMs_SOURCES -Raw | ConvertFrom-Json
    
    $exists = $false
    foreach ($s in $registry.sources) {
        if ($null -ne $s.channels -and $null -ne $s.channels.$Channel) { $exists = $true; break }
    }

    if (-not $exists) {
        Write-Log "Unknown channel: $Channel" "ERROR"
        return
    }

    # Implement Session-Only picking via robust ancestor detection
    try {
        $sid = Get-RomsSessionID
        $sessionDir = Join-Path $global:ROMs_TEMP "sessions"
        if (-not (Test-Path $sessionDir)) { New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null }
        
        $sessionFile = Join-Path $sessionDir "roms.$sid.json"
        $sessionData = @{ channel = $Channel; timestamp = (Get-Date -Format "o") }
        $sessionData | ConvertTo-Json | Out-File -FilePath $sessionFile -Encoding utf8
        
        Write-Log "Session channel set to '$Channel' (Host: $sid)." "SUCCESS"
    } catch {
        Write-Log "Failed to set session: $($_.Exception.Message)" "ERROR"
    }
}
