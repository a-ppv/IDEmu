#!/usr/bin/env python3
"""Extrator dos pacotes HAR (HU_MGU_01 / RSE_MGU_01, iDrive 7): swfl_XXXXXXXX.bin.* -> árvore de arquivos.

Formato (engenharia reversa): a partir de 0x200, uma sequência de registros
  [bloco 'HAR#$%&@' de 64 B, só no início de cada grupo][cabeçalho 92 B][nome][28 B][dados]
O cabeçalho traz o tamanho guardado (+12) e o bruto (+16) e o modo (+60..); os dados são um fluxo zlib
(guardado < bruto) ou bytes crus (guardado == bruto). O primeiro arquivo é o manifesto, com SHA-256 por arquivo.

Uso: har.py -l pacote.bin.*                lista
     har.py pacote.bin.* destino [regex]   extrai (só os caminhos que casam com a regex, se dada)
"""
import sys, os, re, shutil, zlib, struct, stat as st

MAGIC = b'HAR#$%&@'

def records(d):
    pos = 0x200; n = len(d)
    while pos + 120 < n:
        if d[pos:pos + 8] == MAGIC: pos += 64
        if d[pos:pos + 8] == MAGIC: continue
        head = d[pos:pos + 92]
        stored, raw = struct.unpack_from('<II', head, 12)
        nl = struct.unpack_from('<I', head, 4)[0]; ll, nl = nl >> 16, nl & 0xFFFF
        name = d[pos + 92:pos + 92 + nl].decode('utf-8', 'replace')
        if nl == 0: return
        link = d[pos + 92 + nl:pos + 92 + nl + ll].decode('utf-8', 'replace') if ll else None
        e = pos + 92 + nl + ll
        data = e + (0 if ll and struct.unpack_from('<I', head, 60)[0] & 0xF000 == 0x8000 else 28)          # elos rígidos (nome + destino) não têm o enchimento de 28 B
        yield name, head, raw, stored, data, link
        pos = data + stored

def unpack(d, name, raw, stored, data):
    blob = d[data:data + stored]
    if stored == raw: return blob
    o = zlib.decompressobj(); out = o.decompress(blob)
    if not o.eof or o.unused_data: raise ValueError('%s: fluxo zlib incompleto' % name)
    return out          # arquivos grandes vêm em blocos de 50 MiB: vários registros com o mesmo nome (acrescentar)

def mode_of(head):
    return struct.unpack_from('<I', head, 60)[0]

def main_win(d, out, rx):
    """Extração no Windows: arquivos comuns vão para o disco; symlinks e modos (rwx) vão para o sidecar `<destino>/.idemu-meta.json` (tools/mgu/rootmeta.py),
    de onde o mkext2.py os lê. O NTFS não guarda symlink sem privilégio nem bits de execução. Nomes que o Windows não aceita (`:`, `?`, `aux`...) são ignorados
    e contados no fim, em vez de abortar a extração inteira."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import rootmeta, posixpath
    L = rootmeta.lp; meta = rootmeta.Meta(out)
    total = 0; done = {}; skipped = []

    def drop_disk(p):                                  # tira o que houver no disco antes de registrar um symlink no lugar
        if os.path.lexists(L(p)):
            try: os.unlink(L(p))
            except OSError: pass
    for name, head, raw, stored, data, link in records(d):
        m = mode_of(head); kind = 'd' if m and m & 0xF000 == 0x4000 else 'l' if m and m & 0xF000 == 0xA000 else 'f'
        if rx and not rx.search(name): continue
        rel = rootmeta.norm(name)
        if not rel: continue
        try:
            dest = os.path.join(out, *rel.split('/'))
            if kind == 'd': os.makedirs(L(dest), exist_ok=True); continue
            os.makedirs(L(os.path.dirname(dest)), exist_ok=True)
            if link is not None:
                tgt_rel = rootmeta.norm(link)
                tgt = os.path.join(out, *tgt_rel.split('/')) if tgt_rel else None
                if kind != 'l' and tgt and os.path.isfile(L(tgt)):          # elo rígido: copia do destino (e leva o modo dele)
                    meta.drop_link(rel); drop_disk(dest); shutil.copyfile(L(tgt), L(dest)); meta.set_mode(rel, meta.mode_of(tgt_rel) or 0o644)
                else:                                                       # symlink (ou elo rígido cujo destino ainda não veio): destino literal
                    drop_disk(dest); meta.set_link(rel, link)
                continue
            blob = unpack(d, name, raw, stored, data) if stored else b''
            if kind == 'l':
                drop_disk(dest); meta.set_link(rel, blob.decode())
            else:
                part = done.get(name, 0); cont = 0 < part < raw
                if not cont:
                    meta.drop_link(rel)                                     # um arquivo comum substitui um symlink de um pacote anterior
                    if os.path.lexists(L(dest)): os.unlink(L(dest))
                with open(L(dest), 'ab' if cont else 'wb') as f: f.write(blob)
                done[name] = (part if cont else 0) + len(blob)
                meta.set_mode(rel, (m or 0o644) & 0o7777)
            total += len(blob)
        except OSError as e:
            skipped.append('%s (%s)' % (rel, str(e)[:70]))
    meta.save()
    print('extraído: %d bytes' % total + (' (%d nomes ignorados: o Windows não os aceita)' % len(skipped) if skipped else ''))
    for s in skipped[:15]: print('  ignorado:', s)


def main(argv):
    ls = argv and argv[0] == '-l'
    if ls: argv = argv[1:]
    pkg = argv[0]; d = open(pkg, 'rb').read()
    out = argv[1] if not ls else None
    rx = re.compile(argv[2]) if len(argv) > 2 else None
    if os.name == 'nt' and not ls: return main_win(d, out, rx)
    total = 0; done = {}
    for name, head, raw, stored, data, link in records(d):
        m = mode_of(head); kind = 'd' if m and m & 0xF000 == 0x4000 else 'l' if m and m & 0xF000 == 0xA000 else 'f'
        if ls: print('%s %o %9d %9d %s' % (kind, m or 0, raw, stored, name)); continue
        if rx and not rx.search(name): continue
        if name.strip('/') == '': continue
        dest = os.path.join(out, name.lstrip('/'))
        if kind == 'd': os.makedirs(dest, exist_ok=True); os.chmod(dest, 0o755); continue
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if link is not None:
            if os.path.lexists(dest): os.unlink(dest)
            if kind == 'l': os.symlink(link, dest)           # symlink: destino literal
            else:                                           # elo rígido: copia do destino
                tgt = os.path.join(out, link.lstrip('/'))
                (os.link if os.path.exists(tgt) else os.symlink)(tgt if os.path.exists(tgt) else link, dest)
            continue
        blob = unpack(d, name, raw, stored, data) if stored else b''
        if kind == 'l':
            if os.path.lexists(dest): os.unlink(dest)
            os.symlink(blob.decode(), dest)
        else:
            part = done.get(name, 0)
            if not (0 < part < raw) and os.path.lexists(dest): os.chmod(dest, 0o600) if not os.path.islink(dest) else None; os.unlink(dest)
            elif os.path.exists(dest): os.chmod(dest, 0o600)
            with open(dest, 'ab' if 0 < part < raw else 'wb') as f: f.write(blob)
            done[name] = (part if 0 < part < raw else 0) + len(blob)
            os.chmod(dest, (m or 0o644) & 0o7777)
        total += len(blob)
    if not ls: print('extraído: %d bytes' % total)

if __name__ == '__main__': main(sys.argv[1:])
