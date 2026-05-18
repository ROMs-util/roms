# resolver.ps1 - Recursive Dependency Resolution Logic

$script:ResolutionStack = @()

function Get-RomsDependencyList {
    param(
        [Parameter(Mandatory=$true)]
        $Dependencies,
        
        [Parameter(Mandatory=$false)]
        [string[]]$ResolutionStack = @(),
        
        [Parameter(Mandatory=$false)]
        [string[]]$CollectedList = @()
    )

    # 1. Normalize Dependencies to an array of names
    $depNames = @()
    if ($Dependencies -is [System.Array]) {
        $depNames = $Dependencies
    } elseif ($Dependencies.roms -is [System.Array]) {
        $depNames = $Dependencies.roms
    }

    if ($depNames.Count -eq 0) {
        return $CollectedList
    }

    foreach ($depName in $depNames) {
        # 2. Check if already installed (Industrial Strength: .NET Rule)
        $metaPath = [System.IO.Path]::Combine($global:METADATA_DIR, "$depName.json")
        if ([System.IO.File]::Exists($metaPath)) {
            continue
        }

        # 3. Detect Circular Dependencies
        if ($ResolutionStack -contains $depName) {
            $path = ($ResolutionStack + $depName) -join " -> "
            Write-Log "CIRCULAR DEPENDENCY DETECTED: $path" "ERROR"
            throw "Abort: Circular dependency chain found."
        }

        # 4. Skip if already collected for this run
        if ($CollectedList -contains $depName) {
            continue
        }

        # 5. Discover Sub-Dependencies (Recursion)
        $subDeps = $null
        $cacheFiles = Get-ChildItem -Path $global:CACHE_DIR -Filter "*.index.json"
        foreach ($f in $cacheFiles) {
            $data = Get-Content $f.FullName | ConvertFrom-Json
            $pkg = $data | Where-Object { $_.name -eq $depName } | Select-Object -First 1
            if ($pkg -and $pkg.dependencies) {
                $subDeps = $pkg.dependencies
                break
            }
        }

        if ($subDeps) {
            $CollectedList = Get-RomsDependencyList -Dependencies $subDeps -ResolutionStack ($ResolutionStack + $depName) -CollectedList $CollectedList
        }

        if (!($CollectedList -contains $depName)) {
            $CollectedList += $depName
        }
    }

    return $CollectedList
}
