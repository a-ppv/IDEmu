#!/usr/bin/env bash
# Compila o QEMU 11.1.2 x86-64 do IDEmu (iDrive 7) para Windows NATIVO, no shell MINGW64 do MSYS2: o QEMU oficial mais o dispositivo `idemu-shm`
# (memória compartilhada guest <-> glhost7, versão Windows: mapeamento nomeado + memory_region_init_ram_ptr) e a correção de migração do `sdhci-pci`.
# Resultado: bin/qemu-system-x86_64.exe + bin/qemu-share/ (BIOS, VGA, linuxboot: o IDEmu passa `-L bin/qemu-share`) + as DLLs do MinGW em bin/.
#
# Uso: tools/qemu/build-x86-windows.sh [qemu-11.1.2.tar.xz]       (sem argumento, baixa de https://download.qemu.org para ~/idemu-qemu)
#   QEMU_BUILD_DIR   pasta de trabalho (padrão ~/idemu-qemu); a árvore do x86 fica em <pasta>/x86-src, separada da do ARM (omap5) para um não afetar o outro
#   QEMU_JOBS        compilações em paralelo (padrão: nproc)
#   IDEMU_X86_WHPX   0 = não liga o WHPX; padrão: liga se os cabeçalhos do mingw-w64 o permitirem (aceleração do Windows Hypervisor Platform; só usada com IDEMU_MGU7_ACCEL=whpx)
#   IDEMU_X86_IMG=1  também compila qemu-img.exe (precisa para o boot rápido do iDrive 7, que no Windows vem desligado); só vale na primeira configuração
# Pacotes do MSYS2 (windows/build-native.sh deps instala): mingw-w64-x86_64-{toolchain,ninja,pkgconf,python,glib2,pixman} + base-devel curl tar xz.
set -euo pipefail
[[ ${MSYSTEM:-} == MINGW64 ]] || { echo "ERRO: rode no shell 'MSYS2 MINGW64'." >&2; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
W=${QEMU_BUILD_DIR:-$HOME/idemu-qemu}
VER=11.1.2
TAR=${1:-$W/qemu-$VER.tar.xz}
SRC=$W/x86-src/qemu-$VER
BUILD=$W/build-x86-win
PY=${PYTHON:-python}
mkdir -p "$W" "$W/x86-src" "$ROOT/bin"

if [[ ! -f $TAR ]]; then
  curl -fL --retry 5 --connect-timeout 30 "https://download.qemu.org/qemu-$VER.tar.xz" -o "$TAR.tmp"
  mv "$TAR.tmp" "$TAR"
fi
[[ -f $SRC/configure ]] || { tar -C "$W/x86-src" --exclude='*/roms' --exclude='*/tests/lcitool' --exclude='*/tests/docker' -xf "$TAR" || [[ -f $SRC/configure ]]; }   # sem symlink no Windows
cp "$ROOT/tools/qemu/symlink-install-tree-win.py" "$SRC/scripts/symlink-install-tree.py"   # sem symlink no Windows: o qemu-bundle não é usado

cp "$ROOT/src/qemu/idemu-shm.c" "$SRC/hw/misc/idemu-shm.c"
cp "$ROOT/src/qemu/sdhci-pci.c" "$SRC/hw/sd/sdhci-pci.c"
# registra o dispositivo no Kconfig e no meson de hw/misc (newline='': o Python do Windows trocaria LF por CRLF)
if ! grep -q IDEMU_SHM "$SRC/hw/misc/Kconfig"; then
  "$PY" - "$(cygpath -m "$SRC")" <<'PYEOF'
import sys
s = sys.argv[1]
def edit(p, old, new):
    t = open(p, newline='', encoding='utf-8').read()
    assert old in t, 'trecho não encontrado em ' + p
    open(p, 'w', newline='', encoding='utf-8').write(t.replace(old, new, 1))
edit(s + '/hw/misc/Kconfig', 'config PCI_TESTDEV\n', 'config IDEMU_SHM\n    bool\n    default y if PCI_DEVICES\n    depends on PCI\n\nconfig PCI_TESTDEV\n')
edit(s + '/hw/misc/meson.build', "system_ss.add(when: 'CONFIG_PCI_TESTDEV'", "system_ss.add(when: 'CONFIG_IDEMU_SHM', if_true: files('idemu-shm.c'))\nsystem_ss.add(when: 'CONFIG_PCI_TESTDEV'")
PYEOF
fi

mkdir -p "$BUILD"
cd "$BUILD"
if [[ ! -f build.ninja ]]; then
  OPTS=(--target-list=x86_64-softmmu --without-default-features --enable-tcg --disable-docs --disable-werror --disable-guest-agent
        --disable-rust --disable-user --disable-linux-user --disable-bsd-user)
  if [[ ${IDEMU_X86_IMG:-0} == 1 ]]; then OPTS+=(--enable-tools); else OPTS+=(--disable-tools); fi
  if [[ ${IDEMU_X86_WHPX:-auto} != 0 ]]; then
    # WHPX só se os cabeçalhos do mingw-w64 trouxerem a API (senão o configure falharia com --enable-whpx)
    if printf '#include <windows.h>\n#include <winhvplatform.h>\n#include <winhvemulation.h>\nint main(void){return 0;}\n' | gcc -x c -fsyntax-only - 2>/dev/null; then
      OPTS+=(--enable-whpx); echo "[..] WHPX habilitado no QEMU (use IDEMU_MGU7_ACCEL=whpx para experimentar)"
    else
      echo "[aviso] cabeçalhos do WHPX (winhvplatform.h/winhvemulation.h) ausentes: QEMU só com TCG"
    fi
  fi
  "$SRC/configure" "${OPTS[@]}"
fi
TARGETS=(qemu-system-x86_64.exe)
[[ ${IDEMU_X86_IMG:-0} == 1 ]] && TARGETS+=(qemu-img.exe)
ninja -j"${QEMU_JOBS:-$(nproc)}" "${TARGETS[@]}"

# um .exe em uso não pode ser sobrescrito: copia para um nome novo e troca (falha com uma mensagem clara se o IDEmu ainda estiver rodando)
for exe in "${TARGETS[@]}"; do
  cp "$BUILD/$exe" "$ROOT/bin/$exe.new"
  mv -f "$ROOT/bin/$exe.new" "$ROOT/bin/$exe" || { echo "ERRO: feche o IDEmu (bin/$exe está em uso) e rode de novo." >&2; exit 1; }
done
# firmware que o QEMU próprio procura em bin/qemu-share (o IDEmu passa -L)
mkdir -p "$ROOT/bin/qemu-share"
for f in bios-256k.bin vgabios-stdvga.bin linuxboot_dma.bin kvmvapic.bin; do
  [[ -f $SRC/pc-bios/$f ]] || { echo "ERRO: $SRC/pc-bios/$f não existe no tarball" >&2; exit 1; }
  cp "$SRC/pc-bios/$f" "$ROOT/bin/qemu-share/"
done
# DLLs do MinGW de que os .exe dependem (opengl32.dll e as do Windows ficam de fora)
for exe in "${TARGETS[@]}"; do
  ldd "$ROOT/bin/$exe" | awk '/\/mingw64\//{print $3}' | sort -u | while read -r d; do cp -u "$d" "$ROOT/bin/"; done
done
out=$("$ROOT/bin/qemu-system-x86_64.exe" -device help 2>&1 || true)
if grep -q idemu-shm <<<"$out"; then echo "ok: bin/qemu-system-x86_64.exe com o dispositivo idemu-shm"
else echo "ERRO: o QEMU compilou, mas não lista o dispositivo idemu-shm" >&2; exit 1; fi
"$ROOT/bin/qemu-system-x86_64.exe" -accel help 2>&1 || true
