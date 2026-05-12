# help.ps1 - Functional CLI Help and Usage Menus

function Show-Help {
    Write-Host ""
    Write-Host "----- ROMs-util Package Manager (roms) -----" -ForegroundColor Cyan
    Write-Host "The high-level orchestrator for the ecosystem."
    Write-Host ""
    Write-Host "Usage:"
    Write-Host "  roms list                    - List all installed packages"
    Write-Host "  roms install <path>          - Install a local .rms package"
    Write-Host "  roms uninstall <name>        - Remove an installed package"
    Write-Host "  roms help                    - Show this menu"
    Write-Host ""
    Write-Host "Global Flags:"
    Write-Host "  -y, --yes                    - Automatically confirm prompts"
    Write-Host "  -v, --verbose                - Show detailed operation logs"
    Write-Host "--------------------------------------------"
    Write-Host ""
}
