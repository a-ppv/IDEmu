// Canal guest <-> host do iDrive 8: dois anéis em memória travada do processo guest. O host encontra o
// cabeçalho varrendo a RAM do guest (arquivo compartilhado com o QEMU) e traduz cada página pelo PFN.
#ifndef IDEMU_CHAN_H
#define IDEMU_CHAN_H
#define CH_MAGIC "IDEMU-MGU-CHAN-1"
#define CH_RING_A (16u << 20)  // guest -> host
#define CH_RING_B (8u << 20)   // host -> guest
#define CH_PAGE 4096u
#define CH_MAXTABLE 64
// O cabeçalho é escrito pelo guest (Linux aarch64, LP64: unsigned long = 8 bytes). No host Windows (LLP64) unsigned long tem 4 bytes: lá o tipo de 8 bytes é explícito.
#ifdef _WIN32
typedef unsigned long long ch_ul;
#else
typedef unsigned long ch_ul;
#endif
typedef struct ch_hdr {
  char magic[16];
  unsigned version, pages_a, pages_b, ntable;
  ch_ul nonce;
  unsigned pid, tid, role;  // role: 0 = GL, 1 = comandos do host para um daemon do guest
  unsigned table_pfn[CH_MAXTABLE];  // páginas com a tabela u32 pfn[pages_a + pages_b]
  volatile ch_ul a_wr __attribute__((aligned(64)));
  volatile ch_ul a_rd __attribute__((aligned(64)));
  volatile ch_ul b_wr __attribute__((aligned(64)));
  volatile ch_ul b_rd __attribute__((aligned(64)));
} ch_hdr;
_Static_assert(sizeof(ch_hdr) <= CH_PAGE, "cabecalho");
#endif
