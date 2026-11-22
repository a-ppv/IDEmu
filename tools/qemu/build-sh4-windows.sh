#!/usr/bin/env bash
# Compila o QEMU 11.1.2 com a placa "cic" do IDEmu (CIC High, SH7785 / QNX 6.3) para Windows NATIVO (qemu-system-sh4.exe), no shell MINGW64 do MSYS2.
# Mesmo molde do build-arm-windows.sh: baixa o fonte oficial (o tarball é reaproveitado) para ~/idemu-qemu (QEMU_BUILD_DIR muda), mas extrai numa
# árvore PRÓPRIA do SH-4 (sh4-src/), porque os patches do CIC mexem em arquivos comuns (accel/tcg, pflash) que o qemu-system-arm.exe não deve herdar.
# Os patches são os de src/cic/build.sh (o mesmo script do macOS/Linux; no MSYS2 ele detecta o Windows e gera o .exe).
# Normalmente chamado por windows/build-native.sh (que instala os pacotes do MSYS2 antes). Precisa de python (3.10+), ninja, glib2, pixman, make, gcc.
set -euo pipefail
[[ ${MSYSTEM:-} == MINGW64 ]] || { echo "ERRO: rode no shell 'MSYS2 MINGW64' (ou via windows/Build.ps1)." >&2; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
W=${QEMU_BUILD_DIR:-$HOME/idemu-qemu}
VER=11.1.2
TAR=$W/qemu-$VER.tar.xz
SRCDIR=$W/sh4-src
SRC=$SRCDIR/qemu-$VER
BUILD=$W/build-sh4-win
mkdir -p "$W" "$SRCDIR"
if [[ ! -f $TAR ]]; then
  curl -fL --retry 5 --connect-timeout 30 "https://download.qemu.org/qemu-$VER.tar.xz" -o "$TAR.tmp"
  mv "$TAR.tmp" "$TAR"
fi
[[ -f $SRC/configure ]] || { tar -C "$SRCDIR" --exclude='*/roms' --exclude='*/tests/lcitool' --exclude='*/tests/docker' -xf "$TAR" || [[ -f $SRC/configure ]]; }   # sem symlink no Windows: roms/ e lcitool/ (fora do build) ficam de fora
cp "$ROOT/tools/qemu/symlink-install-tree-win.py" "$SRC/scripts/symlink-install-tree.py"   # sem symlink no Windows: o qemu-bundle não é usado
# patches do CIC (placa, hypercall, MMU do SH-4A, flash S29GL...) antes do configure, para que o meson/Kconfig já os enxerguem
CIC_QEMU=$SRC CIC_BUILD=$BUILD CIC_PATCH_ONLY=1 bash "$ROOT/src/cic/build.sh"
mkdir -p "$BUILD"
cd "$BUILD"
if [[ ! -f build.ninja ]]; then
  "$SRC/configure" \
    --target-list=sh4-softmmu \
    --without-default-features \
    --enable-tcg \
    --disable-docs \
    --disable-werror \
    --disable-tools \
    --disable-guest-agent \
    --disable-rust \
    --disable-install-blobs
fi
# build.sh (re)aplica os patches (idempotente), roda `ninja qemu-system-sh4.exe` e copia para bin/
CIC_QEMU=$SRC CIC_BUILD=$BUILD bash "$ROOT/src/cic/build.sh"
mkdir -p "$ROOT/bin"
cp "$BUILD/qemu-system-sh4.exe" "$ROOT/bin/qemu-system-sh4.exe.new"
mv -f "$ROOT/bin/qemu-system-sh4.exe.new" "$ROOT/bin/qemu-system-sh4.exe"
"$ROOT/bin/qemu-system-sh4.exe" -machine help | grep -F cic
