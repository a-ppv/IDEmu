"""Diferenças entre o sistema anfitrião: macOS (o original), Linux e Linux dentro do WSL2 (Windows).

O macOS continua usando o caminho antigo (osascript, `open`, sysctl) direto em server.py / sysfiles.py / stats.py; este módulo só é
consultado quando o servidor NÃO roda no macOS. No Windows o IDEmu roda dentro do WSL2 (ver docs/WINDOWS.md): o servidor Python é
Linux, mas a pessoa usa Windows, então seletor de arquivos, "mostrar na pasta" e o navegador precisam atravessar para o Windows
(powershell.exe / explorer.exe / cmd.exe, que o WSL expõe por interoperabilidade).
"""
import base64
import os
import posixpath
import re
import shutil
import subprocess
import sys

IS_MAC = sys.platform == 'darwin'
IS_WIN = os.name == 'nt'                 # Windows nativo (python.exe); o WSL2 é Linux e cai nos ramos is_wsl()
CREATE_NO_WINDOW = 0x08000000

_WSL = None


def is_wsl():
    """True dentro do WSL (1 ou 2). Cacheado."""
    global _WSL
    if _WSL is None:
        _WSL = False
        if sys.platform.startswith('linux'):
            for p in ('/proc/sys/kernel/osrelease', '/proc/version'):
                try:
                    with open(p) as f:
                        if 'microsoft' in f.read().lower():
                            _WSL = True
                            break
                except OSError:
                    pass
    return _WSL


class PickerUnavailable(Exception):
    """Não há como abrir o seletor nativo neste sistema."""


def _wsl_cwd():
    # o interop do WSL reclama (e às vezes falha) quando o diretório atual é um caminho Linux
    return '/mnt/c' if os.path.isdir('/mnt/c') else None


def _run_win(cmd, timeout=30, **kw):
    return subprocess.run(cmd, cwd=_wsl_cwd(), capture_output=True, timeout=timeout, **kw)


def to_posix(winpath):
    """C:\\Users\\x -> /mnt/c/Users/x (wslpath). None se não der."""
    if not winpath:
        return None
    try:
        r = subprocess.run(['wslpath', '-u', winpath], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    out = r.stdout.strip()
    return out if r.returncode == 0 and out else None


def to_windows(path):
    """/mnt/c/Users/x -> C:\\Users\\x (wslpath -w). Caminhos do ext4 viram \\\\wsl.localhost\\... (o Explorer abre)."""
    try:
        r = subprocess.run(['wslpath', '-w', path], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    out = r.stdout.strip()
    return out if r.returncode == 0 and out else None


def short_work(env_dir, name='work'):
    """Pasta de trabalho curta. Os pacotes SWFL têm caminhos de até ~200 caracteres e o Windows limita o caminho completo a 260 (MAX_PATH):
    dentro de <env>\\work não cabem. No Windows usa <disco>:\\iw\\<id>\\<name>; fora dele, <env>/<name> como sempre."""
    if not IS_WIN:
        return os.path.join(env_dir, name)
    root = os.path.join(os.environ.get('SystemDrive', 'C:') + os.sep, 'iw', os.path.basename(os.path.normpath(env_dir))[:16], name)
    try:
        os.makedirs(os.path.dirname(root), exist_ok=True)
        return root
    except OSError:
        return os.path.join(env_dir, name)


def is_drvfs(path):
    """/mnt/<letra>/...: disco do Windows montado no WSL. Não aceita socket unix nem permissões de verdade: o ambiente (VM) não pode ficar lá."""
    if IS_WIN:                                           # Windows nativo: abspath poria "C:\" na frente de "/mnt/c"
        p = posixpath.normpath((path or '').replace('\\', '/'))
    else:
        p = os.path.abspath(os.path.expanduser(path or ''))
    return bool(re.match(r'^/mnt/[a-zA-Z](/|$)', p))


# ---------------------------------------------------------------------------------------------------------------------------
# Seletor de arquivos/pastas do Windows (a partir do WSL)
# ---------------------------------------------------------------------------------------------------------------------------
def _ps_quote(s):
    return "'" + str(s).replace("'", "''") + "'"


def pick_script(kind, prompt='', start_win=None):
    """Script PowerShell que abre o diálogo do Windows e imprime um caminho por linha (UTF-8). Nada impresso = cancelado."""
    owner = ('$o = New-Object System.Windows.Forms.Form; $o.TopMost = $true; $o.ShowInTaskbar = $false; '
             '$o.StartPosition = "CenterScreen"; $o.Opacity = 0; $o.Show(); $o.Activate(); ')
    pre = ("[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; Add-Type -AssemblyName System.Windows.Forms; "
           "[System.Windows.Forms.Application]::EnableVisualStyles(); " + owner)
    if kind == 'folder':
        body = ('$d = New-Object System.Windows.Forms.FolderBrowserDialog; $d.Description = %s; $d.ShowNewFolderButton = $true; ' % _ps_quote(prompt or '')
                + ('if (Test-Path -LiteralPath %s) { $d.SelectedPath = %s }; ' % (_ps_quote(start_win), _ps_quote(start_win)) if start_win else '')
                + 'if ($d.ShowDialog($o) -eq [System.Windows.Forms.DialogResult]::OK) { Write-Output $d.SelectedPath }; ')
    else:
        body = ('$d = New-Object System.Windows.Forms.OpenFileDialog; $d.Title = %s; $d.CheckFileExists = $true; $d.Multiselect = %s; '
                % (_ps_quote(prompt or ''), '$true' if kind == 'files' else '$false')
                + ('if (Test-Path -LiteralPath %s) { $d.InitialDirectory = %s }; ' % (_ps_quote(start_win), _ps_quote(start_win)) if start_win else '')
                + 'if ($d.ShowDialog($o) -eq [System.Windows.Forms.DialogResult]::OK) { $d.FileNames | ForEach-Object { Write-Output $_ } }; ')
    return pre + body + '$o.Close()'


def native_pick(kind, prompt='', start=None):
    """Seletor nativo fora do macOS. Mesmo contrato de server.native_pick: caminho (ou caminhos, um por linha) em POSIX; None se cancelado.
    Levanta PickerUnavailable se não houver diálogo."""
    if IS_WIN:                                           # Windows nativo: o mesmo diálogo, sem conversão de caminhos
        ps = shutil.which('powershell.exe') or shutil.which('powershell')
        if not ps:
            raise PickerUnavailable('powershell.exe não encontrado: digite o caminho')
        sp = os.path.expanduser(start) if start else None
        script = pick_script(kind, prompt, sp if sp and os.path.isdir(sp) else None)
        enc = base64.b64encode(script.encode('utf-16-le')).decode('ascii')
        try:
            r = subprocess.run([ps, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-STA', '-EncodedCommand', enc],
                               capture_output=True, timeout=900, creationflags=CREATE_NO_WINDOW)
        except subprocess.TimeoutExpired:
            return None
        if r.returncode != 0:
            raise PickerUnavailable('não foi possível abrir o seletor do Windows: %s' % (r.stderr or b'').decode('utf-8', 'replace').strip()[:160])
        paths = [l.strip().lstrip('﻿') for l in (r.stdout or b'').decode('utf-8', 'replace').splitlines() if l.strip()]
        if not paths:
            return None
        return '\n'.join(paths) if kind == 'files' else paths[0]
    if not is_wsl():
        raise PickerUnavailable('seletor nativo indisponível neste sistema: digite o caminho')
    ps = shutil.which('powershell.exe') or '/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
    if not os.path.exists(ps):
        raise PickerUnavailable('powershell.exe do Windows não encontrado a partir do WSL (interoperabilidade desligada?): digite o caminho')
    start_win = None
    if start:
        sp = os.path.expanduser(start)
        if os.path.isdir(sp) and is_drvfs(sp):          # só pastas de discos do Windows: um caminho \\wsl.localhost\ não serve de ponto de partida do diálogo
            start_win = to_windows(sp)
    script = pick_script(kind, prompt, start_win)
    enc = base64.b64encode(script.encode('utf-16-le')).decode('ascii')
    try:
        r = _run_win([ps, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-STA', '-EncodedCommand', enc], timeout=900)
    except subprocess.TimeoutExpired:
        return None
    if r.returncode != 0:
        err = (r.stderr or b'').decode('utf-8', 'replace').strip()[:160]
        raise PickerUnavailable('não foi possível abrir o seletor do Windows: %s' % err)
    paths = []
    for line in (r.stdout or b'').decode('utf-8', 'replace').splitlines():
        line = line.strip().lstrip('\ufeff')
        if not line:
            continue
        p = to_posix(line)
        if p:
            paths.append(p)
    if not paths:
        return None
    return '\n'.join(paths) if kind == 'files' else paths[0]


# ---------------------------------------------------------------------------------------------------------------------------
# "Mostrar na pasta" e abrir o navegador
# ---------------------------------------------------------------------------------------------------------------------------
def reveal(path, select=False):
    """Abre a pasta (ou seleciona o arquivo) no Explorer (Windows/WSL) ou no gerenciador de arquivos (Linux). Levanta OSError se não conseguir."""
    if IS_WIN:
        p = os.path.normpath(path)
        # o explorer.exe devolve código 1 mesmo quando abre: não olhar o retorno
        subprocess.Popen(['explorer.exe', '/select,' + p] if select else ['explorer.exe', p])
        return
    if is_wsl():
        wp = to_windows(path)
        if not wp:
            raise OSError('wslpath falhou para %s' % path)
        exe = shutil.which('explorer.exe') or '/mnt/c/Windows/explorer.exe'
        # o explorer.exe devolve código 1 mesmo quando abre: não olhar o retorno
        _run_win([exe, '/select,' + wp] if select else [exe, wp], timeout=15)
        return
    opener = shutil.which('xdg-open')
    if not opener:
        raise OSError('xdg-open não encontrado')
    d = os.path.dirname(path) if select else path
    subprocess.Popen([opener, d], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def open_url(url):
    """Abre o endereço no navegador do sistema (no WSL, o do Windows)."""
    if IS_WIN:
        try:
            os.startfile(url)                     # navegador padrão do Windows
            return True
        except OSError:
            import webbrowser
            return webbrowser.open(url)
    if is_wsl():
        for cand in (['wslview', url], ['cmd.exe', '/c', 'start', '', url]):
            if shutil.which(cand[0]):
                try:
                    subprocess.Popen(cand, cwd=_wsl_cwd(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    return True
                except OSError:
                    continue
        return False
    opener = shutil.which('xdg-open')
    if opener:
        subprocess.Popen([opener, url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    return False


def host_ram_mb():
    """RAM total visível (MB) em Linux/WSL, via /proc/meminfo, ou no Windows via GlobalMemoryStatusEx; 0 se não souber."""
    if IS_WIN:
        try:
            import ctypes

            class MEMORYSTATUSEX(ctypes.Structure):
                _fields_ = [('dwLength', ctypes.c_ulong), ('dwMemoryLoad', ctypes.c_ulong), ('ullTotalPhys', ctypes.c_ulonglong),
                            ('ullAvailPhys', ctypes.c_ulonglong), ('ullTotalPageFile', ctypes.c_ulonglong), ('ullAvailPageFile', ctypes.c_ulonglong),
                            ('ullTotalVirtual', ctypes.c_ulonglong), ('ullAvailVirtual', ctypes.c_ulonglong), ('sullAvailExtendedVirtual', ctypes.c_ulonglong)]
            m = MEMORYSTATUSEX(); m.dwLength = ctypes.sizeof(m)
            if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(m)):
                return int(m.ullTotalPhys) // (1 << 20)
        except Exception:
            pass
        return 0
    try:
        with open('/proc/meminfo') as f:
            for line in f:
                if line.startswith('MemTotal:'):
                    return int(line.split()[1]) // 1024
    except (OSError, ValueError, IndexError):
        pass
    return 0


# ---------------------------------------------------------------------------------------------------------------------------
# Processos (CPU/RAM) e links de arquivo
# ---------------------------------------------------------------------------------------------------------------------------
def proc_info(pids):
    """{pid: (segundos_de_cpu, rss_kb, vsz_kb)} de processos nossos. No Windows usa a API do sistema (ctypes); no resto, `ps`."""
    pids = [p for p in pids if p]
    out = {}
    if not pids:
        return out
    if IS_WIN:
        import ctypes
        from ctypes import wintypes
        k32 = ctypes.windll.kernel32
        k32.OpenProcess.restype = wintypes.HANDLE
        try:
            psapi = ctypes.windll.psapi
        except OSError:
            psapi = None

        class FT(ctypes.Structure):
            _fields_ = [('lo', wintypes.DWORD), ('hi', wintypes.DWORD)]

        class PMC(ctypes.Structure):
            _fields_ = [('cb', wintypes.DWORD), ('PageFaultCount', wintypes.DWORD), ('PeakWorkingSetSize', ctypes.c_size_t),
                        ('WorkingSetSize', ctypes.c_size_t), ('QuotaPeakPagedPoolUsage', ctypes.c_size_t), ('QuotaPagedPoolUsage', ctypes.c_size_t),
                        ('QuotaPeakNonPagedPoolUsage', ctypes.c_size_t), ('QuotaNonPagedPoolUsage', ctypes.c_size_t),
                        ('PagefileUsage', ctypes.c_size_t), ('PeakPagefileUsage', ctypes.c_size_t)]
        for pid in pids:
            h = k32.OpenProcess(0x1000 | 0x0400, False, int(pid))        # QUERY_LIMITED_INFORMATION | QUERY_INFORMATION
            if not h:
                continue
            try:
                c, e, kt, ut = FT(), FT(), FT(), FT()
                if not k32.GetProcessTimes(h, ctypes.byref(c), ctypes.byref(e), ctypes.byref(kt), ctypes.byref(ut)):
                    continue
                t = (((kt.hi << 32) | kt.lo) + ((ut.hi << 32) | ut.lo)) / 1e7
                rss = vsz = 0
                if psapi:
                    pm = PMC(); pm.cb = ctypes.sizeof(pm)
                    if psapi.GetProcessMemoryInfo(h, ctypes.byref(pm), pm.cb):
                        rss, vsz = pm.WorkingSetSize // 1024, pm.PagefileUsage // 1024
                out[int(pid)] = (t, rss, vsz)
            finally:
                k32.CloseHandle(h)
        return out
    try:
        txt = subprocess.run(['ps', '-o', 'pid=,time=,rss=,vsz=', '-p', ','.join(str(p) for p in pids)], capture_output=True, text=True, timeout=3).stdout
    except Exception:
        return out
    for line in txt.splitlines():
        f = line.split()
        if len(f) >= 4:
            try:
                t = 0.0
                for part in f[1].split(':'):
                    t = t * 60 + float(part)
                out[int(f[0])] = (t, int(f[2]), int(f[3]))
            except ValueError:
                pass
    return out


_JOB = None


def adopt_child(proc):
    """Windows: coloca o processo num job object com KILL_ON_JOB_CLOSE, então ele morre quando o servidor do IDEmu morre (janela fechada à força,
    kill...). Nos outros sistemas não faz nada. Nunca levanta."""
    global _JOB
    if not IS_WIN:
        return
    try:
        import ctypes
        from ctypes import wintypes
        k32 = ctypes.windll.kernel32
        if _JOB is None:
            class BASIC(ctypes.Structure):
                _fields_ = [('PerProcessUserTimeLimit', ctypes.c_int64), ('PerJobUserTimeLimit', ctypes.c_int64), ('LimitFlags', wintypes.DWORD),
                            ('MinimumWorkingSetSize', ctypes.c_size_t), ('MaximumWorkingSetSize', ctypes.c_size_t), ('ActiveProcessLimit', wintypes.DWORD),
                            ('Affinity', ctypes.c_size_t), ('PriorityClass', wintypes.DWORD), ('SchedulingClass', wintypes.DWORD)]

            class IOC(ctypes.Structure):
                _fields_ = [(n, ctypes.c_uint64) for n in ('ReadOperationCount', 'WriteOperationCount', 'OtherOperationCount',
                                                           'ReadTransferCount', 'WriteTransferCount', 'OtherTransferCount')]

            class EXT(ctypes.Structure):
                _fields_ = [('BasicLimitInformation', BASIC), ('IoInfo', IOC), ('ProcessMemoryLimit', ctypes.c_size_t), ('JobMemoryLimit', ctypes.c_size_t),
                            ('PeakProcessMemoryUsed', ctypes.c_size_t), ('PeakJobMemoryUsed', ctypes.c_size_t)]
            k32.CreateJobObjectW.restype = wintypes.HANDLE
            job = k32.CreateJobObjectW(None, None)
            info = EXT()
            info.BasicLimitInformation.LimitFlags = 0x2000                  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            k32.SetInformationJobObject(wintypes.HANDLE(job), 9, ctypes.byref(info), ctypes.sizeof(info))      # 9 = JobObjectExtendedLimitInformation
            _JOB = job
        k32.AssignProcessToJobObject(wintypes.HANDLE(_JOB), wintypes.HANDLE(int(proc._handle)))
    except Exception:
        pass


def link_path(src, dst):
    """Liga `dst` a `src` (arquivo ou pasta). POSIX: link simbólico. Windows: link simbólico se o sistema deixar; senão junção (pasta) ou
    hardlink/cópia (arquivo), que não pedem privilégio. Levanta OSError se nada servir."""
    try:
        os.symlink(src, dst, target_is_directory=os.path.isdir(src))
        return
    except (OSError, NotImplementedError):
        if not IS_WIN:
            raise
    if os.path.isdir(src):
        r = subprocess.run(['cmd', '/c', 'mklink', '/J', dst, src], capture_output=True, creationflags=CREATE_NO_WINDOW)
        if r.returncode:
            raise OSError('mklink /J falhou: %s' % (r.stdout + r.stderr).decode('mbcs', 'replace').strip()[:160])
        return
    try:
        os.link(src, dst)
    except OSError:
        shutil.copyfile(src, dst)
