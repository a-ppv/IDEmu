<#
.SYNOPSIS
  Abre o IDEmu no Windows (versão nativa: Python + qemu-system-arm.exe + glhost.exe, sem WSL).

.DESCRIPTION
  Precisa de bin\qemu-system-arm.exe e bin\glhost.exe (gerados por windows\Build.ps1, ou já presentes num pacote .zip pronto)
  e de um Python 3.10+ (o do pacote em python\, ou o instalado no Windows). Sobe o servidor e abre http://127.0.0.1:8765.
  Feche esta janela (ou Ctrl+C) para encerrar o IDEmu e a VM.

.PARAMETER Port        Porta da interface. Padrão 8765.
.PARAMETER FastBoot    Liga o boot rápido (snapshot). Ainda NÃO validado no Windows: por padrão fica desligado (boot completo, ~25-45 s).
.PARAMETER NoBrowser   Não abre o navegador.
.PARAMETER ShowWindow  Mostra a janela do renderizador (diagnóstico).
#>
[CmdletBinding()]
param(
  [int]$Port = 8765,
  [switch]$FastBoot,
  [switch]$NoBrowser,
  [switch]$ShowWindow
)
$ErrorActionPreference = 'Continue'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
function Say($m)  { Write-Host "[IDEmu] $m" -ForegroundColor Cyan }
function Die($m)  { Write-Host "[IDEmu] ERRO: $m" -ForegroundColor Red; Read-Host 'Enter para fechar' | Out-Null; exit 1 }

# ---- Python -------------------------------------------------------------------------------------------------------------
$py = $null
$pkgPy = Join-Path $Repo 'python\python.exe'
if (Test-Path $pkgPy) { $py = $pkgPy }
else {
  foreach ($c in @('py', 'python', 'python3')) {
    $cmd = Get-Command $c -ErrorAction SilentlyContinue
    if (-not $cmd) { continue }
    if ($cmd.Source -like '*\WindowsApps\*') { continue }       # o atalho da Microsoft Store (abre a loja em vez de rodar)
    $v = if ($c -eq 'py') { & $cmd.Source -3 -c 'import sys;print(sys.version_info[:2]>=(3,10))' 2>$null } else { & $cmd.Source -c 'import sys;print(sys.version_info[:2]>=(3,10))' 2>$null }
    if ("$v".Trim() -eq 'True') { $py = $cmd.Source; $pyArgs = if ($c -eq 'py') { @('-3') } else { @() }; break }
  }
}
if (-not $py) { Die 'Python 3.10 ou mais novo não encontrado. Instale com:  winget install Python.Python.3.12   (marque "Add to PATH") ou use o pacote .zip pronto, que já traz o Python.' }
if (-not $pyArgs) { $pyArgs = @() }

# ---- binários ------------------------------------------------------------------------------------------------------------
$qemu = Join-Path $Repo 'bin\qemu-system-arm.exe'; $glh = Join-Path $Repo 'bin\glhost.exe'
if (-not (Test-Path $qemu) -or -not (Test-Path $glh)) {
  Write-Host '[IDEmu] bin\qemu-system-arm.exe e/ou bin\glhost.exe não existem: é preciso compilar uma vez.' -ForegroundColor Yellow
  Write-Host '        Rode:  powershell -ExecutionPolicy Bypass -File windows\Build.ps1' -ForegroundColor Yellow
  Die 'binários nativos ausentes.'
}

# ---- servidor -------------------------------------------------------------------------------------------------------------
$url = "http://127.0.0.1:$Port/"
function ServerUp { try { $r = Invoke-WebRequest -Uri ($url + 'api/state') -UseBasicParsing -TimeoutSec 2; return $r.StatusCode -eq 200 } catch { return $false } }
if (ServerUp) { Say "O IDEmu já está rodando em $url"; if (-not $NoBrowser) { Start-Process $url }; exit 0 }

$env:PYTHONUTF8 = '1'
$env:PATH = (Join-Path $Repo 'bin') + ';' + $env:PATH          # DLLs do MinGW ao lado dos .exe
if ($FastBoot) { $env:IDEMU_FASTBOOT = '1' }
if ($ShowWindow) { $env:IDEMU_SHOW_WINDOW = '1' }
Say "Iniciando o servidor ($py)..."
$argl = @($pyArgs) + @('-X', 'utf8', '-m', 'idemu', 'gui', '--no-browser', '--port', "$Port")
$p = Start-Process -FilePath $py -ArgumentList $argl -WorkingDirectory $Repo -NoNewWindow -PassThru
try {
  $ok = $false
  for ($i = 0; $i -lt 60; $i++) {
    if ($p.HasExited) { break }
    if (ServerUp) { $ok = $true; break }
    Start-Sleep -Milliseconds 500
  }
  if (-not $ok) { Die 'o servidor do IDEmu não respondeu (veja as mensagens acima).' }
  Say "IDEmu pronto em $url   (feche esta janela ou Ctrl+C para encerrar)"
  if (-not $NoBrowser) { Start-Process $url }
  $p.WaitForExit()
}
finally {
  if ($p -and -not $p.HasExited) {
    Say 'Encerrando o IDEmu e a VM...'
    try { $p.Kill() } catch { }                    # o servidor guarda QEMU/glhost num "job object": morrem junto com ele
    Get-Process -Name 'qemu-system-arm', 'glhost' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Repo\bin\*" } | Stop-Process -Force -ErrorAction SilentlyContinue
  }
}
