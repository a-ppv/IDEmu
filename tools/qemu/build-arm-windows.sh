#!/usr/bin/env bash
# Compila o QEMU 11.1.2 com a placa omap5-uevm do IDEmu para Windows NATIVO (qemu-system-arm.exe), no shell MINGW64 do MSYS2.
# Não mexe em nenhum QEMU instalado: baixa o fonte oficial para ~/idemu-qemu (QEMU_BUILD_DIR muda) e compila num diretório à parte.
# Normalmente chamado por windows/build-native.sh (que instala os pacotes do MSYS2 antes).
set -euo pipefail
[[ ${MSYSTEM:-} == MINGW64 ]] || { echo "ERRO: rode no shell 'MSYS2 MINGW64' (ou via windows/Build.ps1)." >&2; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
W=${QEMU_BUILD_DIR:-$HOME/idemu-qemu}
VER=11.1.2
TAR=$W/qemu-$VER.tar.xz
SRC=$W/qemu-$VER
BUILD=$W/build-arm-win
mkdir -p "$W"
if [[ ! -f $TAR ]]; then
  curl -fL --retry 5 --connect-timeout 30 "https://download.qemu.org/qemu-$VER.tar.xz" -o "$TAR.tmp"
  mv "$TAR.tmp" "$TAR"
fi
[[ -f $SRC/configure ]] || { tar -C "$W" --exclude='*/roms' --exclude='*/tests/lcitool' --exclude='*/tests/docker' -xf "$TAR" || [[ -f $SRC/configure ]]; }   # sem symlink no Windows
cp "$ROOT/tools/qemu/symlink-install-tree-win.py" "$SRC/scripts/symlink-install-tree.py"   # sem symlink no Windows: o qemu-bundle não é usado
cp "$ROOT/src/qemu/omap5-uevm.c" "$SRC/hw/arm/omap5-uevm.c"
if ! grep -q 'config OMAP5_UEVM' "$SRC/hw/arm/Kconfig"; then
  patch -d "$SRC" -p1 < "$ROOT/src/qemu/qemu-v11.1.2-idemu.patch"
fi
mkdir -p "$BUILD"
cd "$BUILD"
if [[ ! -f build.ninja ]]; then
  "$SRC/configure" \
    --target-list=arm-softmmu \
    --without-default-features \
    --enable-tcg \
    --disable-docs \
    --disable-werror \
    --disable-tools \
    --disable-guest-agent \
    --disable-rust \
    --disable-install-blobs
fi
ninja -j"${QEMU_JOBS:-$(nproc)}" qemu-system-arm.exe
mkdir -p "$ROOT/bin"
cp "$BUILD/qemu-system-arm.exe" "$ROOT/bin/qemu-system-arm.exe.new"
mv -f "$ROOT/bin/qemu-system-arm.exe.new" "$ROOT/bin/qemu-system-arm.exe"
"$ROOT/bin/qemu-system-arm.exe" -machine help | grep -F omap5-uevm
