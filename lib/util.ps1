# util.ps1 - Shared native .NET primitives and helper functions

# ---------------------------------------------
# CRYPTOGRAPHY (Industrial Strength)
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
# VERSIONING (Industrial Strength - SemVer 2.0)
# ---------------------------------------------

function Get-RomsVersionParts {
    param([string]$Version)
    # SemVer 2.0 Regex (Major.Minor.Patch[-PreRelease])
    if ($Version -match "^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$") {
        return [PSCustomObject]@{
            Major = [int]$Matches[1]
            Minor = [int]$Matches[2]
            Patch = [int]$Matches[3]
            Pre   = $Matches[4]
        }
    }
    return $null
}

function Test-RomsVersionMatch {
    param(
        [Parameter(Mandatory=$true)][string]$CurrentVersion,
        [Parameter(Mandatory=$true)][string]$Constraint
    )

    $v = Get-RomsVersionParts -Version $CurrentVersion
    if (!$v) { return $false }

    # Parse Constraint (e.g., ^1.2.0, ~2.1, >=1.0.0, or exact 1.0.0)
    if ($Constraint -match "^(\^|~|>=|>|<=|<)?\s*(\d+(?:\.\d+)?(?:\.\d+)?(?:-.+)?)$") {
        $op = $Matches[1]
        $targetStr = $Matches[2]
        $target = Get-RomsVersionParts -Version $targetStr
        
        # Exact Match if no operator
        if (!$op) { return $CurrentVersion -eq $targetStr }

        # Caret (^) - Compatible with Major (e.g. ^1.2.3 means >=1.2.3 and <2.0.0)
        if ($op -eq "^") {
            if (!$target) { return $false }
            return ($v.Major -eq $target.Major) -and (
                ($v.Minor -gt $target.Minor) -or 
                ($v.Minor -eq $target.Minor -and $v.Patch -ge $target.Patch)
            )
        }

        # Tilde (~) - Compatible with Minor (e.g. ~1.2.3 means >=1.2.3 and <1.3.0)
        if ($op -eq "~") {
            if (!$target) { return $false }
            return ($v.Major -eq $target.Major -and $v.Minor -eq $target.Minor -and $v.Patch -ge $target.Patch)
        }

        # Numeric Comparisons via .NET [Version]
        try {
            $currVerObj = [version]$CurrentVersion.Split('-')[0]
            $targetVerObj = [version]$targetStr.Split('-')[0]
            
            switch ($op) {
                ">=" { return $currVerObj -ge $targetVerObj }
                ">"  { return $currVerObj -gt $targetVerObj }
                "<=" { return $currVerObj -le $targetVerObj }
                "<"  { return $currVerObj -lt $targetVerObj }
            }
        } catch { return $false }
    }

    return $CurrentVersion -eq $Constraint
}

# ---------------------------------------------
# FILE IO (Industrial Strength)
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
# NETWORKING (Industrial Strength)
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

    # Industrial Strength: Replace ALL occurrences of placeholders
    $url = $Template
    $url = $url.Replace("<name>", $Package.name)
    $url = $url.Replace("<version>", $Package.version)
    $url = $url.Replace("<architecture>", $Package.architecture)
    $url = $url.Replace("<filename>", $filename)
    
    return $url
}

# ---------------------------------------------
# ENGINE DISCOVERY (Industrial Strength)
# ---------------------------------------------
function Get-RomsEnginePath {
    # 1. Deterministic Standard Root
    if (Test-Path $global:ENGINE_SCRIPT) {
        return $global:ENGINE_SCRIPT
    }

    # 2. Workspace Detection (Internal/Dev only - strictly if .git exists)
    $devPath = Join-Path (Split-Path (Split-Path $PSScriptRoot)) "package_installer\rmspkg.ps1"
    if ((Test-Path (Join-Path (Split-Path (Split-Path $PSScriptRoot)) ".git")) -and (Test-Path $devPath)) {
        return $devPath
    }

    return $null
}
