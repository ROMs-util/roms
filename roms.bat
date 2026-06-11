@echo off
setlocal enabledelayedexpansion
set "ROMS_RAW_ARGS=!CMDCMDLINE!"
powershell -ExecutionPolicy Bypass -File "%~dp0roms.ps1" %*
endlocal
