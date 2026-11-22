"""Port do CIC (SH-4A/QNX 6.3) para Windows nativo: a lógica Python que muda no Windows, testada em qualquer SO (o Windows é simulado com
ipc.IS_WIN / run.IS_WIN). O QEMU em si (src/cic/*.c) não é compilado aqui."""
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools', 'cic'))
sys.path.insert(0, ROOT)

from idemu import ipc, cic          # noqa: E402
import efs                          # noqa: E402

BUILD_SH = os.path.join(ROOT, 'src', 'cic', 'build.sh')


def _load_run():
    spec = importlib.util.spec_from_file_location('cic_run_for_test', os.path.join(ROOT, 'tools', 'cic', 'run.py'))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


cicrun = _load_run()


class QemuCmdTest(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d, True)

    def test_posix_command_line_unchanged(self):
        with mock.patch.object(cicrun, 'IS_WIN', False):
            cmd = cicrun.qemu_cmd('/img', run='/run/x', qemu='/q/qemu', debug_log='', flash='/run/x/flash.img')
        self.assertEqual(cmd[cmd.index('-monitor') + 1], 'unix:/run/x/mon.sock,server,nowait')
        self.assertIn('socket,id=s0,path=/run/x/ser0.sock,server=on,wait=off', cmd)
        self.assertIn('socket,id=s1,path=/run/x/ser1.sock,server=on,wait=off,logfile=/run/x/ser1.log', cmd)
        self.assertIn('if=pflash,format=raw,file=/run/x/flash.img', cmd)
        self.assertIn('loader,file=/img/ifs.bin,addr=0x08010000,force-raw=on', cmd)

    def test_windows_uses_tcp_loopback(self):
        with mock.patch.object(cicrun, 'IS_WIN', True), mock.patch.object(ipc, 'IS_WIN', True):
            cmd = cicrun.qemu_cmd(self.d, run=self.d, qemu='q.exe', debug_log='', flash=os.path.join(self.d, 'a,b', 'flash.img'))
            p0, p1, pm = (ipc.port_of(ipc.addr(self.d, n)) for n in ('ser0.sock', 'ser1.sock', 'mon.sock'))
        mon = cmd[cmd.index('-monitor') + 1]
        self.assertEqual(mon, 'tcp:127.0.0.1:%d,server,nowait' % pm)
        self.assertIn('socket,id=s0,host=127.0.0.1,port=%d,server=on,wait=off' % p0, cmd)
        self.assertTrue(any(a.startswith('socket,id=s1,host=127.0.0.1,port=%d,server=on,wait=off,logfile=' % p1) for a in cmd))
        self.assertFalse([a for a in cmd if 'unix:' in a or 'path=' in a])
        self.assertTrue(any('file=' in a and 'a,,b' in a for a in cmd), 'vírgula no caminho vira ,, no QemuOpts')


class EfsModeTest(unittest.TestCase):
    def test_windows_has_no_exec_bit_so_modes_are_guessed(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        for n in ('run.sh', 'taco', 'logo.png', 'LIB.SO.1'):
            with open(os.path.join(d, n), 'wb') as f:
                f.write(b'x')
        with mock.patch.object(efs, 'IS_WIN', True):
            modes = {p: m for p, k, data, m in efs.dir_entries(d)}
        self.assertEqual(modes, {'run.sh': 0o755, 'taco': 0o755, 'logo.png': 0o644, 'LIB.SO.1': 0o644})

    def test_posix_keeps_disk_mode(self):
        if os.name == 'nt':
            self.skipTest('sem bit de execução no Windows')
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        p = os.path.join(d, 'prog')
        with open(p, 'wb') as f:
            f.write(b'x')
        os.chmod(p, 0o750)
        with mock.patch.object(efs, 'IS_WIN', False):
            self.assertEqual([m for _, _, _, m in efs.dir_entries(d)], [0o750])


class TransportTest(unittest.TestCase):
    """Entrada/saída do controlador iDrive virtual (CIC_INPUT/CIC_OUTPUT) sobre UDP em 127.0.0.1, como no Windows."""

    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d, True)
        p = mock.patch.object(ipc, 'IS_WIN', True)
        p.start()
        self.addCleanup(p.stop)

    def test_send_cmd_goes_to_udp_port_of_input_sock(self):
        rt = cic.CicRuntime.__new__(cic.CicRuntime)
        rt.run = self.d; rt._cmd_lock = threading.Lock(); rt._sock = None
        srv = ipc.dgram_bind(ipc.addr(self.d, 'input.sock'))
        self.addCleanup(srv.close)
        srv.settimeout(3)
        rt.send_cmd('v 116')
        self.addCleanup(rt._sock.close)
        self.assertEqual(srv.recv(100), b'v 116')

    def test_zbe_receives_x_datagram_on_output_sock(self):
        z = cic.VirtualZBE(self.d, lambda line: None)
        self.addCleanup(z.close)
        c = ipc.dgram_socket()
        self.addCleanup(c.close)
        tel = bytes([0, 12, 2, 0, 1, 2, 0x10, 1, 0x02, 0, 0, 1])           # HMI -> FBlock 0x10 inst. 1, FktID 0x200, Set
        ipc.dgram_send(c, ipc.addr(self.d, 'output.sock'), b'x ' + tel.hex().encode())
        end = time.time() + 3
        while time.time() < end and not z.seen:
            time.sleep(0.02)
        self.assertIn((0x10, 1, 0x200, 0), z.seen)

    def test_zbe_rotor_protocol_bytes_are_identical(self):
        sent = []
        z = cic.VirtualZBE(self.d, sent.append)
        self.addCleanup(z.close)
        z.rotate(1)
        expected = bytes([0, 19, 2, 0, 1, 2, 0xe5, 1, 0x0c, 0x10, 0x0c, 1, 1, 0x1d, 1, 0x10, 0x01, 0x1e, 0]).hex()
        self.assertEqual(sent, ['t ' + expected])


@unittest.skipUnless(os.name != 'nt' and shutil.which('bash') and shutil.which('sed') and (shutil.which('python3') or shutil.which('python')),
                     'precisa de bash, sed e python')
class BuildShTest(unittest.TestCase):
    """src/cic/build.sh (usado também por tools/qemu/build-sh4-windows.sh): patches idempotentes, sem CRLF, em UTF-8, e sufixo .exe sob controle."""

    FILES = {
        'hw/sh4/meson.build': "hw_arch += {'sh4': sh4_ss}\n",
        'hw/sh4/Kconfig': "config R2D\n    bool\n",
        'target/sh4/helper.c': "/* Find the corresponding entry in the right TLB\n */\nint x;\n",
        'target/sh4/translate.c': "    case 0x0083: /* pref @Rn */\n        return;\n",
        'target/sh4/op_helper.c': "void helper_trapa(CPUSH4State *env, uint32_t tra)\n{\n",
        'target/sh4/cpu.h': "#define PTEL_PPN_BITS (19)\n#endif\n",
        'target/sh4/cpu.c': ".pointer_wrap = cpu_pointer_wrap_notreached\n",
        'accel/tcg/tcg-accel-ops.c': "            err = cpu_breakpoint_insert(cpu, addr, BP_GDB, NULL);\n            if (err) {\n                break;\n            }\n        }\n        return err;\n",
        'hw/intc/sh_intc.c': "int x;\n",
        'hw/block/pflash_cfi02.c': "    uint8_t cmd;\n",
    }

    def _tree(self):
        t = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, t, True)
        for rel, txt in self.FILES.items():
            p = os.path.join(t, *rel.split('/'))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, 'w', encoding='utf-8', newline='') as f:
                f.write(txt)
        return t

    def _patch(self, t):
        env = dict(os.environ, CIC_QEMU=t, CIC_BUILD=os.path.join(t, 'nao-existe'), CIC_PATCH_ONLY='1')
        r = subprocess.run(['bash', BUILD_SH], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(r.returncode, 0, r.stderr.decode('utf-8', 'replace'))

    def _snapshot(self, t):
        out = {}
        for root, _, files in os.walk(t):
            for n in files:
                p = os.path.join(root, n)
                with open(p, 'rb') as f:
                    out[os.path.relpath(p, t)] = f.read()
        return out

    def test_patch_only_applies_and_is_idempotent(self):
        t = self._tree()
        self._patch(t)
        a = self._snapshot(t)
        self.assertIn(b'CONFIG_CIC', a[os.path.join('hw', 'sh4', 'meson.build')])
        self.assertIn(b'config CIC', a[os.path.join('hw', 'sh4', 'Kconfig')])
        self.assertIn(b'cic_sr_user', a[os.path.join('target', 'sh4', 'helper.c')])
        self.assertIn('instrução'.encode('utf-8'), a[os.path.join('target', 'sh4', 'helper.c')])       # UTF-8, não cp1252
        self.assertIn(b'sh4_cic_hypercall', a[os.path.join('target', 'sh4', 'cpu.h')])
        self.assertTrue(os.path.isfile(os.path.join(t, 'hw', 'sh4', 'cic_pci.c')))
        patched = [k for k in a if k.split(os.sep)[0] in ('target', 'accel') or k.startswith(os.path.join('hw', 'intc')) or k.startswith(os.path.join('hw', 'block'))]
        self.assertTrue(patched)
        self.assertFalse([k for k in patched if b'\r' in a[k]], 'o Python dos patches não pode gerar CRLF')
        self._patch(t)
        self.assertEqual(self._snapshot(t), a)

    def test_exe_suffix_follows_cic_exe(self):
        lines = [l for l in open(BUILD_SH, encoding='utf-8') if l.startswith('case "$(uname -s)"') or l.startswith('EXE=${CIC_EXE')]
        self.assertEqual(len(lines), 2)
        def exe(**env):
            r = subprocess.run(['bash', '-c', ''.join(lines) + 'echo "[$EXE]"'], env=dict(os.environ, **env), stdout=subprocess.PIPE, check=True)
            return r.stdout.decode().strip()
        self.assertEqual(exe(CIC_EXE='.exe'), '[.exe]')
        self.assertEqual(exe(CIC_EXE=''), '[]')

    def test_ninja_target_and_copy_use_the_suffix(self):
        txt = open(BUILD_SH, encoding='utf-8').read()
        self.assertIn('ninja qemu-system-sh4$EXE', txt)
        self.assertIn('"$B/qemu-system-sh4$EXE"', txt)
        self.assertNotIn("sed -i ''", txt)


class SourceMarkersTest(unittest.TestCase):
    """Os ramos de Windows do código C existem (não compila aqui: só garante que ninguém os apagou)."""

    def test_c_windows_branches(self):
        pci = open(os.path.join(ROOT, 'src', 'cic', 'cic_pci.c'), encoding='utf-8').read()
        c = open(os.path.join(ROOT, 'src', 'cic', 'cic.c'), encoding='utf-8').read()
        self.assertIn('CreateFileMappingA', pci)
        self.assertIn('FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE', pci)
        self.assertIn('AF_INET, SOCK_DGRAM', c)
        self.assertIn('cic_input_thread', c)
        self.assertIn('mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)', pci)      # o ramo POSIX continua


if __name__ == '__main__':
    unittest.main()
