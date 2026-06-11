# util.ps1 - Shared native .NET primitives and helper functions

# ---------------------------------------------
# CRYPTOGRAPHY ()
# Computes SHA256 hash of a file using native .NET (version-independent).
# Uses streaming to handle large files without memory bloat.
# Returns uppercase hex string, or $null if file doesn't exist.
# ---------------------------------------------
function Get-RomsFileHash {
    param([Parameter(Mandatory=$true)][string]$FilePath)

    if (-not (Test-Path $FilePath)) { return $null }

    $fileStream = $null
    try {
        # Native .NET Implementation (Universal Support)
        $fileStream = [System.IO.File]::OpenRead($FilePath)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $sha256.ComputeHash($fileStream)
        $fileStream.Close()
        
        return [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToUpper()
    } finally {
        if ($fileStream) { $fileStream.Dispose() }
    }
}

# ---------------------------------------------
# FILE IO ()
# Writes text content to a file using native .NET (prevents encoding corruption).
# Creates parent directory automatically if it doesn't exist.
# Uses specified encoding (default UTF-8) to avoid PowerShell quote-mangling.
# ---------------------------------------------
function Set-RomsFileContent {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string]$Content,
        [Parameter(Mandatory=$false)][System.Text.Encoding]$Encoding = [System.Text.Encoding]::UTF8
    )

    try {
        # Ensure parent directory exists
        $dir = Split-Path $FilePath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        # Native .NET Write (Prevents encoding/quote corruption)
        [System.IO.File]::WriteAllText($FilePath, $Content, $Encoding)
    } catch {
        throw "Failed to write file '$FilePath': $($_.Exception.Message)"
    }
}
# ---------------------------------------------
# NETWORKING ()
# Resolves a download URL template by replacing placeholders with package metadata.
# Replaces <name>, <version>, <architecture>, <filename> in the template string.
# Returns the fully resolved URL ready for Invoke-RestMethod or file copy.
# ---------------------------------------------
function Get-RomsResolvedUrl {
    param(
        [Parameter(Mandatory=$true)][string]$Template,
        [Parameter(Mandatory=$true)][PSCustomObject]$Package
    )
    
    if (-not $Template) { return "" }
    
    # Filename fallback: use metadata if exists, otherwise split URL leaf, otherwise generate standard name
    $filename = if ($Package.filename) { $Package.filename } else { Split-Path $Package.downloadUrl -Leaf }
    if (!$filename -or $filename -eq "") { 
        $filename = "$($Package.name)_$($Package.architecture)-v$($Package.version).rms" 
    }

    # : Replace ALL occurrences of placeholders
    $url = $Template
    $url = $url.Replace("<name>", $Package.name)
    $url = $url.Replace("<version>", $Package.version)
    $url = $url.Replace("<architecture>", $Package.architecture)
    $url = $url.Replace("<filename>", $filename)
    
    return $url
}

# ---------------------------------------------
# ARGUMENT RECOVERY (Industrial RAW)
# Captures arguments from the environment tunnel or raw command line.
# Preserves symbols like '>', '^', and '~' by parsing the raw string.
# Returns a high-fidelity array of arguments.
# ---------------------------------------------
function Get-RomsRawArguments {
    param([array]$FallbackArgs = @())

    try {
        # 1. TUNNEL RECOVERY: Capture literal input from the protected CMD tunnel.
        $raw = $env:ROMS_RAW_ARGS
        
        # Extract everything after the 'roms' command in the raw shell string
        if ($raw -match 'roms(?:\.bat)?["\s]+(.*)$') {
            $raw = $Matches[1].Trim()
            # Remove trailing quote from shell wrapping (cmd /c)
            if ($raw -match '^(.*)"$') { $raw = $Matches[1].Trim() }
        }

        # 2. SHELL OPERATOR GUARD: Truncate at first unquoted delimiter (&, |, >, <, ;)
        # This prevents 'roms pkg && other' from seeing '&& other' as arguments.
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $cleanRaw = ""
            $inQuote = $false
            for ($i = 0; $i -lt $raw.Length; $i++) {
                $char = $raw[$i]
                if ($char -eq '"') { $inQuote = -not $inQuote }
                if (-not $inQuote -and ($char -match '[&|><;]')) { break }
                $cleanRaw += $char
            }
            $raw = $cleanRaw.Trim()
        }

        # 3. CLEAR TUNNEL
        $env:ROMS_RAW_ARGS = $null
        
        # 4. Fallback to [Environment]::CommandLine if tunnel is missing
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $raw = [Environment]::CommandLine
            $anchor = $global:EntryScriptPath
            if (-not [string]::IsNullOrWhiteSpace($anchor)) {
                $index = $raw.IndexOf($anchor)
                if ($index -ne -1) {
                    $raw = $raw.Substring($index + $anchor.Length).Trim()
                    if ($raw.StartsWith('"')) { $raw = $raw.Substring(1).Trim() }
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($raw)) { return $FallbackArgs }

        # 5. Regex Tokenization (Industrial Standard)
        $regex = '(?i)"([^"]*)"|([^\s]+)'
        $matches = [regex]::Matches($raw, $regex)
        
        $result = @()
        foreach ($m in $matches) {
            $token = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
            $result += $token
        }
        
        if ($result.Count -eq 0) { return $FallbackArgs }
        return ,$result
    } catch {
        return $FallbackArgs
    }
}
