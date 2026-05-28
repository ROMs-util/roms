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

    # 1. Normalize Dependencies to an array
    $depIdentifiers = @()
    if ($Dependencies -is [System.Array]) {
        $depIdentifiers = $Dependencies
    } elseif ($Dependencies.packages -is [System.Array]) {
        $depIdentifiers = $Dependencies.packages
    } elseif ($Dependencies.roms -is [System.Array]) {
        $depIdentifiers = $Dependencies.roms
    }

    if ($depIdentifiers.Count -eq 0) {
        return $CollectedList
    }

    foreach ($depIdentifier in $depIdentifiers) {
        # 2. Parse Identifier (e.g., "beta:^1.0.0" or just "beta")
        $parts = $depIdentifier.Split(':')
        $depName = $parts[0]
        $constraint = if ($parts.Count -gt 1) { $parts[1] } else { "*" }

        # 3. Check if already installed
        $metaPath = [System.IO.Path]::Combine($global:METADATA_DIR, "$depName.json")
        if ([System.IO.File]::Exists($metaPath)) {
            continue
        }

        # 4. Detect Circular Dependencies
        if ($ResolutionStack -contains $depName) {
            $path = ($ResolutionStack + $depName) -join " -> "
            Write-Log "CIRCULAR DEPENDENCY DETECTED: $path" "ERROR"
            throw "Abort: Circular dependency chain found."
        }

        # 5. Skip if already collected for this run
        $alreadyCollected = $false
        foreach ($item in $CollectedList) {
            if ($item -eq $depName -or $item.StartsWith("${depName}:")) {
                $alreadyCollected = $true
                break
            }
        }
        if ($alreadyCollected) { continue }

        # 6. Find best satisfying version in registry
        $pkg = Get-RomsRegistryPackage -Name $depName -Constraint $constraint
        if (!$pkg) { throw "Dependency '$depName' (Constraint: $constraint) not found in registry." }

        # 7. Discover Sub-Dependencies (Recursion)
        if ($pkg.dependencies) {
            $CollectedList = Get-RomsDependencyList -Dependencies $pkg.dependencies -ResolutionStack ($ResolutionStack + $depName) -CollectedList $CollectedList
        }

        # 8. Add specific versioned identifier to the list
        $CollectedList += "${depName}:$($pkg.version)"
    }

    return $CollectedList
}
