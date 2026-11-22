"""Transporte local entre o IDEmu, o QEMU e o renderizador (glhost).

macOS e Linux: sockets unix (um caminho de arquivo é o endereço), exatamente como sempre foi.
Windows nativo: o `AF_UNIX` do Windows não tem datagrama e o QEMU/glhost de lá falam TCP/UDP, então cada ponto de comunicação vira uma porta
em 127.0.0.1 e o endereço é a cadeia "127.0.0.1:PORTA". Todo o resto do IDEmu usa só as funções deste módulo: o endereço é opaco.

    addr(pasta, 'ser.sock')      endereço do ponto 'ser.sock' da pasta (caminho no POSIX; porta reservada no Windows)
    connect / listen / dgram_*   sockets conforme o sistema
    chardev(addr)                texto do `-serial` / `-qmp` do QEMU para esse endereço
    ready(pasta, nome)           o servidor do ponto já está de pé? (arquivo no POSIX; arquivo .ready no Windows)
"""
import getpass
import os
import socket
import tempfile
import threading
import time

IS_WIN = os.name == 'nt'
LOOPBACK = '127.0.0.1'
_lock = threading.Lock()
_RESERVED = {'con', 'prn', 'aux', 'nul'} | {'com%d' % i for i in range(1, 10)} | {'lpt%d' % i for i in range(1, 10)}


def run_root():
    """Pasta dos temporários da execução (sockets, quadro, controle)."""
    if IS_WIN:
        try:
            user = getpass.getuser()
        except Exception:
            user = 'user'
        return os.path.join(tempfile.gettempdir(), 'idemu-%s' % ''.join(c for c in user if c.isalnum() or c in '-_') or 'idemu-user')
    return '/tmp/idemu-%d' % os.getuid()


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind((LOOPBACK, 0))
        return s.getsockname()[1]
    finally:
        s.close()


def addr(d, name):
    """Endereço do ponto de comunicação `name` da pasta `d`. No Windows a porta é reservada na primeira chamada e guardada em <name>.port."""
    path = os.path.join(d, name)
    if not IS_WIN:
        return path
    if name.split('.')[0].lower() in _RESERVED:                   # CON, AUX, NUL...: no Windows são dispositivos, mesmo com extensão (abrir con.sock.port lê o teclado)
        raise ValueError('nome reservado do Windows: ' + name)
    pf = path + '.port'
    with _lock:
        try:
            with open(pf) as f:
                return '%s:%d' % (LOOPBACK, int(f.read().strip()))
        except (OSError, ValueError):
            pass
        os.makedirs(d, exist_ok=True)
        port = free_port()
        tmp = pf + '.tmp'
        with open(tmp, 'w') as f:
            f.write(str(port))
        os.replace(tmp, pf)
        return '%s:%d' % (LOOPBACK, port)


def port_of(a):
    return int(a.rsplit(':', 1)[1])


def ready(d, name):
    p = os.path.join(d, name)
    return os.path.exists(p + '.ready') if IS_WIN else os.path.exists(p)


def _unix():
    return socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)


def connect_once(a):
    """Conecta (fluxo). Levanta OSError se ninguém atende."""
    if IS_WIN:
        s = socket.create_connection((LOOPBACK, port_of(a)), timeout=2)
        s.settimeout(None)
        try:
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        return s
    s = _unix()
    try:
        s.connect(a)
    except OSError:
        s.close()
        raise
    return s


def connect(a, timeout=30):
    """Tenta conectar até `timeout` s (o QEMU/glhost ainda estão subindo)."""
    end = time.time() + timeout
    while time.time() < end:
        try:
            return connect_once(a)
        except OSError:
            time.sleep(0.2)
    raise RuntimeError('não conectou em ' + a)


def listen(a, backlog=8):
    """Socket de fluxo servidor no endereço."""
    if IS_WIN:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind((LOOPBACK, port_of(a)))
        s.listen(backlog)
        return s
    try:
        os.unlink(a)
    except OSError:
        pass
    s = _unix()
    s.bind(a)
    s.listen(backlog)
    return s


def dgram_socket():
    return socket.socket(socket.AF_INET if IS_WIN else socket.AF_UNIX, socket.SOCK_DGRAM)


def dgram_bind(a):
    """Socket de datagramas ligado ao endereço (recebe)."""
    s = dgram_socket()
    if IS_WIN:
        s.bind((LOOPBACK, port_of(a)))
    else:
        try:
            os.unlink(a)
        except OSError:
            pass
        s.bind(a)
    return s


def dgram_send(s, a, data):
    s.sendto(data, (LOOPBACK, port_of(a)) if IS_WIN else a)


def chardev(a):
    """Argumento do `-serial` / `-qmp` do QEMU que serve neste endereço (o QEMU escuta; o IDEmu conecta)."""
    if IS_WIN:
        return 'tcp:%s:%d,server,nowait' % (LOOPBACK, port_of(a))
    return 'unix:%s,server,nowait' % a


def shutdown_close(s):
    """Fecha acordando quem está bloqueado em accept()/recv() (no Windows o close() sozinho não acorda)."""
    if s is None:
        return
    try:
        s.shutdown(socket.SHUT_RDWR)
    except Exception:
        pass
    try:
        s.close()
    except Exception:
        pass
