<#
.SYNOPSIS
  Compila o IDEmu para Windows NATIVO: bin\qemu-system-arm.exe (QEMU 11.1.2 + placa OMAP5), bin\glhost.exe e as DLLs.

.DESCRIPTION
  Usa o MSYS2 (toolchain MinGW-w64). Se o MSYS2 não estiver em C:\msys64, instala com winget (-InstallMsys2) ou diz como instalar.
  Leva de 15 a 60 minutos na primeira vez (baixa ~130 MB do QEMU e compila). Nada é instalado fora de C:\msys64.
  Depois de compilar, use IDEmu.bat. Para gerar um .zip pronto para distribuir: windows\Package.ps1.

.PARAMETER Msys2Root     Pasta do MSYS2. Padrão C:\msys64 (ou a variável MSYS2_ROOT).
.PARAMETER InstallMsys2  Instala o MSYS2 com o winget se faltar.
.PARAMETER Step          all (padrão: todas as gerações) | core (só iDrive 5/6) | deps | qemu | glhost | cic | mgu7 | mgu8 | dlls
.PARAMETER Jobs          Compilações em paralelo do QEMU. Padrão: núcleos do PC.
#>
[CmdletBinding()]
param(
  [string]$Msys2Root = $(if ($env:MSYS2_ROOT) { $env:MSYS2_ROOT } else { 'C:\msys64' }),
  [switch]$InstallMsys2,
  [ValidateSet('all', 'core', 'deps', 'qemu', 'glhost', 'cic', 'mgu7', 'mgu8', 'dlls')][string]$Step = 'all',
  [int]$Jobs = [Environment]::ProcessorCount
)
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
function Say($m) { Write-Host "[IDEmu] $m" -ForegroundColor Cyan }

$bash = Join-Path $Msys2Root 'usr\bin\bash.exe'
if (-not (Test-Path $bash)) {
  if ($InstallMsys2) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
      Say 'Instalando o MSYS2 com o winget...'
      & winget install --id MSYS2.MSYS2 -e --accept-package-agreements --accept-source-agreements
    }
    if (-not (Test-Path $bash)) {
      # sem winget (Windows LTSC/IoT, por exemplo): baixa o instalador oficial do MSYS2 (assinado) e instala em silêncio
      Say 'Baixando o instalador oficial do MSYS2...'
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $ProgressPreference = 'SilentlyContinue'
      $inst = Join-Path ([IO.Path]::GetTempPath()) 'msys2-x86_64-latest.exe'
      Invoke-WebRequest -Uri 'https://github.com/msys2/msys2-installer/releases/latest/download/msys2-x86_64-latest.exe' -OutFile $inst -UseBasicParsing
      $sig = Get-AuthenticodeSignature $inst
      if ($sig.Status -ne 'Valid') { throw "assinatura do instalador do MSYS2 inválida ($($sig.Status)): não vou executá-lo. Instale manualmente (https://www.msys2.org)." }
      Say 'Instalando o MSYS2 em silêncio...'
      & $inst in --confirm-command --accept-messages --root $Msys2Root | Out-Host
    }
    if (-not (Test-Path $bash)) { throw "o MSYS2 foi instalado, mas não achei $bash. Passe -Msys2Root com a pasta correta." }
  } else {
    Write-Host "[IDEmu] MSYS2 não encontrado em $Msys2Root." -ForegroundColor Yellow
    Write-Host '        Rode de novo com -InstallMsys2 (usa o winget) ou instale em https://www.msys2.org e use -Msys2Root.' -ForegroundColor Yellow
    exit 1
  }
}

# o caminho do script no formato do MSYS2: C:\a\b -> /c/a/b
$script = [regex]::Replace((Join-Path $Repo 'windows\build-native.sh').Replace('\', '/'), '^([A-Za-z]):', { param($m) '/' + $m.Groups[1].Value.ToLower() })

$env:MSYSTEM = 'MINGW64'
$env:CHERE_INVOKING = '1'
$env:MSYS2_PATH_TYPE = 'minimal'
$env:QEMU_JOBS = "$Jobs"
Say "Compilando ($Step) com o MSYS2 em $Msys2Root ..."
# 1ª vez: o MSYS2 pede para atualizar o núcleo (pacman -Syu) antes de instalar pacotes
if ($Step -in 'all', 'core', 'deps', 'cic', 'mgu7', 'mgu8') {
  & $bash -lc 'pacman -Syu --noconfirm' | Out-Host
}
if ($Step -in 'all', 'mgu8') {
  # o guest do iDrive 8 é ELF aarch64 e o ld.lld do MSYS2 só liga PE/COFF: o src/mgu22/build-windows.sh usa o `zig ld.lld` (Zig em C:\zig)
  $zigRoot = if ($env:ZIG_ROOT) { $env:ZIG_ROOT } else { 'C:\zig' }
  if (-not (Get-Command zig -ErrorAction SilentlyContinue) -and -not (Get-ChildItem $zigRoot -Recurse -Filter zig.exe -ErrorAction SilentlyContinue | Select-Object -First 1)) {
    Say 'Baixando o Zig (o lld dele liga o guest ELF do iDrive 8; ~100 MB)...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $ProgressPreference = 'SilentlyContinue'
    $idx = Invoke-RestMethod 'https://ziglang.org/download/index.json'
    $ver = $idx.PSObject.Properties.Name | Where-Object { $_ -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_ } -Descending | Select-Object -First 1
    $asset = $idx.$ver.'x86_64-windows'
    $zz = Join-Path ([IO.Path]::GetTempPath()) "zig-$ver.zip"
    Invoke-WebRequest -Uri $asset.tarball -OutFile $zz -UseBasicParsing
    if ((Get-FileHash $zz -Algorithm SHA256).Hash.ToLower() -ne $asset.shasum.ToLower()) { throw 'o checksum do Zig não confere: baixe manualmente em https://ziglang.org/download/' }
    New-Item -ItemType Directory -Force $zigRoot | Out-Null
    Expand-Archive $zz -DestinationPath $zigRoot -Force
  }
}
& $bash -l $script $Step
if ($LASTEXITCODE -ne 0) { throw "a compilação falhou (código $LASTEXITCODE). Veja as mensagens acima." }
if ($Step -in 'all', 'core') {
  foreach ($f in 'bin\qemu-system-arm.exe', 'bin\glhost.exe') { if (-not (Test-Path (Join-Path $Repo $f))) { throw "faltou gerar $f" } }
  Say 'Pronto. Abra o IDEmu com IDEmu.bat.'
}
