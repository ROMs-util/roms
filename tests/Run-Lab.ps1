# Run-Lab.ps1 - Lab integration tests for the package_manager (roms)
#
# Exercises every package_testnet scenario through the `roms` CLI.
# Requires: live C:\roms environment, `roms update` synced with testnet index.
# Each test cleans up after itself to prevent cross-test contamination.

$ErrorActionPreference = "Stop"

$script:Pass = 0
$script:Fail = 0
$script:CleanList = @()

function Report {
    param([bool]$Ok, [string]$Name, [string]$Detail = "")
    if ($Ok) { $script:Pass++; Write-Host "  [PASS] $Name" }
    else { $script:Fail++; Write-Host "  [FAIL] $Name -- $Detail" -ForegroundColor Red }
}

function Invoke-Roms {
    param([string[]]$RomArgs)
    $argString = $RomArgs -join " "
    $output = powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'C:\roms\bin\roms.bat' $argString 2>&1"
    $exitCode = $LASTEXITCODE
    return [PSCustomObject]@{
        Output   = $output
        ExitCode = $exitCode
        Text     = ($output -join "`n")
    }
}

function Clean-Package {
    param([string]$Name)
    $dirs = @(
        "C:\roms\$Name",
        "C:\roms\.metadata\$Name.json",
        "C:\roms\bin\$Name.bat",
        "C:\roms\logs\$Name.log"
    )
    foreach ($d in $dirs) {
        if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    # Also clean alternatives.json entries
    $altsFile = "C:\roms\alternatives.json"
    if (Test-Path $altsFile) {
        try {
            $alts = Get-Content $altsFile -Raw | ConvertFrom-Json
            foreach ($prop in $alts.PSObject.Properties) {
                $cmdName = $prop.Name
                $entry = $prop.Value
                $pkgId = "$Name-1.0.0"
                $before = @($entry.providers).Count
                $entry.providers = @($entry.providers | Where-Object { $_.package -ne $pkgId })
                if (@($entry.providers).Count -lt $before) {
                    if ($entry.selected -eq $pkgId) {
                        $nextBest = $entry.providers | Sort-Object priority -Descending | Select-Object -First 1
                        $entry.selected = if ($nextBest) { $nextBest.package } else { $null }
                    }
                    $alts | ConvertTo-Json -Depth 10 | Out-File $altsFile -Encoding utf8 -Force
                }
            }
        } catch { }
    }
}

function Mark-Log {
    $m = "LAB-MARKER-$([guid]::NewGuid().ToString('N'))"
    $logFile = "C:\roms\logs\roms.log"
    if (Test-Path $logFile) { Add-Content -Path $logFile -Value $m -Encoding utf8 }
    return $m
}

function Get-LogTail {
    param([string]$Marker)
    $logFile = "C:\roms\logs\roms.log"
    if (-not (Test-Path $logFile)) { return @() }
    $lines = Get-Content $logFile
    $idx = ($lines | Select-String -SimpleMatch $Marker | Select-Object -Last 1).LineNumber
    if (-not $idx) { return @() }
    return @($lines[$idx..($lines.Count - 1)])
}

# ===========================================================================
Write-Host "=============================================="
Write-Host " LAB SUITE - package_manager (roms)"
Write-Host "=============================================="

# --- Preflight: sync registry ---
Write-Host "`n--- Preflight: syncing registry ---"
$syncResult = Invoke-Roms @("update")
Report ($syncResult.ExitCode -eq 0) "registry sync" $syncResult.Text.Substring(0, [Math]::Min(200, $syncResult.Text.Length))

# ===========================================================================
Write-Host "`n--- 1. Recursive Resolver (chain-a -> chain-b -> chain-c) ---"

Clean-Package "chain-a"; Clean-Package "chain-b"; Clean-Package "chain-c"
$marker = Mark-Log
$r = Invoke-Roms @("install", "chain-a", "-y")
Report ($r.ExitCode -eq 0) "chain-a install exit 0" "exit=$($r.ExitCode)"

# Physical Truth: all three metadata files must exist
Report (Test-Path "C:\roms\.metadata\chain-a.json") "chain-a metadata exists"
Report (Test-Path "C:\roms\.metadata\chain-b.json") "chain-b metadata exists"
Report (Test-Path "C:\roms\.metadata\chain-c.json") "chain-c metadata exists"

# Physical Truth: all three directories must exist
Report (Test-Path "C:\roms\chain-a") "chain-a directory exists"
Report (Test-Path "C:\roms\chain-b") "chain-b directory exists"
Report (Test-Path "C:\roms\chain-c") "chain-c directory exists"

# roms list must show all three
$listResult = Invoke-Roms @("list")
Report ($listResult.Text -match "chain-a" -and $listResult.Text -match "chain-b" -and $listResult.Text -match "chain-c") "roms list shows all three"

Clean-Package "chain-a"; Clean-Package "chain-b"; Clean-Package "chain-c"

# ===========================================================================
Write-Host "`n--- 2. Atomic AVC Cleanup (chain-fail -> chain-broken) ---"

Clean-Package "chain-fail"
$marker = Mark-Log
$r = Invoke-Roms @("install", "chain-fail", "-y")
$tail = Get-LogTail $marker

# Must report failure
Report ($r.Text -match "CRITICAL FAILURE" -or $r.Text -match "not found" -or $r.Text -match "Abort") "chain-fail reports failure"

# Physical Truth: no directory or metadata
Report (-not (Test-Path "C:\roms\chain-fail")) "chain-fail directory absent"
Report (-not (Test-Path "C:\roms\.metadata\chain-fail.json")) "chain-fail metadata absent"

Clean-Package "chain-fail"

# ===========================================================================
Write-Host "`n--- 3. Transactional Rollback (state-breaker) ---"

Clean-Package "state-breaker"
$marker = Mark-Log
$r = Invoke-Roms @("install", "state-breaker", "-y")

# Must report failure (postInstall hook exits 1)
Report ($r.Text -match "CRITICAL FAILURE" -or $r.ExitCode -ne 0) "state-breaker reports failure"

# Physical Truth: directory must be cleaned up
Report (-not (Test-Path "C:\roms\state-breaker")) "state-breaker directory absent (rollback)"

Clean-Package "state-breaker"

# ===========================================================================
Write-Host "`n--- 4. Global Rollback (fail-chain -> helper) ---"

Clean-Package "fail-chain"; Clean-Package "helper"
$marker = Mark-Log
$r = Invoke-Roms @("install", "fail-chain", "-y")

# fail-chain fails, helper must be rolled back
Report ($r.Text -match "CRITICAL FAILURE" -or $r.ExitCode -ne 0) "fail-chain reports failure"

# Physical Truth: both must be absent (global rollback)
Report (-not (Test-Path "C:\roms\fail-chain")) "fail-chain directory absent"
Report (-not (Test-Path "C:\roms\helper")) "helper directory absent (rolled back)"
Report (-not (Test-Path "C:\roms\.metadata\fail-chain.json")) "fail-chain metadata absent"
Report (-not (Test-Path "C:\roms\.metadata\helper.json")) "helper metadata absent (rolled back)"

Clean-Package "fail-chain"; Clean-Package "helper"

# ===========================================================================
Write-Host "`n--- 5. Alternatives & Auto-Pivot (pivot-v1, pivot-v2) ---"

Clean-Package "pivot-v1"; Clean-Package "pivot-v2"
$altsFile = "C:\roms\alternatives.json"

# Install pivot-v1 first
$r = Invoke-Roms @("install", "pivot-v1", "-y")
Report ($r.ExitCode -eq 0) "pivot-v1 install" "exit=$($r.ExitCode)"

# Install pivot-v2 (same commandName, same default priority)
$r = Invoke-Roms @("install", "pivot-v2", "-y")
Report ($r.ExitCode -eq 0) "pivot-v2 install" "exit=$($r.ExitCode)"

# Strictly higher rule: first installed wins when priorities equal
if (Test-Path $altsFile) {
    $alts = Get-Content $altsFile -Raw | ConvertFrom-Json
    $selected = $alts.'lab-pivot'.selected
    Report ($selected -eq "pivot-v1-1.0.0") "pivot-v1 stays selected (equal priority)" "selected=$selected"
}

# Uninstall pivot-v1 -> should pivot to pivot-v2
$r = Invoke-Roms @("uninstall", "pivot-v1", "-y")
Report ($r.ExitCode -eq 0) "pivot-v1 uninstall" "exit=$($r.ExitCode)"

if (Test-Path $altsFile) {
    $alts = Get-Content $altsFile -Raw | ConvertFrom-Json
    $selected = $alts.'lab-pivot'.selected
    Report ($selected -eq "pivot-v2-1.0.0") "pivot-v2 auto-pivoted" "selected=$selected"
}

Clean-Package "pivot-v1"; Clean-Package "pivot-v2"

# ===========================================================================
Write-Host "`n--- 6. Priority Takeover (priority-base, priority-max) ---"

Clean-Package "priority-base"; Clean-Package "priority-max"

# Install base (priority 100)
$r = Invoke-Roms @("install", "priority-base", "-y")
Report ($r.ExitCode -eq 0) "priority-base install" "exit=$($r.ExitCode)"

# Install max (priority 200) -> should takeover
$r = Invoke-Roms @("install", "priority-max", "-y")
Report ($r.ExitCode -eq 0) "priority-max install" "exit=$($r.ExitCode)"

if (Test-Path $altsFile) {
    $alts = Get-Content $altsFile -Raw | ConvertFrom-Json
    $selected = $alts.'lab-priority'.selected
    Report ($selected -eq "priority-max-1.0.0") "priority-max took over" "selected=$selected"
}

Clean-Package "priority-base"; Clean-Package "priority-max"

# ===========================================================================
Write-Host "`n--- 7. Environment Variables (env-pro) ---"

Clean-Package "env-pro"

$r = Invoke-Roms @("install", "env-pro", "-y")
Report ($r.ExitCode -eq 0) "env-pro install" "exit=$($r.ExitCode)"

# Check environment variable (Machine or User scope fallback)
$machineVal = [System.Environment]::GetEnvironmentVariable("ROMS_LAB_VAR", "Machine")
$userVal = [System.Environment]::GetEnvironmentVariable("ROMS_LAB_VAR", "User")
$envSet = ($machineVal -eq "STABLE") -or ($userVal -eq "STABLE")
Report $envSet "ROMS_LAB_VAR set after install" "machine=$machineVal user=$userVal"

# Uninstall -> must clean up
$r = Invoke-Roms @("uninstall", "env-pro", "-y")
Report ($r.ExitCode -eq 0) "env-pro uninstall" "exit=$($r.ExitCode)"

$machineAfter = [System.Environment]::GetEnvironmentVariable("ROMS_LAB_VAR", "Machine")
$userAfter = [System.Environment]::GetEnvironmentVariable("ROMS_LAB_VAR", "User")
Report ($null -eq $machineAfter -and $null -eq $userAfter) "ROMS_LAB_VAR removed after uninstall" "machine=$machineAfter user=$userAfter"

Clean-Package "env-pro"

# ===========================================================================
Write-Host "`n--- 8. Lifecycle Hooks (hook-manifest) ---"

Clean-Package "hook-manifest"
$hookLog = "C:\roms\logs\hook-verify.log"
if (Test-Path $hookLog) { Remove-Item $hookLog -Force -ErrorAction SilentlyContinue }

$r = Invoke-Roms @("install", "hook-manifest", "-y")
Report ($r.ExitCode -eq 0) "hook-manifest install" "exit=$($r.ExitCode)"

# Uninstall to trigger all 4 hooks
$r = Invoke-Roms @("uninstall", "hook-manifest", "-y")
Report ($r.ExitCode -eq 0) "hook-manifest uninstall" "exit=$($r.ExitCode)"

# Verify hook-verify.log has all 4 timestamps
if (Test-Path $hookLog) {
    $hookContent = Get-Content $hookLog -Raw
    Report ($hookContent -match "PRE-INSTALL") "pre-install hook fired"
    Report ($hookContent -match "POST-INSTALL") "post-install hook fired"
    Report ($hookContent -match "PRE-UNINSTALL") "pre-uninstall hook fired"
    Report ($hookContent -match "POST-UNINSTALL") "post-uninstall hook fired"
} else {
    Report $false "hook-verify.log exists" "file not found"
}

Clean-Package "hook-manifest"

# ===========================================================================
Write-Host "`n--- 9. Heterogeneous Chain (paybox -> moonpay -> chain-c) ---"

Clean-Package "paybox"; Clean-Package "moonpay"; Clean-Package "chain-c"

$r = Invoke-Roms @("install", "paybox", "-y")
Report ($r.ExitCode -eq 0) "paybox install" "exit=$($r.ExitCode)"

# All three must be installed
Report (Test-Path "C:\roms\.metadata\paybox.json") "paybox metadata exists"
Report (Test-Path "C:\roms\.metadata\moonpay.json") "moonpay metadata exists"
Report (Test-Path "C:\roms\.metadata\chain-c.json") "chain-c metadata exists (via moonpay)"

Clean-Package "paybox"; Clean-Package "moonpay"; Clean-Package "chain-c"

# ===========================================================================
Write-Host "`n--- 10. SemVer Resolution Matrix ---"

# Ensure helper is clean before each sub-test
function Test-SemVerCase {
    param([string]$ConstraintPkg, [string]$ExpectedVersion, [string]$Label)
    
    Clean-Package $ConstraintPkg; Clean-Package "helper"
    
    $r = Invoke-Roms @("install", $ConstraintPkg, "-v")
    Report ($r.ExitCode -eq 0) "$Label install" "exit=$($r.ExitCode)"
    
    # Physical Truth: check metadata version
    $metaFile = "C:\roms\.metadata\helper.json"
    if (Test-Path $metaFile) {
        $meta = Get-Content $metaFile -Raw | ConvertFrom-Json
        Report ($meta.version -eq $ExpectedVersion) "$Label resolves to $ExpectedVersion" "got $($meta.version)"
    } else {
        Report $false "$Label helper metadata exists" "file not found"
    }
    
    Clean-Package $ConstraintPkg; Clean-Package "helper"
}

Test-SemVerCase "ver-caret"  "1.1.0" "ver-caret (^1.0.0)"
Test-SemVerCase "ver-tilde"  "1.0.1" "ver-tilde (~1.0.0)"
Test-SemVerCase "ver-range"  "2.0.1" "ver-range (>=1.1.0)"
Test-SemVerCase "ver-pre"    "1.2.0-rc.1" "ver-pre (^1.2.0-alpha)"
Test-SemVerCase "ver-zero"   "0.1.1" "ver-zero (^0.1.0)"
Test-SemVerCase "ver-exact"  "1.0.0" "ver-exact (=1.0.0)"

# ===========================================================================
# CLEANUP
# ===========================================================================
Write-Host "`n--- Final Cleanup ---"
$cleanupNames = @(
    "chain-a", "chain-b", "chain-c", "chain-fail",
    "state-breaker", "fail-chain", "helper",
    "pivot-v1", "pivot-v2", "priority-base", "priority-max",
    "env-pro", "hook-manifest", "hook-deep",
    "paybox", "moonpay"
)
foreach ($n in $cleanupNames) { Clean-Package $n }
if (Test-Path $hookLog) { Remove-Item $hookLog -Force -ErrorAction SilentlyContinue }

# ===========================================================================
Write-Host "`n=============================================="
Write-Host " RESULT: $script:Pass passed, $script:Fail failed"
Write-Host "=============================================="
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
