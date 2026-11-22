<#
.SYNOPSIS
  Gera dist\IDEmu-windows-x64.zip: o IDEmu nativo pronto para usar (Python embutido + bin\*.exe + DLLs), sem instalar nada.

.DESCRIPTION
  Roda DEPOIS de windows\Build.ps1 (precisa de bin\qemu-system-arm.exe e bin\glhost.exe). Baixa o Python embutido de python.org.
  O pacote NÃO inclui firmware da BMW nem imagens: cada pessoa usa os seus pacotes SWFL (veja NOTICE).

.PARAMETER PythonVersion  Versão do Python embutido (3.10 a 3.13). Padrão 3.12.8.
#>
[CmdletBinding()]
param([string]$PythonVersion = '3.12.8')
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
function Say($m) { Write-Host "[IDEmu] $m" -ForegroundColor Cyan }
foreach ($f in 'bin\qemu-system-arm.exe', 'bin\glhost.exe') { if (-not (Test-Path (Join-Path $Repo $f))) { throw "falta ${f}: rode windows\Build.ps1 antes." } }

$dist = Join-Path $Repo 'dist'; $name = 'IDEmu-windows-x64'; $stage = Join-Path $dist $name
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null

Say 'Copiando o IDEmu...'
$xd = @('__pycache__', 'phone')               # idemu\data\phone: certificado gerado em uso
& robocopy (Join-Path $Repo 'idemu') (Join-Path $stage 'idemu') /E /XD $xd /XF *.pyc /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw 'robocopy falhou ao copiar idemu' }
& robocopy (Join-Path $Repo 'bin') (Join-Path $stage 'bin') /E /XF *.new /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw 'robocopy falhou ao copiar bin' }
New-Item -ItemType Directory -Force (Join-Path $stage 'windows'), (Join-Path $stage 'docs') | Out-Null
Copy-Item (Join-Path $Repo 'windows\IDEmu.ps1') (Join-Path $stage 'windows\')
Copy-Item (Join-Path $Repo 'IDEmu.bat') $stage
foreach ($f in 'LICENSE', 'NOTICE', 'README.md', 'README.pt-BR.md') { if (Test-Path (Join-Path $Repo $f)) { Copy-Item (Join-Path $Repo $f) $stage } }
foreach ($f in 'WINDOWS.md', 'LINUX.md', 'ARQUITETURA.md') { if (Test-Path (Join-Path $Repo "docs\$f")) { Copy-Item (Join-Path $Repo "docs\$f") (Join-Path $stage 'docs') } }

$pyDir = Join-Path $stage 'python'
$zip = Join-Path $dist "python-$PythonVersion-embed-amd64.zip"
if (-not (Test-Path $zip)) {
  Say "Baixando o Python $PythonVersion embutido..."
  Invoke-WebRequest -Uri "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip" -OutFile $zip -UseBasicParsing
}
Expand-Archive -Path $zip -DestinationPath $pyDir -Force
$pth = Get-ChildItem $pyDir -Filter 'python*._pth' | Select-Object -First 1
if (-not $pth) { throw 'python*._pth não encontrado no Python embutido' }
# com o _pth o Python ignora o diretório atual: acrescenta a raiz do IDEmu (a pasta acima de python\) para `-m idemu` achar o pacote
$lines = @(Get-Content $pth.FullName | Where-Object { $_ -notmatch '^\s*\.\.\s*$' })
$lines += '..'
Set-Content -Path $pth.FullName -Value $lines -Encoding ASCII

$out = Join-Path $dist "$name.zip"
if (Test-Path $out) { Remove-Item -Force $out }
Say 'Compactando...'
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $out -CompressionLevel Optimal
Say ("Pronto: {0} ({1:N0} MB)" -f $out, ((Get-Item $out).Length / 1MB))
