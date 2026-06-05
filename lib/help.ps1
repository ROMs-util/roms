# help.ps1 - Functional CLI Help and Usage Menus

# ---------------------------------------------
# CLI HELP DISPLAY
# Displays the ROMs package manager command reference in the console.
# Shows all available commands, their syntax, and global flags.
# Output uses Write-Host (not Write-Log) to preserve formatting.
# ---------------------------------------------
function Show-Help {
    Write-Host ""
    Write-Host "----- ROMs-util Package Manager (roms) -----" -ForegroundColor Cyan
    Write-Host "The high-level orchestrator for the ecosystem."
    Write-Host ""
    Write-Host "USAGE:" -ForegroundColor Yellow
    Write-Host "  roms list                    - List all installed packages"
    Write-Host "  roms update                  - Fetch latest package registry"
    Write-Host "  roms search <query>          - Find packages in the registry"
    Write-Host "  roms select <command> [pkg]  - Manually select provider for a command"
    Write-Host "  roms source <cmd> [args]     - Manage registry channels"
    Write-Host "  roms install <path>          - Install a local .rms package"
    Write-Host "  roms uninstall <name>        - Remove an installed package"
    Write-Host "  roms help                    - Show this menu"
    Write-Host ""
    Write-Host "SOURCE COMMANDS:" -ForegroundColor Yellow
    Write-Host "  list                         - Show registered sources and channel status"
    Write-Host "    on <channel>               - Enable a specific channel (e.g., testnet)"
    Write-Host "    off <channel>              - Disable a specific channel"
    Write-Host "    pick <channel>             - Set the preferred global channel"
    Write-Host ""
    Write-Host "GLOBAL FLAGS:" -ForegroundColor Yellow
    Write-Host "  -y, --yes                    - Automatically confirm prompts"
    Write-Host "  -v, --verbose                - Show detailed logs (-v, -vv, -vvv)"
    Write-Host ""
    Write-Host "EXAMPLES:" -ForegroundColor Yellow
    Write-Host "  roms source list"
    Write-Host "  roms source on testnet"
    Write-Host "  roms install git@testnet"
    Write-Host "--------------------------------------------"
    Write-Host ""
}
