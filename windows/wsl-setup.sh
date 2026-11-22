#!/usr/bin/env bash
# IDEmu no Windows: roda DENTRO do WSL2 (Ubuntu). Não use no macOS.
#
#   wsl-setup.sh <pasta-do-repositorio-no-windows-em-formato-WSL> [sync|deps|build|all]
#
#   sync   copia o repositório (/mnt/c/...) para ~/IDEmu, no disco Linux do WSL (rápido a cada partida)
#   deps   instala os pacotes do Ubuntu (pede a senha do sudo)
#   build  compila o QEMU 11.1.2 (OMAP5) e o renderizador glhost em ~/IDEmu/bin
#   all    deps + sync + build   (padrão)
#
# Por que copiar: o IDEmu usa sockets unix e permissões (chaves SSH) que o disco do Windows (/mnt/c) não suporta.
# O que está em ~/IDEmu/environments (as VMs), ~/IDEmu/bin e ~/IDEmu/cache é preservado a cada sincronização.
set -euo pipefail

SRC=${1:?uso: wsl-setup.sh <repositório em /mnt/...> [sync|deps|build|all]}
STEP=${2:-all}
DEST=${IDEMU_HOME:-$HOME/IDEmu}
SRC=${SRC%/}

do_sync() {
  [[ -d $SRC/idemu ]] || { echo "ERRO: $SRC não parece o repositório do IDEmu (falta a pasta idemu)." >&2; exit 1; }
  mkdir -p "$DEST"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --no-owner --no-group --delete \
      --exclude '/environments/' --exclude '/bin/' --exclude '/cache/' --exclude '/mapcache/' --exclude '/settings.json' \
      --exclude '/cic/' --exclude '/mgu7/' --exclude '/mgu22/' --exclude '/vendor/' \
      --exclude '/idemu/data/phone/' --exclude '/idemu/shim/lib-*/' --exclude '/src/*/out/' \
      --exclude '__pycache__/' --exclude '*.pyc' --exclude '.git/' --exclude 'node_modules/' --exclude '*.log' \
      "$SRC/" "$DEST/"
  else
    echo "rsync não instalado: copiando com cp (rode '$0 $SRC deps' para instalar o rsync)"
    cp -a "$SRC/." "$DEST/"
  fi
  # arquivos de texto do Windows podem ter CRLF (autocrlf do git): o bash não aceita
  find "$DEST" -path "$DEST/environments" -prune -o -path "$DEST/bin" -prune -o -type f \( -name '*.sh' -o -name '*.command' \) -exec sed -i 's/\r$//' {} +
  echo "[ok] repositório sincronizado em $DEST"
}

do_deps() {
  local SUDO=""
  [[ $(id -u) -eq 0 ]] || SUDO="sudo"
  $SUDO apt-get update
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    python3 python3-venv python3-pip git curl rsync patch xz-utils tar procps openssl openssh-server openssh-client \
    build-essential clang ninja-build pkg-config libglib2.0-dev libpixman-1-dev \
    freeglut3-dev libgl1-mesa-dev libgl1-mesa-dri libpng-dev xvfb
  echo "[ok] dependências instaladas"
}

do_build() {
  [[ -f $DEST/tools/qemu/build-arm-linux.sh ]] || do_sync
  cd "$DEST"
  # no WSL2 o TCG é só CPU: o QEMU usa todos os núcleos que o WSL enxerga para compilar
  export QEMU_JOBS=${QEMU_JOBS:-$(nproc)}
  echo "[..] compilando o QEMU 11.1.2 (baixa ~130 MB; leva de 10 a 40 min)"
  bash tools/qemu/build-arm-linux.sh
  echo "[..] compilando o renderizador glhost"
  bash src/glhost/build.sh
  [[ -x bin/qemu-system-arm && -x bin/glhost ]] || { echo "ERRO: bin/qemu-system-arm ou bin/glhost não foi gerado." >&2; exit 1; }
  echo "[ok] compilado: $DEST/bin"
}

case $STEP in
  sync)  do_sync ;;
  deps)  do_deps ;;
  build) do_build ;;
  all)   do_deps; do_sync; do_build ;;
  *)     echo "passo desconhecido: $STEP" >&2; exit 2 ;;
esac
