/* winport.h: o que o glhost precisa para compilar no Windows nativo (MSYS2/MinGW-w64 + freeglut + GLEW + libpng).
   Só é incluído com _WIN32; macOS e Linux não o veem. Sockets: o QEMU e o glhost falam TCP/UDP em 127.0.0.1 (o AF_UNIX do Windows não tem datagrama). */
#ifndef IDEMU_WINPORT_H
#define IDEMU_WINPORT_H
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <io.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>            /* antes do `#define close`: ele declara close() */
#include <GL/glew.h>         /* antes de gl.h/glut.h: o opengl32.dll só exporta o OpenGL 1.1, o resto (FBO, shaders, VBO) vem por ponteiros */
#ifndef F_OK
#define F_OK 0
#endif
#ifndef MSG_DONTWAIT
#define MSG_DONTWAIT 0         /* o socket UDP é marcado não-bloqueante com ioctlsocket (ver main) */
#endif
#define poll(fds,n,ms) WSAPoll((fds),(ULONG)(n),(INT)(ms))
#define close closesocket      /* o glhost só chama close() em sockets */

/* "127.0.0.1:porta" -> sockaddr_in. Devolve 0 se o texto não tiver esse formato. */
static int win_parse_addr(const char *s, struct sockaddr_in *a){
  const char *c=s?strrchr(s,':'):0; if(!c) return 0;
  memset(a,0,sizeof *a); a->sin_family=AF_INET; a->sin_port=htons((unsigned short)atoi(c+1)); a->sin_addr.s_addr=htonl(INADDR_LOOPBACK); return 1; }
static void win_nonblock(SOCKET s){ u_long on=1; ioctlsocket(s,FIONBIO,&on); }
static void win_nodelay(SOCKET s){ int on=1; setsockopt(s,IPPROTO_TCP,TCP_NODELAY,(const char*)&on,sizeof on); }
/* o arquivo do quadro compartilhado: tamanho fixo, mapeado em leitura/escrita; o Python o abre de fora (compartilhamento total) */
static void *win_map_file(const char *path,size_t len){
  HANDLE fh=CreateFileA(path,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
  if(fh==INVALID_HANDLE_VALUE) return 0;
  HANDLE mh=CreateFileMappingA(fh,NULL,PAGE_READWRITE,(DWORD)((unsigned long long)len>>32),(DWORD)(len&0xffffffffu),NULL); if(!mh) return 0;
  void *p=MapViewOfFile(mh,FILE_MAP_ALL_ACCESS,0,0,len); return p; }
#endif
