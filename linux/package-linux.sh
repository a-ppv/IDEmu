#!/usr/bin/env bash
# Gera dist/IDEmu-linux-<arquitetura>.tar.gz: o IDEmu nativo para Linux (idemu/ + bin/ + launcher). Rode DEPOIS de linux/build-linux.sh.
# Os binários usam as bibliotecas do sistema (glib2, pixman, freeglut, GL, libpng): na máquina de destino instale-as (linux/build-linux.sh deps instala também as de desenvolvimento).
# Não inclui firmware da BMW nem imagens: cada pessoa usa os seus pacotes SWFL (veja NOTICE).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
[[ -x bin/qemu-system-arm && -x bin/glhost ]] || { echo "Faltam bin/qemu-system-arm e bin/glhost: rode linux/build-linux.sh" >&2; exit 1; }
ARCH=$(uname -m)
NAME=IDEmu-linux-$ARCH
STAGE=dist/$NAME
rm -rf "$STAGE"; mkdir -p "$STAGE/linux" "$STAGE/docs"
rsync -a --exclude '__pycache__' --exclude '*.pyc' --exclude '/data/phone' idemu/ "$STAGE/idemu/" 2>/dev/null \
  || { cp -a idemu "$STAGE/idemu"; find "$STAGE/idemu" -name __pycache__ -prune -exec rm -rf {} +; rm -rf "$STAGE/idemu/data/phone"; }
mkdir -p "$STAGE/bin"
cp -a bin/qemu-system-arm bin/glhost "$STAGE/bin/"
[[ -d bin/glsl ]] && cp -a bin/glsl "$STAGE/bin/"
[[ -f bin/shader_index.txt ]] && cp -a bin/shader_index.txt "$STAGE/bin/"
cp linux/IDEmu.sh "$STAGE/linux/"; chmod +x "$STAGE/linux/IDEmu.sh"
cp LICENSE NOTICE README.md README.pt-BR.md "$STAGE/" 2>/dev/null || true
cp docs/LINUX.md docs/ARQUITETURA.md "$STAGE/docs/" 2>/dev/null || true
tar -C dist -czf "dist/$NAME.tar.gz" "$NAME"
echo "[ok] dist/$NAME.tar.gz ($(du -h "dist/$NAME.tar.gz" | cut -f1))"
