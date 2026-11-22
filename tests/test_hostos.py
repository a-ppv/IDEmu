import os
import sys
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from idemu import hostos                       # noqa: E402


class FakeRun:
    def __init__(self, out=b'', code=0, err=b''):
        self.stdout, self.returncode, self.stderr = out, code, err


class DrvfsTest(unittest.TestCase):
    def test_windows_drives_are_drvfs(self):
        for p in ('/mnt/c', '/mnt/c/', '/mnt/c/Users/x', '/mnt/D/dados'):
            self.assertTrue(hostos.is_drvfs(p), p)

    def test_linux_paths_are_not(self):
        for p in ('/home/u/IDEmu', '/mnt/wsl/x', '/mnt', '/mnt/cc/x', '/tmp'):
            self.assertFalse(hostos.is_drvfs(p), p)


class PickScriptTest(unittest.TestCase):
    def test_folder_script(self):
        s = hostos.pick_script('folder', 'Escolha a pasta')
        self.assertIn('FolderBrowserDialog', s)
        self.assertIn('OutputEncoding', s)                       # caminhos com acento voltam em UTF-8
        self.assertNotIn('OpenFileDialog', s)

    def test_files_script_is_multiselect(self):
        s = hostos.pick_script('files', 'x')
        self.assertIn('OpenFileDialog', s)
        self.assertIn('Multiselect = $true', s)

    def test_single_file_script(self):
        self.assertIn('Multiselect = $false', hostos.pick_script('file', 'x'))

    def test_quotes_are_escaped(self):
        s = hostos.pick_script('folder', "it's a 'test'")
        self.assertIn("'it''s a ''test'''", s)

    def test_start_folder_only_when_given(self):
        self.assertNotIn('SelectedPath = ', hostos.pick_script('folder', 'x'))
        self.assertIn("SelectedPath = 'C:\\Users\\me'", hostos.pick_script('folder', 'x', 'C:\\Users\\me'))


class NativePickTest(unittest.TestCase):
    def test_not_wsl_raises(self):
        with mock.patch.object(hostos, 'IS_WIN', False), mock.patch.object(hostos, 'is_wsl', return_value=False):
            with self.assertRaises(hostos.PickerUnavailable):
                hostos.native_pick('folder', 'x')

    def _pick(self, kind, out, code=0, err=b''):
        conv = {'C:\\a\\b': '/mnt/c/a/b', 'C:\\a\\c.bin': '/mnt/c/a/c.bin'}
        with mock.patch.object(hostos, 'IS_WIN', False), mock.patch.object(hostos, 'is_wsl', return_value=True), \
                mock.patch.object(hostos.shutil, 'which', return_value='/mnt/c/Windows/System32/powershell.exe'), \
                mock.patch.object(hostos.os.path, 'exists', return_value=True), \
                mock.patch.object(hostos, '_run_win', return_value=FakeRun(out, code, err)) as run, \
                mock.patch.object(hostos, 'to_posix', side_effect=lambda p: conv.get(p)):
            return hostos.native_pick(kind, 'x'), run

    def test_folder_is_converted_to_posix(self):
        r, run = self._pick('folder', b'C:\\a\\b\r\n')
        self.assertEqual(r, '/mnt/c/a/b')
        self.assertIn('-EncodedCommand', run.call_args[0][0])    # o script vai codificado: sem problema de aspas

    def test_cancel_is_none(self):
        r, _ = self._pick('folder', b'')
        self.assertIsNone(r)

    def test_files_are_newline_separated(self):
        r, _ = self._pick('files', b'C:\\a\\b\r\nC:\\a\\c.bin\r\n')
        self.assertEqual(r, '/mnt/c/a/b\n/mnt/c/a/c.bin')

    def test_failure_is_reported(self):
        with self.assertRaises(hostos.PickerUnavailable):
            self._pick('folder', b'', 1, b'boom')


class WindowsNativeTest(unittest.TestCase):
    """Windows nativo (python.exe): o seletor roda o PowerShell direto e os caminhos ficam como o Windows os escreve."""

    def _pick(self, kind, out, code=0):
        with mock.patch.object(hostos, 'IS_WIN', True), mock.patch.object(hostos.shutil, 'which', return_value='powershell.exe'), \
                mock.patch.object(hostos.subprocess, 'run', return_value=FakeRun(out, code, b'boom')) as run, \
                mock.patch.object(hostos, 'CREATE_NO_WINDOW', 0):
            return hostos.native_pick(kind, 'x'), run

    def test_folder_keeps_windows_path(self):
        r, run = self._pick('folder', b'C:\\a\\b\r\n')
        self.assertEqual(r, 'C:\\a\\b')
        self.assertIn('-EncodedCommand', run.call_args[0][0])

    def test_cancel_is_none(self):
        self.assertIsNone(self._pick('folder', b'')[0])

    def test_files_newline_separated(self):
        self.assertEqual(self._pick('files', b'C:\\a\\b\r\nC:\\a\\c.bin\r\n')[0], 'C:\\a\\b\nC:\\a\\c.bin')

    def test_failure_is_reported(self):
        with self.assertRaises(hostos.PickerUnavailable):
            self._pick('folder', b'', 1)

    def test_link_path_falls_back_to_hardlink(self):
        with mock.patch.object(hostos, 'IS_WIN', True), mock.patch.object(hostos.os, 'symlink', side_effect=OSError('sem privilegio')), \
                mock.patch.object(hostos.os.path, 'isdir', return_value=False), mock.patch.object(hostos.os, 'link') as ln:
            hostos.link_path('C:\\a.bin', 'C:\\b.bin')
            ln.assert_called_once_with('C:\\a.bin', 'C:\\b.bin')

    def test_link_path_posix_still_raises(self):
        with mock.patch.object(hostos, 'IS_WIN', False), mock.patch.object(hostos.os, 'symlink', side_effect=OSError('x')):
            with self.assertRaises(OSError):
                hostos.link_path('/a', '/b')


class RamTest(unittest.TestCase):
    def test_meminfo(self):
        from unittest.mock import mock_open
        with mock.patch.object(hostos, 'IS_WIN', False), mock.patch('builtins.open', mock_open(read_data='MemTotal:       8388608 kB\nMemFree: 1 kB\n')):
            self.assertEqual(hostos.host_ram_mb(), 8192)

    def test_missing_meminfo(self):
        with mock.patch.object(hostos, 'IS_WIN', False), mock.patch('builtins.open', side_effect=OSError):
            self.assertEqual(hostos.host_ram_mb(), 0)


class ServerDispatchTest(unittest.TestCase):
    """O servidor so desvia para hostos fora do macOS; no macOS o caminho antigo (osascript) continua o mesmo."""

    def setUp(self):
        from idemu import server
        self.server = server

    def test_non_mac_uses_hostos(self):
        with mock.patch.object(hostos, 'IS_MAC', False), mock.patch.object(hostos, 'native_pick', return_value='/mnt/c/x') as p:
            self.assertEqual(self.server.native_pick('folder', 'x', None), '/mnt/c/x')
            p.assert_called_once()

    def test_non_mac_picker_unavailable_is_501(self):
        with mock.patch.object(hostos, 'IS_MAC', False), \
                mock.patch.object(hostos, 'native_pick', side_effect=hostos.PickerUnavailable('sem seletor')):
            with self.assertRaises(self.server.ApiError) as cm:
                self.server.native_pick('folder', 'x', None)
            self.assertEqual(cm.exception.code, 501)

    def test_mac_still_uses_osascript(self):
        with mock.patch.object(hostos, 'IS_MAC', True), mock.patch.object(hostos, 'native_pick') as p, \
                mock.patch('subprocess.run', return_value=FakeRun(b'', 0)) as run:
            run.return_value.stdout = '/Users/me/pasta/\n'
            self.assertEqual(self.server.native_pick('folder', 'x', None), '/Users/me/pasta/')
            p.assert_not_called()
            self.assertEqual(run.call_args[0][0][0], 'osascript')


if __name__ == '__main__':
    unittest.main()
