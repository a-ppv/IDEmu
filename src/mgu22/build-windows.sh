#!/usr/bin/env bash
# Compila as peças do iDrive 8 no Windows (shell MINGW64 do MSYS2): o equivalente de build.sh (zsh, macOS).
#   guest : aarch64 (glibc do firmware) com clang + ld.lld -> <saida>/libcod.so.0, libEGL.so.1, idemuwl, idemuinput, ... (idênticos aos do macOS)
#   host  : bin/mguhost.exe (renderizador no ANGLE/D3D11) com o gcc do MinGW-w64; o qemushm.dylib do macOS não se aplica (ver src/qemu/hostmem-winshm.c)
# Uso:  build-windows.sh <sysroot> <saida>   guest + mguhost.exe     (chamado por tools/mgu/build_image.py no Windows)
#       build-windows.sh host                só bin/mguhost.exe       (windows/build-native.sh)
# Pacotes: pacman -S --needed mingw-w64-x86_64-{toolchain,clang,lld,python}
# Variáveis: PYTHON (padrão python3), CLANG, LLD, CC.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT=$(cd ../.. && pwd)
mp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }   # caminho no estilo C:/pasta, que o bash e as ferramentas nativas entendem
PY=${PYTHON:-python3}
command -v "$PY" >/dev/null 2>&1 || PY=python

build_host() {
  local out=${1:-$ROOT/bin/mguhost.exe}
  mkdir -p "$(dirname "$out")"
  # -mssse3: o cópia RGBA->RGB usa pshufb (qualquer x86-64 depois de 2006); -static: sem depender de libwinpthread-1.dll ao lado do .exe
  "${CC:-gcc}" -O2 -w -mssse3 -D__USE_MINGW_ANSI_STDIO=1 -D_WIN32_WINNT=0x0A00 mguhost.c -o "$out" -static -pthread -lws2_32 -lwinmm
  ls -l "$out"
}

if [[ ${1:-} == host ]]; then
  build_host "${2:-}"
  exit 0
fi

[[ $# -ge 2 ]] || { echo "uso: build-windows.sh <sysroot> <saida>  |  build-windows.sh host" >&2; exit 2; }
SYS=$(mp "$1"); OUT=$(mp "$2"); mkdir -p "$OUT"
CLANG=${CLANG:-clang}
LLD=${LLD:-ld.lld}
command -v "$CLANG" >/dev/null 2>&1 || { echo "ERRO: clang não encontrado (pacman -S mingw-w64-x86_64-clang)" >&2; exit 1; }
command -v "$LLD" >/dev/null 2>&1 || { echo "ERRO: ld.lld não encontrado (pacman -S mingw-w64-x86_64-lld)" >&2; exit 1; }
# o ld.lld do MSYS2 só liga PE/COFF ("unknown argument: -z"); o guest é ELF aarch64. Sem um lld com ELF, usa o `zig ld.lld` (Zig: https://ziglang.org/download/, extraído em C:\zig ou ~/zig, ou ZIG=caminho)
LLD_PROBE=$("$LLD" -z noexecstack 2>&1 </dev/null || true)       # (sem pipe para o grep: com pipefail o SIGPIPE do grep -q derrubaria o teste)
if [[ $LLD_PROBE == *"unknown argument"* ]]; then
  ZIG=${ZIG:-$(command -v zig 2>/dev/null || ls /c/zig/*/zig.exe "$HOME"/zig/*/zig.exe 2>/dev/null | head -n 1 || true)}
  [[ -n ${ZIG:-} && -x $ZIG ]] || { echo "ERRO: o ld.lld do MSYS2 não liga ELF e o Zig não foi encontrado: baixe https://ziglang.org/download/ (zig-x86_64-windows) e extraia em C:\\zig (ou defina ZIG)" >&2; exit 1; }
  printf '#!/usr/bin/env bash\nexec "%s" ld.lld "$@"\n' "$ZIG" > "$OUT/ld.lld.zig"; chmod +x "$OUT/ld.lld.zig"; LLD="$OUT/ld.lld.zig"
fi
CF=(-target aarch64-linux-gnu -ffreestanding -fPIC -O2 -fno-stack-protector -fno-builtin-malloc -Wno-everything)
LD=("$LLD" -shared -z noexecstack --hash-style=gnu)
EX=("$LLD" --dynamic-linker=/lib/ld-linux-aarch64.so.1 -z noexecstack --hash-style=gnu --unresolved-symbols=ignore-in-shared-libs)
L=(-L"$SYS/lib" -L"$SYS/usr/lib")
cc() { "$CLANG" "${CF[@]}" "$@"; }
"$PY" gen.py
cc -c libcod.c -o "$OUT/libcod.o"
"${LD[@]}" -soname libcod.so.0 -o "$OUT/libcod.so.0" "$OUT/libcod.o" "${L[@]}" -l:libc.so.6
cc -c crt.c -o "$OUT/crt.o"
cc -c ustk.c -o "$OUT/ustk.o"
"${EX[@]}" -o "$OUT/ustk" "$OUT/crt.o" "$OUT/ustk.o" "${L[@]}" -l:libc.so.6
cc -c guest_egl.c -o "$OUT/guest_egl.o"
"${LD[@]}" -soname libEGL.so.1 -o "$OUT/libEGL.so.1" "$OUT/guest_egl.o" "${L[@]}" -l:libc.so.6 -l:libwayland-client.so.0
echo 'int idemu_gles_stub;' > "$OUT/empty.c"; cc -c "$OUT/empty.c" -o "$OUT/empty.o"
"${LD[@]}" -soname libGLESv2.so.2 -o "$OUT/libGLESv2.so.2" "$OUT/empty.o" -L"$OUT" -l:libEGL.so.1
cc -c idemuinput.c -o "$OUT/idemuinput.o"
"${EX[@]}" -o "$OUT/idemuinput" "$OUT/crt.o" "$OUT/idemuinput.o" "${L[@]}" -l:libc.so.6
cc -c idemuusb.c -o "$OUT/idemuusb.o"
"${EX[@]}" -o "$OUT/idemuusb" "$OUT/crt.o" "$OUT/idemuusb.o" "${L[@]}" -l:libc.so.6 -l:libdbus-1.so.3
cc -c usbfake/libusb_fake.c -o "$OUT/libusb_fake.o"
"${LD[@]}" -soname libusb-1.0.so.0 -o "$OUT/libusb-1.0.so.0" "$OUT/libusb_fake.o" "${L[@]}" -l:libc.so.6
cc -c usbfake/libudev_fake.c -o "$OUT/libudev_fake.o"
"${LD[@]}" -soname libudev.so.1 --version-script=usbfake/libudev.map -o "$OUT/libudev.so.1" "$OUT/libudev_fake.o" "${L[@]}" -l:libc.so.6
cc -c hmihook.c -o "$OUT/hmihook.o"
"${LD[@]}" -soname libidemuhmi.so -o "$OUT/libidemuhmi.so" "$OUT/hmihook.o" "${L[@]}" -l:libc.so.6
cc -c idemuwl.c -o "$OUT/idemuwl.o"
"${EX[@]}" -o "$OUT/idemuwl" "$OUT/crt.o" "$OUT/idemuwl.o" "${L[@]}" -l:libc.so.6 -l:libwayland-server.so.0 -l:libivi-application.so.1 -l:libivi-controller.so.1
# o renderizador do host (x86-64): sem gcc instalado, só avisa (dá para compilar depois com `build-windows.sh host`)
if command -v "${CC:-gcc}" >/dev/null 2>&1; then
  build_host
else
  echo "AVISO: gcc não encontrado: bin/mguhost.exe não foi compilado (pacman -S mingw-w64-x86_64-toolchain; bash src/mgu22/build-windows.sh host)" >&2
fi
