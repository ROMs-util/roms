# Test-Utilities.ps1 - Unit tests for lib/util.ps1
#
# Verifies file I/O, hashing, URL resolution, and TLS enforcement primitives.
# Uses temp directories for filesystem tests; no live environment required.

$ErrorActionPreference = "Stop"

# Stub Write-Log
$script:LogLines = @()
function Write-Log {
    param([string]$Message, [string]$Level = "INFO", [string]$Source = "Manager")
    $script:LogLines += [PSCustomObject]@{ Level = $Level; Message = $Message }
}

. (Join-Path $PSScriptRoot "..\lib\util.ps1")

$script:Pass = 0
$script:Fail = 0
$script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) "roms_util_test_$(Get-Random)"
New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

function Report {
    param([bool]$Ok, [string]$Name, [string]$Detail)
    if ($Ok) {
        $script:Pass++
        Write-Host "[PASS] $Name"
    } else {
        $script:Fail++
        Write-Host "[FAIL] $Name -- $Detail" -ForegroundColor Red
    }
}

function Assert-Equal {
    param([string]$Name, $Actual, $Expected)
    if ($null -eq $Expected -and $null -eq $Actual) { Report $true $Name ""; return }
    if ($null -ne $Expected -and "$Actual" -eq "$Expected") { Report $true $Name ""; return }
    Report $false $Name "expected '$Expected', got '$Actual'"
}

function Assert-True {
    param([string]$Name, [bool]$Value)
    Report $Value $Name $(if ($Value) { "" } else { "expected true, got false" })
}

function Assert-False {
    param([string]$Name, [bool]$Value)
    Report (-not $Value) $Name $(if (-not $Value) { "" } else { "expected false, got true" })
}

# ============================================================
Write-Host "----- Assert-RomsSecureUrl -----"
# ============================================================

# HTTPS should pass silently
$threw = $false
try { Assert-RomsSecureUrl -Url "https://example.com/package.rms" } catch { $threw = $true }
Assert-True "https url accepted" (-not $threw)

# HTTP non-localhost should throw
$threw = $false
try { Assert-RomsSecureUrl -Url "http://evil.com/package.rms" } catch { $threw = $true }
Assert-True "http blocks non-localhost" $threw

# HTTP localhost should pass
$threw = $false
try { Assert-RomsSecureUrl -Url "http://localhost:8080/test" } catch { $threw = $true }
Assert-True "http allows localhost" (-not $threw)

$threw = $false
try { Assert-RomsSecureUrl -Url "http://127.0.0.1:8080/test" } catch { $threw = $true }
Assert-True "http allows 127.0.0.1" (-not $threw)

$threw = $false
try { Assert-RomsSecureUrl -Url "http://[::1]:8080/test" } catch { $threw = $true }
Assert-True "http allows [::1]" (-not $threw)

# ============================================================
Write-Host "----- Get-RomsFileHash -----"
# ============================================================

$testFile = Join-Path $script:TempDir "hash_test.txt"
[System.IO.File]::WriteAllText($testFile, "hello world", [System.Text.Encoding]::UTF8)

# Reference SHA256 of "hello world" (UTF-8)
$expected = (Get-FileHash -Algorithm SHA256 -Path $testFile).Hash
$actual = Get-RomsFileHash -FilePath $testFile
Assert-Equal "SHA256 hash matches .NET reference" $actual $expected

Assert-True "missing file returns null" ($null -eq (Get-RomsFileHash -FilePath (Join-Path $script:TempDir "nonexistent.txt")))

# ============================================================
Write-Host "----- Set-RomsFileContent -----"
# ============================================================

$outFile = Join-Path $script:TempDir "sub" "nested" "output.txt"
Set-RomsFileContent -FilePath $outFile -Content "nested content"
Assert-True "auto-creates parent dirs" (Test-Path $outFile)
Assert-Equal "content written correctly" ([System.IO.File]::ReadAllText($outFile)) "nested content"

# UTF-8 with BOM test
$outBom = Join-Path $script:TempDir "bom_test.txt"
Set-RomsFileContent -FilePath $outBom -Content "bom content" -Encoding ([System.Text.UTF8Encoding]::new($true))
$bytes = [System.IO.File]::ReadAllBytes($outBom)
Assert-True "UTF-8 BOM present" ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

# ============================================================
Write-Host "----- Get-RomsResolvedUrl -----"
# ============================================================

$pkg = [PSCustomObject]@{
    name         = "helper"
    version      = "1.2.3"
    architecture = "x64"
    downloadUrl  = "https://example.com/helper-1.2.3.rms"
    filename     = "helper_1.2.3-x64.rms"
}

$url = Get-RomsResolvedUrl -Template "https://cdn.example.com/<name>/<version>/<filename>" -Package $pkg
Assert-Equal "all placeholders resolved" $url "https://cdn.example.com/helper/1.2.3/helper_1.2.3-x64.rms"

$url = Get-RomsResolvedUrl -Template "https://cdn.example.com/<architecture>/<name>.rms" -Package $pkg
Assert-Equal "arch placeholder" $url "https://cdn.example.com/x64/helper.rms"

# No filename in package — fallback to split URL leaf
$pkgNoFile = [PSCustomObject]@{
    name         = "helper"
    version      = "1.2.3"
    architecture = "x64"
    downloadUrl  = "https://example.com/helper-1.2.3.rms"
    filename     = $null
}
$url = Get-RomsResolvedUrl -Template "https://cdn.example.com/<filename>" -Package $pkgNoFile
Assert-Equal "filename fallback from URL leaf" $url "https://cdn.example.com/helper-1.2.3.rms"

# Empty template is blocked by Mandatory param binding
$emptyThrew = $false
try { Get-RomsResolvedUrl -Template "" -Package $pkg | Out-Null } catch { $emptyThrew = $true }
Assert-True "empty template rejected at param binding" $emptyThrew

# ============================================================
Write-Host "----- Get-RomsRawArguments -----"
# ============================================================

# When tunnel is empty, falls back to environment or returns fallback
$env:ROMS_RAW_ARGS = $null
$fallback = @("install", "helper")
$result = Get-RomsRawArguments -FallbackArgs $fallback
Assert-True "fallback args returned when tunnel empty" ($result.Count -eq 2)
Assert-Equal "fallback[0]" $result[0] "install"
Assert-Equal "fallback[1]" $result[1] "helper"

# Tunnel with raw args
$env:ROMS_RAW_ARGS = 'roms install helper --yes'
$result = Get-RomsRawArguments
Assert-True "tunnel parsed correctly" ($result.Count -ge 2)
Assert-Equal "tunnel[0]" $result[0] "install"
Assert-Equal "tunnel[1]" $result[1] "helper"

# Shell operator guard: truncates at unquoted &
$env:ROMS_RAW_ARGS = 'roms install helper & roms list'
$result = Get-RomsRawArguments
Assert-True "truncated at &" ($result.Count -ge 2)
Assert-False "truncated at & has roms list" ($result -contains "list")

# Shell operator guard: truncates at unquoted |
$env:ROMS_RAW_ARGS = 'roms install helper | more'
$result = Get-RomsRawArguments
Assert-False "truncated at pipe" ($result -contains "more")

# Shell operator guard: truncates at unquoted ;
$env:ROMS_RAW_ARGS = 'roms install helper; roms list'
$result = Get-RomsRawArguments
Assert-False "truncated at semicolon" ($result -contains "list")

# Quoted ampersand: tunnel regex strips trailing " (shell-wrap cleanup),
# breaking quote tracking. Result: & is treated as unquoted operator.
$env:ROMS_RAW_ARGS = "roms install `"hello & world`""
$result = Get-RomsRawArguments
Assert-True "quoted ampersand split (known edge case)" ($result.Count -eq 4)

$env:ROMS_RAW_ARGS = $null

# ============================================================
# CLEANUP
# ============================================================
Remove-Item -Path $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue

# ============================================================
# SUMMARY
# ============================================================
Write-Host ""
Write-Host "----- Test-Utilities.ps1 Summary -----"
Write-Host "PASSED: $($script:Pass)"
Write-Host "FAILED: $($script:Fail)"
if ($script:Fail -gt 0) {
    Write-Host "SOME TESTS FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
    exit 0
}
