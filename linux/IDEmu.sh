#!/usr/bin/env bash
# Abre o IDEmu no Linux (iDrive 5/6 / NBT Evo). Equivalente do IDEmu.command do macOS.
#
#   linux/IDEmu.sh [--fast-boot] [--software-gl] [--port N] [--no-browser]
#
# Sem tela gráfica (SSH, servidor, WSL sem WSLg), o renderizador roda dentro do xvfb-run com Mesa llvmpipe (caminho validado, docs/LINUX.md).
# O boot rápido (snapshot) não foi validado no Linux: fica desligado, a menos que você passe --fast-boot.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

FAST=0; SOFT=0; ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --fast-boot) FAST=1 ;;
    --software-gl) SOFT=1 ;;
    -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done

[[ -x bin/qemu-system-arm && -x bin/glhost ]] || { echo "Faltam bin/qemu-system-arm e bin/glhost: rode  linux/build-linux.sh" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 não encontrado" >&2; exit 1; }

[[ $FAST -eq 1 ]] || export IDEMU_NO_SNAPSHOT=1
[[ $SOFT -eq 1 ]] && export LIBGL_ALWAYS_SOFTWARE=1

if [[ -z ${DISPLAY:-} && -z ${WAYLAND_DISPLAY:-} ]]; then
  command -v xvfb-run >/dev/null || { echo "Sem tela gráfica e sem xvfb-run: instale o xvfb (linux/build-linux.sh deps)" >&2; exit 1; }
  export LIBGL_ALWAYS_SOFTWARE=1
  exec xvfb-run -a -s '-screen 0 1920x1080x24' python3 -m idemu gui ${ARGS[@]+"${ARGS[@]}"}
fi
exec python3 -m idemu gui ${ARGS[@]+"${ARGS[@]}"}
