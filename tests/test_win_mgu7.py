"""iDrive 7 no Windows: a lógica Python que não depende do firmware nem do Windows. Roda em qualquer sistema (o Windows é simulado com mock em IS_WIN):
sidecar de symlinks/modos da raiz extraída (tools/mgu/rootmeta.py), extração HAR e imagem ext2 com o sidecar, linha de comando do QEMU, nomes da memória compartilhada."""
import importlib.util, os, struct, sys, tempfile, unittest
from unittest import mock
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from idemu import mgu7, ipc

TOOLS = os.path.join(ROOT, 'tools', 'mgu')


def load(name):
    spec = importlib.util.spec_from_file_location('t_' + name, os.path.join(TOOLS, name + '.py'))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m


rootmeta = load('rootmeta')


class MetaTest(unittest.TestCase):
    def test_norm_and_save_roundtrip(self):
        self.assertEqual(rootmeta.norm('/usr//bin/./x'), 'usr/bin/x')
        self.assertEqual(rootmeta.norm('/'), '')
        with tempfile.TemporaryDirectory() as tmp:
            m = rootmeta.Meta(tmp); m.set_link('/bin/sh', 'busybox'); m.set_mode('usr/bin/x', 0o100755)
            m.save()
            n = rootmeta.Meta(tmp)
            self.assertEqual(n.links, {'bin/sh': 'busybox'}); self.assertEqual(n.mode_of('usr/bin/x'), 0o755)

    def test_resolve_follows_links_in_every_component(self):
        m = rootmeta.Meta(tempfile.gettempdir() + '/nao-existe-idemu')
        m.set_link('lib', 'usr/lib'); m.set_link('usr/lib/libx.so', 'libx.so.1'); m.set_link('bin', '/usr/bin'); m.set_link('usr/bin/sh', '../lib/shx')
        self.assertEqual(m.resolve('lib/y.so'), 'usr/lib/y.so')             # pasta que é symlink relativo
        self.assertEqual(m.resolve('lib/libx.so'), 'usr/lib/libx.so.1')     # e o arquivo final também
        self.assertEqual(m.resolve('bin/tool'), 'usr/bin/tool')             # destino absoluto vale a partir da raiz
        self.assertEqual(m.resolve('bin/sh'), 'usr/lib/shx')                # relativo com `..`
        self.assertEqual(m.resolve('etc/x'), 'etc/x')
        m.set_link('a', 'b'); m.set_link('b', 'a')
        with self.assertRaises(OSError): m.resolve('a/x')                  # laço de symlinks

    def test_links_in_lists_one_directory(self):
        m = rootmeta.Meta(tempfile.gettempdir() + '/nao-existe-idemu')
        m.set_link('etc/a', 'x'); m.set_link('etc/b', 'y'); m.set_link('usr/c', 'z'); m.set_link('top', 't')
        self.assertEqual(m.links_in('etc'), {'a': 'x', 'b': 'y'}); self.assertEqual(m.links_in(''), {'top': 't'}); self.assertEqual(m.links_in('vazio'), {})

    def test_lp_leaves_short_paths_alone(self):
        self.assertEqual(rootmeta.lp('C:\\a\\b'), 'C:\\a\\b')


def har_record(name, mode, data=b'', link=None):
    """Um registro HAR (formato de tools/mgu/har.py) com os dados crus (guardado == bruto)."""
    nb = name.encode(); lb = link.encode() if link else b''
    head = bytearray(92)
    struct.pack_into('<I', head, 4, (len(lb) << 16) | len(nb)); struct.pack_into('<II', head, 12, len(data), len(data)); struct.pack_into('<I', head, 60, mode)
    return bytes(head) + nb + lb + b'\0' * 28 + data


def har_package(*recs):
    return b'\0' * 0x200 + b''.join(recs) + b'\0' * 300          # o zero no fim (nome vazio) encerra a leitura


class HarWindowsTest(unittest.TestCase):
    """har.main_win (a extração do Windows) chamada direto, em qualquer sistema: arquivos no disco, symlinks e modos no sidecar."""
    def test_extract_records_links_and_modes(self):
        har = load('har')
        pkg = har_package(har_record('/usr', 0o040755), har_record('/usr/bin', 0o040755),
                          har_record('/usr/bin/tool', 0o100755, b'\x7fELFabc'), har_record('/etc/conf', 0o100600, b'x=1\n'),
                          har_record('/bin/sh', 0o120777, b'busybox'), har_record('/lib', 0o120777, b'', link='usr/lib'))
        with tempfile.TemporaryDirectory() as tmp:
            har.main_win(pkg, tmp, None)
            self.assertEqual(open(os.path.join(tmp, 'usr', 'bin', 'tool'), 'rb').read(), b'\x7fELFabc')
            m = rootmeta.Meta(tmp)
            self.assertEqual((m.mode_of('usr/bin/tool'), m.mode_of('etc/conf')), (0o755, 0o600))
            self.assertEqual(m.links.get('bin/sh'), 'busybox'); self.assertEqual(m.links.get('lib'), 'usr/lib')
            self.assertFalse(os.path.lexists(os.path.join(tmp, 'bin', 'sh')))            # symlink só no sidecar, não no disco
            # segundo pacote por cima: um arquivo comum no lugar do symlink apaga o registro dele
            har.main_win(har_package(har_record('/bin/sh', 0o100755, b'#!/bin/sh\n')), tmp, None)
            m = rootmeta.Meta(tmp); self.assertNotIn('bin/sh', m.links); self.assertEqual(m.mode_of('bin/sh'), 0o755); self.assertIn('lib', m.links)


def read_ext2(path):
    """Leitor mínimo do ext2 que o mkext2.py grava: devolve (função inode(n) -> (modo, tamanho, i_block), função ls(n) -> {nome: inode})."""
    d = open(path, 'rb').read(); BS = 4096
    ipg = struct.unpack_from('<I', d, 1024 + 40)[0]; it = struct.unpack_from('<I', d, BS + 8)[0]
    def inode(n):
        off = it * BS + ((n - 1) % ipg) * 128
        return struct.unpack_from('<H', d, off)[0], struct.unpack_from('<I', d, off + 4)[0], d[off + 40:off + 100]
    def ls(n):
        mode, size, ib = inode(n); out = {}
        for b in struct.unpack_from('<12I', ib, 0):
            if not b: continue
            p = b * BS; q = p
            while q < p + BS:
                ino, rl, nl, ft = struct.unpack_from('<IHBB', d, q)
                if ino: out[d[q + 8:q + 8 + nl].decode()] = ino
                q += rl
        return out
    return inode, ls


class Ext2WindowsTest(unittest.TestCase):
    def test_image_takes_links_and_modes_from_sidecar(self):
        mk = load('mkext2')
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, 'root'); os.makedirs(os.path.join(root, 'bin')); os.makedirs(os.path.join(root, 'etc'))
            open(os.path.join(root, 'bin', 'tool'), 'wb').write(b'\x7fELFxx'); open(os.path.join(root, 'bin', 'script'), 'wb').write(b'#!/bin/sh\n'); open(os.path.join(root, 'bin', 'data'), 'wb').write(b'texto')
            open(os.path.join(root, 'etc', 'secret'), 'wb').write(b's')
            m = rootmeta.Meta(root); m.set_mode('bin/tool', 0o4755); m.set_mode('etc/secret', 0o600)
            m.set_link('bin/sh', 'busybox'); m.set_link('etc/long', '/' + 'a' * 80); m.save()               # o 2º destino passa de 59 bytes (symlink "lento")
            img = os.path.join(tmp, 'root.img')
            with mock.patch.object(mk, 'IS_WIN', True), mock.patch.object(mk, 'rootmeta', rootmeta, create=True), mock.patch.object(mk, 'L', rootmeta.lp):
                mk.build(root, img, 16)
            inode, ls = read_ext2(img)
            top = ls(2); self.assertEqual(sorted(top), ['.', '..', 'bin', 'etc'])         # o sidecar (.idemu-meta.json) não vai para a imagem
            b = ls(top['bin']); self.assertEqual(sorted(b), ['.', '..', 'data', 'script', 'sh', 'tool'])
            self.assertEqual(inode(b['tool'])[0] & 0o7777, 0o4755); self.assertEqual(inode(b['script'])[0] & 0o7777, 0o755)       # sidecar; heurística (#!)
            self.assertEqual(inode(b['data'])[0] & 0o7777, 0o644)
            mode, size, ib = inode(b['sh']); self.assertEqual((mode & 0o170000, size, ib[:7]), (0o120000, 7, b'busybox'))
            e = ls(top['etc']); self.assertEqual(inode(e['secret'])[0] & 0o7777, 0o600)
            mode, size, ib = inode(e['long']); self.assertEqual((mode & 0o170000, size), (0o120000, 81))


class RuntimeHelpersTest(unittest.TestCase):
    def test_shared_memory_name(self):
        self.assertEqual(mgu7.shm_win_name('/idemu-gl-123-456'), 'Local\\idemu-gl-123-456')

    def test_chardev_socket_posix_and_windows(self):
        with mock.patch.object(mgu7, 'IS_WIN', False):
            self.assertEqual(mgu7._chardev_socket('gl', '/tmp/x/gl.sock'), 'socket,id=gl,path=/tmp/x/gl.sock,server=on,wait=off')      # o de sempre, byte a byte
        with mock.patch.object(mgu7, 'IS_WIN', True):
            self.assertEqual(mgu7._chardev_socket('gl', '127.0.0.1:5555'), 'socket,id=gl,host=127.0.0.1,port=5555,server=on,wait=off,nodelay=on')
            self.assertEqual(mgu7._qp('C:\\a,b\\x'), 'C:\\a,,b\\x')
        with mock.patch.object(mgu7, 'IS_WIN', False): self.assertEqual(mgu7._qp('/a,b'), '/a,b')

    def test_accel_is_tcg_except_windows_opt_in(self):
        with mock.patch.dict(os.environ, {'IDEMU_MGU7_ACCEL': 'whpx'}):
            with mock.patch.object(mgu7, 'IS_WIN', False): self.assertEqual(mgu7._accel(), 'tcg')
            with mock.patch.object(mgu7, 'IS_WIN', True): self.assertEqual(mgu7._accel(), 'whpx')
        with mock.patch.dict(os.environ, clear=False):
            os.environ.pop('IDEMU_MGU7_ACCEL', None)
            with mock.patch.object(mgu7, 'IS_WIN', True): self.assertEqual(mgu7._accel(), 'tcg')

    def test_fast_boot_is_off_on_windows_unless_requested(self):
        with tempfile.TemporaryDirectory() as tmp:
            rt = mgu7.Mgu7Runtime(tmp, {'id': 'x'})
            with mock.patch.dict(os.environ, clear=False):
                os.environ.pop('IDEMU_FASTBOOT', None)
                with mock.patch.object(mgu7, 'IS_WIN', True):
                    self.assertFalse(rt.snap_capable()); self.assertFalse(rt.snapshot_info()['enabled'])
                    os.environ['IDEMU_FASTBOOT'] = '1'; self.assertFalse(mgu7._win_nofast())

    def test_executable_names(self):
        self.assertEqual(os.path.basename(mgu7.glhost_path()), 'glhost7' + ('.exe' if ipc.IS_WIN else ''))
        self.assertEqual(os.path.basename(mgu7.QEMU_OWN), 'qemu-system-x86_64' + ('.exe' if ipc.IS_WIN else ''))

    def test_overlay_links_match_the_overlay_files(self):
        """Num checkout do Windows (ZIP) os 2 symlinks do overlay são arquivos de texto com o destino dentro; no macOS são symlinks de verdade."""
        ov = os.path.join(TOOLS, 'rse_overlay')
        for rel, tgt in mgu7.WIN_OVERLAY_LINKS.items():
            p = os.path.join(ov, *rel.split('/'))
            self.assertTrue(os.path.lexists(p), rel)
            if os.path.islink(p): self.assertEqual(os.readlink(p), tgt)
            else: self.assertEqual(open(p).read().strip(), tgt)

    def test_windows_overlay_goes_to_root_with_sidecar(self):
        with tempfile.TemporaryDirectory() as tmp:
            wm = rootmeta.Meta(tmp); wm.set_link('lib', 'usr/lib')                      # `lib -> usr/lib`: o overlay de lib/systemd vai para usr/lib/systemd
            mgu7._win_overlay(tmp, wm)
            self.assertTrue(os.path.isfile(os.path.join(tmp, 'usr', 'lib', 'systemd', 'system', 'idemu-diag.service')))
            self.assertTrue(os.path.isfile(os.path.join(tmp, 'etc', 'fstab')))
            self.assertEqual(wm.links['etc/systemd/system/winston.service'], '/dev/null')
            self.assertEqual(wm.links['etc/systemd/system/multi-user.target.wants/idemu-diag.service'], '/lib/systemd/system/idemu-diag.service')
            self.assertEqual(wm.mode_of('usr/bin/idemu-diag.sh'), 0o755); self.assertEqual(wm.mode_of('etc/fstab'), 0o644)
            self.assertNotIn(b'\r', open(os.path.join(tmp, 'etc', 'fstab'), 'rb').read())     # LF mesmo se o checkout veio com CRLF
            self.assertFalse(os.path.lexists(os.path.join(tmp, 'etc', 'systemd', 'system', 'winston.service')))


class ScriptsTest(unittest.TestCase):
    def test_shell_scripts_have_lf_endings(self):
        for p in ('tools/qemu/build-x86-windows.sh', 'src/mgu/build-windows.sh'):
            self.assertNotIn(b'\r', open(os.path.join(ROOT, *p.split('/')), 'rb').read(), p)

    def test_glhost7_windows_port_is_wired(self):
        src = open(os.path.join(ROOT, 'src', 'mgu', 'glhost7.c'), encoding='utf-8').read()
        self.assertIn('#include "winport7.h"', src); self.assertIn('wglCreateContextAttribsARB', src); self.assertIn('w7_open_shm', src)
        hdr = open(os.path.join(ROOT, 'src', 'mgu', 'winport7.h'), encoding='utf-8').read()
        self.assertIn('#include "../glhost/winport.h"', hdr); self.assertIn('OpenFileMappingA', hdr)
        shm = open(os.path.join(ROOT, 'src', 'qemu', 'idemu-shm.c'), encoding='utf-8').read()
        self.assertIn('CreateFileMappingA', shm); self.assertIn('memory_region_init_ram_ptr', shm); self.assertIn('memory_region_init_ram_from_fd', shm)


if __name__ == '__main__':
    unittest.main()
