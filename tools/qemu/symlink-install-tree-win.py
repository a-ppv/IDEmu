#!/usr/bin/env python3
# Substitui scripts/symlink-install-tree.py do QEMU nas compilações para Windows (copiado pelos build-*-windows.sh).
# O original cria a árvore "qemu-bundle" com links simbólicos, e o Windows sem Modo de Desenvolvedor/administrador não os permite.
# O qemu-bundle só serve para rodar o QEMU de dentro da pasta de build; o IDEmu copia os .exe para bin/, então não precisa dele.
import sys
sys.exit(0)
