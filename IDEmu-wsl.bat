@echo off
rem Abre o IDEmu no Windows VIA WSL2 (alternativa; o launcher normal e IDEmu.bat, nativo). No macOS use IDEmu.command. Detalhes: docs\WINDOWS.md
title IDEmu
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\IDEmu-wsl.ps1" %*
if errorlevel 1 pause
