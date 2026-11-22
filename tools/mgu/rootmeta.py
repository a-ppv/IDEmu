#!/usr/bin/env python3
"""Metadados de uma raiz de sistema extraída no Windows (iDrive 7): symlinks e modos de arquivo.

O firmware do MGU é Linux: symlinks (muitos com destino absoluto, `/dev/null`...), elos rígidos e bits de execução. O NTFS do Windows não os guarda
sem privilégio (symlink) nem de forma alguma (modo `rwx`). No lugar de criá-los no disco, `har.py` e o `mgu7.build` anotam tudo num arquivo ao lado
dos arquivos comuns, `<raiz>/.idemu-meta.json`, e o `mkext2.py` o junta ao que está no disco quando grava a imagem ext2:

    {"v": 1, "links": {"bin/sh": "busybox", "etc/localtime": "/usr/share/zoneinfo/UTC"}, "modes": {"usr/bin/HmiMain3D": 493}}

Os caminhos são relativos à raiz, com `/`, sem `/` inicial. Só o Windows usa este módulo (no macOS/Linux o disco guarda tudo); ele não importa nada além da
biblioteca padrão e roda em qualquer sistema, o que permite testar a lógica (tests/test_win_mgu7.py).
"""
import json, os, posixpath

META = '.idemu-meta.json'


def lp(path):
    """Caminho no formato longo do Windows (\\\\?\\C:\\...): a raiz do firmware tem caminhos acima dos 260 caracteres do MAX_PATH. Fora do Windows devolve igual."""
    if os.name != 'nt' or len(path) < 240:
        return path
    p = os.path.abspath(path)
    if p.startswith('\\\\?\\'):
        return p
    if p.startswith('\\\\'):
        return '\\\\?\\UNC\\' + p[2:]
    return '\\\\?\\' + p


def norm(rel):
    """Caminho relativo normalizado: sem `/` inicial, sem `.` e sem `//` ('' = a raiz)."""
    r = posixpath.normpath('/' + str(rel).replace('\\', '/')).lstrip('/')
    return '' if r == '.' else r


class Meta:
    def __init__(self, root):
        self.root = root
        self.path = os.path.join(root, META)
        self.links = {}
        self.modes = {}
        self._byparent = None
        try:
            with open(lp(self.path), encoding='utf-8') as f:
                d = json.load(f)
            self.links = dict(d.get('links') or {})
            self.modes = {k: int(v) for k, v in (d.get('modes') or {}).items()}
        except (OSError, ValueError):
            pass

    def save(self):
        os.makedirs(lp(self.root), exist_ok=True)
        tmp = self.path + '.tmp'
        with open(lp(tmp), 'w', encoding='utf-8', newline='\n') as f:
            json.dump({'v': 1, 'links': self.links, 'modes': self.modes}, f, separators=(',', ':'))
        os.replace(lp(tmp), lp(self.path))

    # ---- symlinks ----
    def set_link(self, rel, target):
        rel = norm(rel)
        self.links[rel] = str(target)
        self.modes.pop(rel, None)
        self._byparent = None

    def drop_link(self, rel):
        rel = norm(rel)
        if rel in self.links:
            del self.links[rel]
            self._byparent = None

    def is_link(self, rel):
        return norm(rel) in self.links

    def links_in(self, reldir):
        """{nome: destino} dos symlinks que ficam diretamente na pasta `reldir` ('' = a raiz)."""
        if self._byparent is None:
            self._byparent = {}
            for rel, tgt in self.links.items():
                self._byparent.setdefault(posixpath.dirname(rel), {})[posixpath.basename(rel)] = tgt
        return self._byparent.get(norm(reldir), {})

    def resolve(self, rel, max_hops=40):
        """Caminho `rel` com os symlinks do sidecar seguidos em TODOS os componentes (destino absoluto vale a partir da raiz). Serve para gravar um arquivo
        onde o Linux o gravaria: `lib/x.so` com `lib -> usr/lib` vira `usr/lib/x.so`, em vez de criar uma pasta `lib` de verdade ao lado do link."""
        todo = [p for p in norm(rel).split('/') if p]
        done = []
        hops = 0
        while todo:
            p = todo.pop(0)
            if p == '.':
                continue
            if p == '..':
                if done:
                    done.pop()
                continue
            cand = '/'.join(done + [p])
            t = self.links.get(cand)
            if t is None:
                done.append(p)
                continue
            hops += 1
            if hops > max_hops:
                raise OSError('symlinks demais ao resolver %s' % rel)
            if t.startswith('/'):
                done = []
            todo = [x for x in t.split('/') if x] + todo
        return '/'.join(done)

    # ---- modos ----
    def set_mode(self, rel, mode):
        self.modes[norm(rel)] = int(mode) & 0o7777

    def mode_of(self, rel):
        return self.modes.get(norm(rel))
