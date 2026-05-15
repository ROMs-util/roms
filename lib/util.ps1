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
# FILE IO (Industrial Strength)
# ---------------------------------------------
function Set-RomsFileContent {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string]$Content,
        [System.Text.Encoding]$Encoding = [System.Text.Encoding]::UTF8
    )

    try {
        $dir = Split-Path $FilePath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllText($FilePath, $Content, $Encoding)
    } catch {
        Write-Log "Failed to write file: $FilePath. $_" "ERROR"
        throw $_
    }
}
