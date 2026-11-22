@echo off
rem Abre o IDEmu no Windows (versao nativa, sem WSL). No macOS use IDEmu.command; no Linux, linux/IDEmu.sh.
rem Primeira vez a partir do codigo-fonte: powershell -ExecutionPolicy Bypass -File windows\Build.ps1 -InstallMsys2
rem Detalhes: docs\WINDOWS.md
chcp 65001 >nul
title IDEmu
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\IDEmu.ps1" %*
if errorlevel 1 pause
