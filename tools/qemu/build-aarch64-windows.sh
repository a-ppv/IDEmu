#!/usr/bin/env bash
# Compila o QEMU 11.1.2 (aarch64-softmmu, máquina `virt`) para Windows NATIVO com o backend de memória `memory-backend-winshm` do iDrive 8 (MGU22):
# bin/qemu-system-aarch64.exe, no shell MINGW64 do MSYS2. Complementa tools/qemu/build-arm-windows.sh (o do iDrive 5/6, omap5-uevm).
# Não mexe em nenhum QEMU instalado nem no fonte do build do iDrive 5/6: usa a mesma tarball (~/idemu-qemu) mas extrai o fonte numa pasta própria
# (qemu-<versão>-a64), porque este script edita backends/meson.build.
#
# Em x86-64 o guest aarch64 só roda em TCG (emulação pura): muito mais lento que o HVF do Mac. Em Windows on ARM (MSYS2 CLANGARM64) o script liga o WHPX.
set -euo pipefail
case "${MSYSTEM:-}" in MINGW64|CLANGARM64) ;; *) echo "ERRO: rode no shell 'MSYS2 MINGW64' (ou CLANGARM64, em Windows on ARM)." >&2; exit 1;; esac
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
W=${QEMU_BUILD_DIR:-$HOME/idemu-qemu}
VER=11.1.2
TAR=$W/qemu-$VER.tar.xz
SRC=$W/qemu-$VER-a64
BUILD=$W/build-aarch64-win
mkdir -p "$W"
if [[ ! -f $TAR ]]; then
  curl -fL --retry 5 --connect-timeout 30 "https://download.qemu.org/qemu-$VER.tar.xz" -o "$TAR.tmp"
  mv "$TAR.tmp" "$TAR"
fi
if [[ ! -d $SRC ]]; then
  mkdir -p "$SRC.tmp"
  tar -C "$SRC.tmp" --strip-components=1 --exclude='*/roms' --exclude='*/tests/lcitool' --exclude='*/tests/docker' -xf "$TAR" || [[ -f $SRC.tmp/configure ]]
  mv "$SRC.tmp" "$SRC"
fi
cp "$ROOT/tools/qemu/symlink-install-tree-win.py" "$SRC/scripts/symlink-install-tree.py"   # sem symlink no Windows: o qemu-bundle não é usado

# libfdt: a máquina virt monta/lê a árvore de dispositivos (e carrega o -dtb do iDrive 8). O MSYS2 MINGW64 não tem pacote do dtc: usa o libfdt interno do QEMU (baixa o subprojeto dtc)

# o backend novo: copia o fonte e o registra no meson (só no Windows). Idempotente.
cp "$ROOT/src/qemu/hostmem-winshm.c" "$SRC/backends/hostmem-winshm.c"
if ! grep -q 'hostmem-winshm.c' "$SRC/backends/meson.build"; then
  python3 - "$SRC/backends/meson.build" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding='utf-8').read()
if not t.endswith('\n'):
    t += '\n'
t += """
# IDEmu: RAM do guest do iDrive 8 em memória compartilhada nomeada do Windows (src/qemu/hostmem-winshm.c)
if host_machine.system() == 'windows'
  system_ss.add(files('hostmem-winshm.c'))
endif
"""
open(p, 'w', encoding='utf-8', newline='\n').write(t)
PY
fi
grep -q 'hostmem-winshm.c' "$SRC/backends/meson.build" || { echo "ERRO: não consegui registrar hostmem-winshm.c em backends/meson.build" >&2; exit 1; }

# o QEMU interpreta `-object` pelo esquema QAPI (qapi/qom.json): um tipo novo precisa estar lá, senão dá "Parameter 'qom-type' does not accept value". Idempotente.
if ! grep -q 'memory-backend-winshm' "$SRC/qapi/qom.json"; then
  python3 - "$SRC/qapi/qom.json" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding='utf-8').read()
def sub(old, new):
    global t
    assert t.count(old) == 1, old
    t = t.replace(old, new)
sub("""##
# @MemoryBackendEpcProperties:""", """##
# @MemoryBackendWinShmProperties:
#
# Properties for memory-backend-winshm objects (IDEmu: guest RAM in a
# named Windows file mapping).
#
# @shm-name: name of the file mapping (section)
#
# Since: 11.1
##
{ 'struct': 'MemoryBackendWinShmProperties',
  'base': 'MemoryBackendProperties',
  'data': { 'shm-name': 'str' },
  'if': 'CONFIG_WIN32' }

##
# @MemoryBackendEpcProperties:""")
sub("""    { 'name': 'memory-backend-shm',
      'if': 'CONFIG_POSIX' },
""", """    { 'name': 'memory-backend-shm',
      'if': 'CONFIG_POSIX' },
    { 'name': 'memory-backend-winshm',
      'if': 'CONFIG_WIN32' },
""")
sub("""      'memory-backend-shm':         { 'type': 'MemoryBackendShmProperties',
                                      'if': 'CONFIG_POSIX' },
""", """      'memory-backend-shm':         { 'type': 'MemoryBackendShmProperties',
                                      'if': 'CONFIG_POSIX' },
      'memory-backend-winshm':      { 'type': 'MemoryBackendWinShmProperties',
                                      'if': 'CONFIG_WIN32' },
""")
open(p, 'w', encoding='utf-8', newline='\n').write(t)
PY
fi
EXTRA=()
# WHPX do aarch64 só existe quando o próprio QEMU é compilado para ARM64 (Windows on ARM)
[[ ${MSYSTEM_CARCH:-} == aarch64 ]] && EXTRA+=(--enable-whpx)
# a lista que o usuário quiser acrescentar: QEMU_CONFIGURE_EXTRA="--enable-xxx ..."
# shellcheck disable=SC2206
[[ -n ${QEMU_CONFIGURE_EXTRA:-} ]] && EXTRA+=($QEMU_CONFIGURE_EXTRA)

mkdir -p "$BUILD"
cd "$BUILD"
if [[ ! -f build.ninja ]]; then
  "$SRC/configure" \
    --target-list=aarch64-softmmu \
    --without-default-features \
    --enable-tcg \
    --enable-fdt=internal \
    --disable-docs \
    --disable-werror \
    --disable-tools \
    --disable-guest-agent \
    --disable-rust \
    --disable-install-blobs \
    "${EXTRA[@]}"
fi
ninja -j"${QEMU_JOBS:-$(nproc)}" qemu-system-aarch64.exe
mkdir -p "$ROOT/bin"
cp "$BUILD/qemu-system-aarch64.exe" "$ROOT/bin/qemu-system-aarch64.exe.new"
mv -f "$ROOT/bin/qemu-system-aarch64.exe.new" "$ROOT/bin/qemu-system-aarch64.exe"
# as DLLs do MinGW de que ele depende (o mesmo que windows/build-native.sh faz para o qemu-system-arm.exe)
ldd "$ROOT/bin/qemu-system-aarch64.exe" | awk '/\/(mingw64|clangarm64)\//{print $3}' | sort -u | while read -r d; do cp -u "$d" "$ROOT/bin/"; done
"$ROOT/bin/qemu-system-aarch64.exe" -machine help | grep -E '^virt ' | head -n 1
"$ROOT/bin/qemu-system-aarch64.exe" -object help | grep -F memory-backend-winshm || { echo "ERRO: memory-backend-winshm não foi registrado no binário" >&2; exit 1; }
echo "[ok] $ROOT/bin/qemu-system-aarch64.exe"
