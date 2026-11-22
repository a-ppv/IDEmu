#!/usr/bin/env bash
# Compila o IDEmu para Windows NATIVO: bin/qemu-system-arm.exe (QEMU 11.1.2 + omap5-uevm), bin/glhost.exe e as DLLs de que dependem.
# Roda no shell MINGW64 do MSYS2; quem chama é windows/Build.ps1 (não precisa abrir o MSYS2 à mão).
set -euo pipefail
[[ ${MSYSTEM:-} == MINGW64 ]] || { echo "ERRO: precisa do shell MSYS2 MINGW64 (use windows\\Build.ps1)." >&2; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
STEP=${1:-all}

deps() {
  echo "[..] instalando pacotes do MSYS2 (toolchain, clang/lld, glib, pixman, freeglut, glew, libpng, dtc)"
  # o grupo toolchain faz o pacman perguntar a seleção; com --noconfirm e stdin = /dev/null ele escolhe "tudo" (stdin de pipe vazio aborta)
  pacman -S --needed --noconfirm base-devel git curl patch tar xz \
    mingw-w64-x86_64-toolchain mingw-w64-x86_64-ninja mingw-w64-x86_64-pkgconf mingw-w64-x86_64-python \
    mingw-w64-x86_64-glib2 mingw-w64-x86_64-pixman mingw-w64-x86_64-libpng mingw-w64-x86_64-freeglut mingw-w64-x86_64-glew \
    mingw-w64-x86_64-clang mingw-w64-x86_64-lld < /dev/null      # (não há mingw-w64-x86_64-dtc: o QEMU usa o libfdt interno)
}

dlls() {
  # copia para bin/ as DLLs do MinGW que os .exe usam (ldd lista o caminho de cada uma)
  mkdir -p bin
  for exe in bin/qemu-system-arm.exe bin/glhost.exe bin/qemu-system-sh4.exe bin/qemu-system-x86_64.exe bin/glhost7.exe \
             bin/qemu-img.exe bin/qemu-system-aarch64.exe bin/mguhost.exe; do
    [[ -f $exe ]] || continue
    ldd "$exe" | awk '/\/mingw64\//{print $3}' | sort -u | while read -r d; do cp -u "$d" bin/; done
  done
  # opengl32.dll é do Windows (driver da placa de vídeo): nunca copiar o do MinGW/Mesa por cima dele
  echo "[ok] DLLs em bin/: $(ls bin/*.dll 2>/dev/null | wc -l)"
}

core()  { bash src/glhost/build.sh; bash tools/qemu/build-arm-windows.sh; dlls; }          # iDrive 5/6
cic()   { bash tools/qemu/build-sh4-windows.sh; dlls; }                                     # CIC
mgu7()  { bash src/mgu/build-windows.sh glhost7; bash tools/qemu/build-x86-windows.sh; dlls; }   # iDrive 7
mgu8()  { bash tools/qemu/build-aarch64-windows.sh; bash src/mgu22/build-windows.sh host; dlls; }   # iDrive 8

case $STEP in
  deps)   deps ;;
  core)   core ;;
  qemu)   bash tools/qemu/build-arm-windows.sh; dlls ;;
  glhost) bash src/glhost/build.sh; dlls ;;
  cic)    cic ;;
  mgu7)   mgu7 ;;
  mgu8)   mgu8 ;;
  dlls)   dlls ;;
  all)    deps; core; cic; mgu7; mgu8 ;;
  *) echo "passo desconhecido: $STEP (deps|core|qemu|glhost|cic|mgu7|mgu8|dlls|all)" >&2; exit 2 ;;
esac
if [[ $STEP == all || $STEP == core ]]; then
  [[ -f bin/qemu-system-arm.exe && -f bin/glhost.exe ]] || { echo "ERRO: faltou gerar bin/qemu-system-arm.exe ou bin/glhost.exe" >&2; exit 1; }
fi
echo "[ok] passo '$STEP' concluído: $ROOT/bin"
exit 0