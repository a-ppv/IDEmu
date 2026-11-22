/* winport7.h: o que o glhost7 (iDrive 7) precisa para compilar no Windows nativo (MSYS2/MinGW-w64 + GLEW). Só é incluído com _WIN32.
   Reaproveita src/glhost/winport.h (winsock, windows.h, GLEW antes do GL, win_parse_addr/win_nodelay) e acrescenta o que é só do glhost7:
   memória compartilhada NOMEADA do QEMU (OpenFileMapping), arquivo do quadro que pode crescer, relógio e esperas.
   Sem freeglut: o contexto OpenGL 4.1 core vem de uma janela oculta + WGL (ver init_gl em glhost7.c).
   Atenção: winport.h faz `#define close closesocket` e `#define poll WSAPoll`: o glhost7 só chama close() em sockets. */
#ifndef IDEMU_WINPORT7_H
#define IDEMU_WINPORT7_H
#include "../glhost/winport.h"
#include <mmsystem.h>          /* timeBeginPeriod (link: -lwinmm) */
#include <direct.h>            /* _mkdir */

#ifndef usleep
#define usleep(us) Sleep((DWORD)(((us) + 999) / 1000))     /* o usleep do mingw varia entre versões; Sleep(1) com timeBeginPeriod(1) dá ~1 ms */
#endif
#define memmem w7_memmem
static void *w7_memmem(const void *h, size_t hl, const void *n, size_t nl) {
  const unsigned char *a = (const unsigned char *)h, *b = (const unsigned char *)n;
  if (!nl) return (void *)a;
  for (size_t i = 0; hl >= nl && i <= hl - nl; i++) if (a[i] == b[0] && !memcmp(a + i, b, nl)) return (void *)(a + i);
  return NULL;
}

/* "/idemu-gl-123" (valor de shm-name= do QEMU) -> "Local\idemu-gl-123", o nome do mapeamento que o QEMU cria (src/qemu/idemu-shm.c) */
static void w7_shm_name(const char *name, char *out, size_t cap) { snprintf(out, cap, "Local\\%s", name[0] == '/' ? name + 1 : name); }

/* abre o mapeamento do QEMU (ele o cria ao subir; tenta por até 2 min) e mapeia `size` bytes; NULL se não achar */
static void *w7_open_shm(const char *name, size_t size) {
  char wn[300]; w7_shm_name(name, wn, sizeof wn);
  HANDLE h = NULL;
  for (int i = 0; i < 1200 && !h; i++) { h = OpenFileMappingA(FILE_MAP_ALL_ACCESS, FALSE, wn); if (!h) Sleep(100); }
  if (!h) return NULL;
  void *m = NULL;
  for (int i = 0; i < 600 && !m; i++) { m = MapViewOfFile(h, FILE_MAP_ALL_ACCESS, 0, 0, size); if (!m) Sleep(100); }
  CloseHandle(h);          /* a visão continua válida; o objeto vive enquanto o QEMU o segurar */
  return m;
}

/* arquivo do quadro (<saida>/frame.rgba): só cresce (o IDEmu o mantém mapeado), tamanho mínimo fixo para quase nunca precisar crescer.
   Devolve a visão e o tamanho total em *got; a visão e o mapeamento anteriores só são soltos depois que o novo existe. */
static HANDLE w7_fm_file = INVALID_HANDLE_VALUE, w7_fm_map = NULL; static void *w7_fm_view = NULL;
static void *w7_map_frame(const char *path, size_t need, size_t *got) {
  size_t minlen = 64 + (size_t)1920 * 1080 * 4;
  HANDLE fh = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (fh == INVALID_HANDLE_VALUE) return NULL;
  LARGE_INTEGER cur; cur.QuadPart = 0; GetFileSizeEx(fh, &cur);
  size_t len = need > minlen ? need : minlen; if ((size_t)cur.QuadPart > len) len = (size_t)cur.QuadPart;
  HANDLE mh = CreateFileMappingA(fh, NULL, PAGE_READWRITE, (DWORD)((unsigned long long)len >> 32), (DWORD)(len & 0xffffffffu), NULL);
  if (!mh) { CloseHandle(fh); return NULL; }
  void *v = MapViewOfFile(mh, FILE_MAP_ALL_ACCESS, 0, 0, len);
  if (!v) { CloseHandle(mh); CloseHandle(fh); return NULL; }
  if (w7_fm_view) UnmapViewOfFile(w7_fm_view);
  if (w7_fm_map) CloseHandle(w7_fm_map);
  if (w7_fm_file != INVALID_HANDLE_VALUE) CloseHandle(w7_fm_file);
  w7_fm_file = fh; w7_fm_map = mh; w7_fm_view = v; *got = len;
  return v;
}
#endif
