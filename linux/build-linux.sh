#!/usr/bin/env bash
# Compila o IDEmu para Linux NATIVO: bin/qemu-system-arm (QEMU 11.1.2 + omap5-uevm) e bin/glhost.
#
#   linux/build-linux.sh [deps|build|all]
#
#   deps   instala os pacotes do sistema (apt, dnf, pacman ou zypper; pede sudo)
#   build  compila o QEMU e o renderizador (10 a 40 min na primeira vez)
#   all    deps + build   (padrão)
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
STEP=${1:-all}

deps() {
  local SUDO=""
  [[ $(id -u) -eq 0 ]] || SUDO="sudo"
  if command -v apt-get >/dev/null; then
    $SUDO apt-get update
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
      python3 curl patch xz-utils tar openssl openssh-server openssh-client \
      build-essential clang ninja-build pkg-config libglib2.0-dev libpixman-1-dev \
      freeglut3-dev libgl1-mesa-dev libgl1-mesa-dri libpng-dev xvfb
  elif command -v dnf >/dev/null; then
    $SUDO dnf install -y python3 curl patch xz tar openssl openssh-server openssh-clients \
      gcc gcc-c++ clang make ninja-build pkgconf-pkg-config glib2-devel pixman-devel \
      freeglut-devel mesa-libGL-devel mesa-dri-drivers libpng-devel xorg-x11-server-Xvfb
  elif command -v pacman >/dev/null; then
    $SUDO pacman -S --needed --noconfirm python curl patch xz tar openssl openssh \
      base-devel clang ninja pkgconf glib2 pixman freeglut libglvnd mesa libpng xorg-server-xvfb
  elif command -v zypper >/dev/null; then
    $SUDO zypper --non-interactive install python3 curl patch xz tar openssl openssh \
      gcc gcc-c++ clang make ninja pkg-config glib2-devel libpixman-1-0-devel \
      freeglut-devel Mesa-libGL-devel libpng16-devel xorg-x11-server-Xvfb
  else
    echo "Gerenciador de pacotes não reconhecido: instale à mão python3, gcc/clang, ninja, pkg-config, glib2, pixman, freeglut, GL, libpng e xvfb." >&2
    exit 1
  fi
  echo "[ok] dependências instaladas"
}

build() {
  export QEMU_JOBS=${QEMU_JOBS:-$(nproc)}
  echo "[..] compilando o QEMU 11.1.2 (baixa ~130 MB)"
  bash tools/qemu/build-arm-linux.sh
  echo "[..] compilando o renderizador glhost"
  bash src/glhost/build.sh
  [[ -x bin/qemu-system-arm && -x bin/glhost ]] || { echo "ERRO: bin/qemu-system-arm ou bin/glhost não foi gerado." >&2; exit 1; }
  echo "[ok] compilado: $ROOT/bin"
}

case $STEP in
  deps)  deps ;;
  build) build ;;
  all)   deps; build ;;
  *)     echo "passo desconhecido: $STEP (deps|build|all)" >&2; exit 2 ;;
esac
