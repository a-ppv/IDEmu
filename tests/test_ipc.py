import os
import shutil
import socket
import sys
import tempfile
import threading
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from idemu import ipc                          # noqa: E402


class PosixAddrTest(unittest.TestCase):
    """macOS/Linux: o endereço é o caminho do socket unix, como sempre foi."""

    def test_addr_is_path(self):
        with mock.patch.object(ipc, 'IS_WIN', False):
            self.assertEqual(ipc.addr('/tmp/x', 'gl.sock'), os.path.join('/tmp/x', 'gl.sock'))

    def test_chardev_unix(self):
        with mock.patch.object(ipc, 'IS_WIN', False):
            self.assertEqual(ipc.chardev('/tmp/x/ser.sock'), 'unix:/tmp/x/ser.sock,server,nowait')

    def test_ready_is_the_socket_file(self):
        d = tempfile.mkdtemp()
        try:
            with mock.patch.object(ipc, 'IS_WIN', False):
                self.assertFalse(ipc.ready(d, 'gl.sock'))
                open(os.path.join(d, 'gl.sock'), 'w').close()
                self.assertTrue(ipc.ready(d, 'gl.sock'))
        finally:
            shutil.rmtree(d, ignore_errors=True)


class WindowsAddrTest(unittest.TestCase):
    """Windows: cada ponto vira uma porta em 127.0.0.1, guardada em <nome>.port. (Roda em qualquer sistema: só usa TCP/UDP local.)"""

    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.p = mock.patch.object(ipc, 'IS_WIN', True)
        self.p.start()

    def tearDown(self):
        self.p.stop()
        shutil.rmtree(self.d, ignore_errors=True)

    def test_addr_is_stable_loopback_port(self):
        a = ipc.addr(self.d, 'gl.sock')
        self.assertTrue(a.startswith('127.0.0.1:'))
        self.assertEqual(ipc.addr(self.d, 'gl.sock'), a)                  # a mesma chamada devolve a mesma porta
        self.assertNotEqual(ipc.addr(self.d, 'ser.sock'), a)              # pontos diferentes, portas diferentes

    def test_new_dir_gets_new_port_file(self):
        a = ipc.addr(self.d, 'qmp.sock')
        self.assertTrue(os.path.isfile(os.path.join(self.d, 'qmp.sock.port')))
        self.assertEqual(int(open(os.path.join(self.d, 'qmp.sock.port')).read()), ipc.port_of(a))

    def test_chardev_tcp(self):
        self.assertEqual(ipc.chardev('127.0.0.1:4321'), 'tcp:127.0.0.1:4321,server,nowait')

    def test_ready_is_a_marker_file(self):
        self.assertFalse(ipc.ready(self.d, 'gl.sock'))
        open(os.path.join(self.d, 'gl.sock.ready'), 'w').close()
        self.assertTrue(ipc.ready(self.d, 'gl.sock'))

    def test_stream_roundtrip(self):
        a = ipc.addr(self.d, 'shell.sock')
        srv = ipc.listen(a)
        got = []

        def serve():
            c, _ = srv.accept()
            got.append(c.recv(16)); c.sendall(b'pong'); c.close()
        t = threading.Thread(target=serve); t.start()
        c = ipc.connect(a, 5)
        c.sendall(b'ping')
        self.assertEqual(c.recv(16), b'pong')
        t.join(5); c.close(); srv.close()
        self.assertEqual(got, [b'ping'])

    def test_datagram_roundtrip(self):
        a = ipc.addr(self.d, 'input.sock')
        rx = ipc.dgram_bind(a)
        rx.settimeout(3)
        tx = ipc.dgram_socket()
        ipc.dgram_send(tx, a, b'1 8 1')
        self.assertEqual(rx.recv(64), b'1 8 1')
        rx.close(); tx.close()

    def test_connect_refused_raises_after_timeout(self):
        a = ipc.addr(self.d, 'nada.sock')
        with self.assertRaises(RuntimeError):
            ipc.connect(a, 0.5)


class RunRootTest(unittest.TestCase):
    def test_posix(self):
        with mock.patch.object(ipc, 'IS_WIN', False), mock.patch.object(ipc.os, 'getuid', create=True, return_value=501):
            self.assertEqual(ipc.run_root(), '/tmp/idemu-501')

    def test_windows_uses_temp(self):
        with mock.patch.object(ipc, 'IS_WIN', True), mock.patch.object(ipc.getpass, 'getuser', return_value='ana'):
            r = ipc.run_root()
            self.assertTrue(r.startswith(tempfile.gettempdir()))
            self.assertTrue(r.endswith('idemu-ana'))


if __name__ == '__main__':
    unittest.main()
