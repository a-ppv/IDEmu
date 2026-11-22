<#
.SYNOPSIS
  Instala o WSL2 + Ubuntu 24.04 (uma vez), necessário para rodar o IDEmu no Windows.

.DESCRIPTION
  Rode em um PowerShell COMO ADMINISTRADOR. Depois do `wsl --install` o Windows pede para reiniciar; ao voltar,
  abra o "Ubuntu" no menu Iniciar uma vez para criar seu usuário e senha, e então rode IDEmu-wsl.bat.
  Este script não mexe em nada além de instalar o WSL e a distribuição.
#>
$ErrorActionPreference = 'Stop'
function Say($m) { Write-Host "[IDEmu] $m" -ForegroundColor Cyan }

$build = [Environment]::OSVersion.Version.Build
if ($build -lt 19041) { Write-Host "[IDEmu] ERRO: o WSL2 exige Windows 10 versão 2004 (build 19041) ou mais novo; este é o build $build." -ForegroundColor Red; exit 1 }

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$haveDistro = $false
if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
  $prev = [Console]::OutputEncoding
  try { [Console]::OutputEncoding = [System.Text.Encoding]::Unicode; $l = @(& wsl.exe -l 2>$null | ForEach-Object { ("$_" -replace '\s*\(.*\)\s*$', '').Trim() } | Where-Object { $_ -like 'Ubuntu*' }) } finally { [Console]::OutputEncoding = $prev }
  $haveDistro = $l.Count -gt 0
}
if ($haveDistro) {
  Say 'Já existe uma distribuição Ubuntu no WSL. Nada a instalar: rode IDEmu-wsl.bat.'
  exit 0
}

if (-not $admin) {
  Write-Host "[IDEmu] Abra o PowerShell como administrador (botão direito > Executar como administrador) e rode de novo:" -ForegroundColor Yellow
  Write-Host "         powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -ForegroundColor Yellow
  exit 1
}

Say 'Instalando o WSL2 e o Ubuntu 24.04 (precisa de internet; pode pedir para reiniciar)...'
& wsl.exe --install -d Ubuntu-24.04
if ($LASTEXITCODE -ne 0) {
  Write-Host '[IDEmu] O "wsl --install" falhou. Alternativas: habilitar manualmente "Subsistema do Windows para Linux" e "Plataforma de Máquina Virtual" em "Ativar ou desativar recursos do Windows", reiniciar, e instalar o Ubuntu 24.04 pela Microsoft Store.' -ForegroundColor Red
  exit 1
}
Say 'Pronto. Reinicie o Windows se ele pedir, abra o "Ubuntu" uma vez para criar seu usuário/senha, e depois rode IDEmu-wsl.bat.'
