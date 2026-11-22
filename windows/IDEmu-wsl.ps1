<#
.SYNOPSIS
  Abre o IDEmu no Windows (roda o servidor Linux dentro do WSL2 e abre a interface no seu navegador).

.DESCRIPTION
  Primeira vez: instala o necessário no WSL (Ubuntu) e compila o QEMU/renderizador (10 a 40 min, uma vez só).
  Depois: sincroniza o código, sobe o servidor e abre http://127.0.0.1:8765.
  Feche esta janela (ou Ctrl+C) para encerrar o IDEmu e a VM.

.PARAMETER Distro     Nome da distribuição WSL. Padrão: a primeira "Ubuntu*" instalada.
.PARAMETER Port       Porta da interface. Padrão 8765.
.PARAMETER FastBoot   Liga o boot rápido (snapshot). Ainda NÃO validado no caminho Linux/WSL: por padrão fica desligado.
.PARAMETER Rebuild    Recompila o QEMU e o glhost.
.PARAMETER NoBrowser  Não abre o navegador.
.PARAMETER ShowWindow Não usa o Xvfb: usa o servidor gráfico do WSLg (janela do renderizador visível). Só para diagnóstico.
#>
[CmdletBinding()]
param(
  [string]$Distro,
  [int]$Port = 8765,
  [switch]$FastBoot,
  [switch]$Rebuild,
  [switch]$NoBrowser,
  [switch]$ShowWindow
)
$ErrorActionPreference = 'Continue'     # os executáveis nativos (wsl.exe) escrevem em stderr; o sucesso é checado por $LASTEXITCODE
$Repo =(Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Say($m)  { Write-Host "[IDEmu] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[IDEmu] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[IDEmu] ERRO: $m" -ForegroundColor Red; Read-Host 'Enter para fechar' | Out-Null; exit 1 }

# ---- 1. WSL e distribuição --------------------------------------------------------------------------------------------
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { Die 'wsl.exe não encontrado. Rode windows\Setup-wsl.ps1 (como administrador) para instalar o WSL2.' }
$prevEnc = [Console]::OutputEncoding
try {
  [Console]::OutputEncoding = [System.Text.Encoding]::Unicode          # wsl.exe -l fala UTF-16
  # "wsl -l" (sem -q: o wsl.exe antigo não tem) imprime um cabeçalho traduzido e "Nome (Default)"; só os nomes que começam com Ubuntu interessam
  $list = @(& wsl.exe -l 2>$null | ForEach-Object { ("$_" -replace '\s*\(.*\)\s*$', '').Trim() } | Where-Object { $_ -and $_ -notmatch 'docker-desktop' })
} finally { [Console]::OutputEncoding = $prevEnc }
if (-not $Distro) { $Distro = $list | Where-Object { $_ -like 'Ubuntu*' } | Select-Object -First 1 }
if (-not $Distro) { Die 'Nenhuma distribuição Ubuntu no WSL. Rode windows\Setup-wsl.ps1 (como administrador) e depois abra o Ubuntu uma vez para criar seu usuário.' }

# Atenção: sem aspas duplas dentro dos comandos para o WSL (o PowerShell 5.1 as estraga ao chamar executáveis nativos)
function InWsl([string]$cmd) { & wsl.exe -d $Distro -- bash -lc $cmd }
function InWslOk([string]$cmd) { & wsl.exe -d $Distro -- bash -lc $cmd 2>$null | Out-Null; return ($LASTEXITCODE -eq 0) }

# caminho do repositório visto de dentro do WSL
$repoWsl = "$(& wsl.exe -d $Distro -- wslpath -a ($Repo -replace '\\', '/') 2>$null | Select-Object -First 1)".Trim()
if (-not $repoWsl) { Die "não consegui converter '$Repo' para um caminho do WSL. A distribuição '$Distro' abre?" }

# ---- 2. Primeira vez / recompilar ------------------------------------------------------------------------------------
$tmp = '$HOME/.idemu-wsl-setup.sh'
# copia o script com fins de linha LF (o checkout do Windows pode ter CRLF); \015 = CR
InWsl "tr -d '\015' < '$repoWsl/windows/wsl-setup.sh' > $tmp && chmod +x $tmp" | Out-Null
$built = InWslOk 'test -x $HOME/IDEmu/bin/qemu-system-arm && test -x $HOME/IDEmu/bin/glhost'
if ($Rebuild -or -not $built) {
  Say 'Primeira execução: instalando dependências e compilando no WSL (pede a senha do Ubuntu; leva de 10 a 40 minutos).'
  InWsl "bash $tmp '$repoWsl' all"
  if ($LASTEXITCODE -ne 0) { Die 'a preparação do WSL falhou (veja as mensagens acima).' }
} else {
  InWsl "bash $tmp '$repoWsl' sync"
  if ($LASTEXITCODE -ne 0) { Die 'não consegui sincronizar o código para o WSL.' }
}
# dependências que podem faltar numa instalação antiga (rápido quando já estão)
if (-not (InWslOk 'command -v xvfb-run >/dev/null && command -v python3 >/dev/null')) { Warn 'faltam pacotes no WSL; instalando...'; InWsl "bash $tmp '$repoWsl' deps" }

# ---- 3. Servidor ---------------------------------------------------------------------------------------------------------
$url = "http://127.0.0.1:$Port/"
function ServerUp { try { $r = Invoke-WebRequest -Uri ($url + 'api/state') -UseBasicParsing -TimeoutSec 2; return $r.StatusCode -eq 200 } catch { return $false } }
if (ServerUp) {
  Say "O IDEmu já está rodando em $url"
  if (-not $NoBrowser) { Start-Process $url }
  exit 0
}

$env_ = 'export LIBGL_ALWAYS_SOFTWARE=1; '
if (-not $FastBoot) { $env_ += 'export IDEMU_NO_SNAPSHOT=1; ' }
$run = "cd ~/IDEmu && $env_" + $(if ($ShowWindow) { "exec python3 -m idemu gui --no-browser --port $Port" } else { "exec xvfb-run -a -s '-screen 0 1920x1080x24' python3 -m idemu gui --no-browser --port $Port" })

Say "Iniciando o servidor no WSL ($Distro)..."
# o Start-Process junta os argumentos sem escapar: o comando inteiro vai entre aspas duplas e não contém nenhuma
$p = Start-Process -FilePath 'wsl.exe' -ArgumentList @('-d', $Distro, '--', 'bash', '-lc', "`"$run`"") -NoNewWindow -PassThru
try {
  $ok = $false
  for ($i = 0; $i -lt 120; $i++) {
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
    & wsl.exe -d $Distro -- bash -lc "pkill -TERM -f '^python3 -m idemu gui' || true" 2>$null | Out-Null
    $null = $p.WaitForExit(8000)
    if (-not $p.HasExited) { try { $p.Kill() } catch { } }
  }
}
