#!/usr/bin/env bash
# Windows nativo (shell MINGW64 do MSYS2): compila as peças do iDrive 7.
#   glhost7   bin/glhost7.exe, o renderizador do host (OpenGL 4.1 core por WGL + GLEW). É o passo normal; o guest já vem compilado em idemu/guest7/.
#   guest     binários do guest x86-64 (equivalente do build.sh, que é zsh e usa o clang/lld do Rust): clang + ld.lld do MSYS2 em out/. Precisa da libc do firmware.
#   all       os dois.
# Uso: src/mgu/build-windows.sh [glhost7]
#      src/mgu/build-windows.sh guest <libc-2.27.so do MGU> [--install]   (--install copia o resultado para idemu/guest7/)
#      src/mgu/build-windows.sh all <libc-2.27.so do MGU> [--install]
# Pacotes: mingw-w64-x86_64-{toolchain,glew,pkgconf} (glhost7) e mingw-w64-x86_64-{clang,lld} + python (guest). A libc vem do firmware extraído
# (tools/mgu/har.py; em mgu7/work/root/lib/libc-2.27.so durante o build da imagem) e a libdl-2.27.so é a que está ao lado dela.
set -euo pipefail
[[ ${MSYSTEM:-} == MINGW64 ]] || { echo "ERRO: rode no shell 'MSYS2 MINGW64'." >&2; exit 1; }
cd "$(dirname "${BASH_SOURCE[0]}")"
HERE=$(pwd)
ROOT=$(cd ../.. && pwd)
STEP=${1:-glhost7}; shift || true

build_glhost7() {
  local cc=${CC:-gcc} flags
  flags=$(pkg-config --cflags --libs glew 2>/dev/null || echo "-lglew32")
  mkdir -p "$ROOT/bin"
  # winmm: timeBeginPeriod (Sleep de 1 ms); gdi32/opengl32: WGL; ws2_32: a serial GL em TCP quando o QEMU não tem o idemu-shm
  "$cc" -std=gnu11 -O2 -g -D__USE_MINGW_ANSI_STDIO=1 -Wno-deprecated-declarations -Wno-int-conversion -Wno-pointer-sign \
    -Wno-incompatible-pointer-types -Wno-builtin-declaration-mismatch -Wno-implicit-function-declaration \
    glhost7.c $flags -lopengl32 -lgdi32 -lws2_32 -lwinmm -lm -o "$ROOT/bin/glhost7.exe"
  # DLLs do MinGW de que ele depende (glew32.dll...); opengl32.dll é do Windows
  ldd "$ROOT/bin/glhost7.exe" | awk '/\/mingw64\//{print $3}' | sort -u | while read -r d; do cp -u "$d" "$ROOT/bin/"; done
  ls -l "$ROOT/bin/glhost7.exe"
}

build_guest() {
  local libc=${1:?uso: build-windows.sh guest <libc-2.27.so do MGU> [--install]}; shift || true
  local install=0; [[ ${1:-} == --install ]] && install=1
  [[ -f $libc ]] || { echo "ERRO: $libc não existe" >&2; exit 1; }
  local libdl; libdl=$(dirname "$libc")/libdl-2.27.so
  [[ -f $libdl ]] || { echo "ERRO: $libdl não existe (a libdl do firmware fica ao lado da libc)" >&2; exit 1; }
  command -v clang >/dev/null && command -v ld.lld >/dev/null || { echo "ERRO: pacman -S mingw-w64-x86_64-clang mingw-w64-x86_64-lld" >&2; exit 1; }
  local py=${PYTHON:-python}
  mkdir -p out/lib
  cp "$libc" out/lib/libc.so.6
  cp "$libdl" out/lib/libdl.so.2
  # no zsh `$CF` expande o array; no bash é preciso "${CF[@]}" (senão o clang receberia tudo como UM argumento)
  local CF=(-target x86_64-linux-gnu -ffreestanding -fPIC -O1 -fno-stack-protector -Wno-incompatible-library-redeclaration -Wno-builtin-requires-header -Wno-implicit-function-declaration -Wno-empty-body)
  local LLD=(ld.lld)
  local DYN=(--dynamic-linker /lib/ld-linux-x86-64.so.2)
  # (a ordem dos -L / -l importa: os objetos primeiro, depois as bibliotecas)
  clang "${CF[@]}" -c wlstub.c -o out/wlstub.o
  "${LLD[@]}" -pie -o out/idemu-wl "${DYN[@]}" -e _start out/wlstub.o -Lout/lib -l:libc.so.6
  clang "${CF[@]}" -c idemu_run.c -o out/idemu_run.o
  "${LLD[@]}" -pie -o out/idemu-run "${DYN[@]}" -e _start out/idemu_run.o -Lout/lib -l:libc.so.6
  clang "${CF[@]}" -c lifecycle.c -o out/lifecycle.o
  "${LLD[@]}" -pie -o out/idemu-lifecycle "${DYN[@]}" -e _start out/lifecycle.o -Lout/lib -l:libc.so.6
  "$py" gen_gl.py >/dev/null
  clang "${CF[@]}" -c gles_guest.c -o out/gles_guest.o
  "${LLD[@]}" -shared -soname libGLESv2.so.2 -o out/libGLESv2.so.2 out/gles_guest.o -Lout/lib -l:libc.so.6 -l:libdl.so.2
  echo 'int idemu_egl_stub;' > out/egl_stub.c
  clang "${CF[@]}" -c out/egl_stub.c -o out/egl_stub.o
  "${LLD[@]}" -shared -soname libEGL.so.1 -o out/libEGL.so.1 out/egl_stub.o --no-as-needed -Lout -l:libGLESv2.so.2
  clang "${CF[@]}" -c fakeipc.c -o out/fakeipc.o
  "${LLD[@]}" -shared -soname libipc.so.1 -o out/libipc.so.1 out/fakeipc.o -Lout/lib -l:libc.so.6
  clang "${CF[@]}" -c fakesvc.c -o out/fakesvc.o
  "${LLD[@]}" -pie -o out/idemu-fakesvc "${DYN[@]}" -e _start out/fakesvc.o -Lout/lib -l:libc.so.6
  clang "${CF[@]}" -c fastclock.c -o out/fastclock.o
  "${LLD[@]}" -shared -soname libfastclock.so -o out/libfastclock.so out/fastclock.o
  ls -l out/idemu-wl out/idemu-run out/libGLESv2.so.2 out/libEGL.so.1 out/libipc.so.1 out/idemu-fakesvc out/libfastclock.so
  if [[ $install == 1 ]]; then
    for f in idemu-wl idemu-run libGLESv2.so.2 libEGL.so.1 libipc.so.1 idemu-fakesvc libfastclock.so; do cp "out/$f" "$ROOT/idemu/guest7/$f"; done
    echo "[ok] binários do guest copiados para idemu/guest7/ (a imagem do iDrive 7 é refeita sozinha no próximo uso)"
  fi
}

case $STEP in
  glhost7) build_glhost7 ;;
  guest)   build_guest "$@" ;;
  all)     build_glhost7; build_guest "$@" ;;
  *) echo "passo desconhecido: $STEP (glhost7|guest|all)" >&2; exit 2 ;;
esac
