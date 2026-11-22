/*
 * memory-backend-winshm: RAM do guest em memória compartilhada nomeada do Windows (iDrive 8 / MGU22).
 *
 * No macOS o QEMU usa `memory-backend-shm` + `qemushm.dylib` para abrir o objeto POSIX que o Python criou, e o `mguhost` mapeia o mesmo objeto para ler os
 * anéis de comandos GL que o guest escreve. O Windows não tem shm_open: aqui a RAM é uma seção sem arquivo (CreateFileMapping sobre o arquivo de paginação) com
 * um nome. O IDEmu (Python, mmap.mmap(-1, n, tagname=nome)) a cria e já grava o initramfs nela; o QEMU (este backend) e o `mguhost` a abrem pelo nome.
 *
 *   -object memory-backend-winshm,id=m0,size=12288M,shm-name=idemu_ram_1234
 *
 * `shm-name` é o nome da seção (sem barra invertida). Se a seção ainda não existir, ela é criada (CreateFileMapping devolve a existente se o nome já está em uso).
 * O objeto some quando o último processo que o tem aberto fecha o handle: o Python mantém o dele aberto até o primeiro quadro.
 *
 * Também publica uma seção pequena "<shm-name>_info" com o pid do QEMU e o endereço onde a RAM foi mapeada: o mguhost usa os dois em QueryWorkingSetEx para
 * achar só as páginas que o guest já tocou (ler uma página nunca tocada de uma seção a aloca; a RAM do guest tem 12 GiB). Formato (mesmo de mguhost.c, WinShmInfo):
 *   uint32 magic (0x4d535749), uint32 pid, uint64 base, uint64 size.
 *
 * Escrito para o QEMU 11.1.2 (modelado em backends/hostmem-ram.c e hostmem-shm.c); só é compilado no Windows (tools/qemu/build-aarch64-windows.sh).
 */
#include "qemu/osdep.h"
#include "system/hostmem.h"
#include "qapi/error.h"
#include "qom/object_interfaces.h"
#include "qemu/module.h"
#include "qom/object.h"

#ifndef _WIN32
#error "hostmem-winshm.c é só para o Windows"
#endif

#define TYPE_MEMORY_BACKEND_WINSHM "memory-backend-winshm"

OBJECT_DECLARE_SIMPLE_TYPE(HostMemoryBackendWinShm, MEMORY_BACKEND_WINSHM)

struct HostMemoryBackendWinShm {
    HostMemoryBackend parent_obj;

    char *shm_name;
    HANDLE map;
    void *view;
};

typedef struct WinShmInfo {
    uint32_t magic;
    uint32_t pid;
    uint64_t base;
    uint64_t size;
} WinShmInfo;

#define WINSHM_INFO_MAGIC 0x4d535749u

static bool winshm_backend_memory_alloc(HostMemoryBackend *backend, Error **errp)
{
    HostMemoryBackendWinShm *s = MEMORY_BACKEND_WINSHM(backend);
    g_autofree char *name = NULL;
    g_autofree char *info_name = NULL;
    uint64_t size = backend->size;
    HANDLE ih;
    WinShmInfo *info;

    if (!size) {
        error_setg(errp, "can't create backend with size 0");
        return false;
    }
    if (!s->shm_name || !s->shm_name[0]) {
        error_setg(errp, "property 'shm-name' is required");
        return false;
    }
    if (strchr(s->shm_name, '\\')) {
        error_setg(errp, "property 'shm-name' must not contain a backslash");
        return false;
    }

    /* abre a seção criada pelo Python (ou cria, se não existir); os argumentos de tamanho valem só na criação */
    s->map = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE,
                                (DWORD)(size >> 32), (DWORD)(size & 0xffffffffu),
                                s->shm_name);
    if (!s->map) {
        error_setg_win32(errp, GetLastError(), "CreateFileMapping('%s') failed", s->shm_name);
        return false;
    }
    s->view = MapViewOfFile(s->map, FILE_MAP_ALL_ACCESS, 0, 0, (SIZE_T)size);
    if (!s->view) {
        error_setg_win32(errp, GetLastError(), "MapViewOfFile('%s', %" PRIu64 " bytes) failed", s->shm_name, size);
        CloseHandle(s->map);
        s->map = NULL;
        return false;
    }

    name = host_memory_backend_get_name(backend);
    memory_region_init_ram_ptr(&backend->mr, OBJECT(backend), name, size, s->view);

    /* seção de informação para o mguhost (o handle e a visão ficam abertos até o processo terminar) */
    info_name = g_strdup_printf("%s_info", s->shm_name);
    ih = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, 4096, info_name);
    if (ih) {
        info = MapViewOfFile(ih, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(*info));
        if (info) {
            info->pid = GetCurrentProcessId();
            info->base = (uint64_t)(uintptr_t)s->view;
            info->size = size;
            MemoryBarrier();
            info->magic = WINSHM_INFO_MAGIC;
        }
    }
    return true;
}

static char *winshm_get_shm_name(Object *obj, Error **errp)
{
    return g_strdup(MEMORY_BACKEND_WINSHM(obj)->shm_name);
}

static void winshm_set_shm_name(Object *obj, const char *value, Error **errp)
{
    HostMemoryBackendWinShm *s = MEMORY_BACKEND_WINSHM(obj);

    if (host_memory_backend_mr_inited(MEMORY_BACKEND(obj))) {
        error_setg(errp, "cannot change property 'shm-name' after the memory region is initialized");
        return;
    }
    g_free(s->shm_name);
    s->shm_name = g_strdup(value);
}

static void winshm_backend_instance_finalize(Object *obj)
{
    /* a seção e a visão ficam até o processo terminar (o bloco de RAM é RAM_PREALLOC e não desmapeia nada) */
    g_free(MEMORY_BACKEND_WINSHM(obj)->shm_name);
}

static void winshm_backend_class_init(ObjectClass *oc, const void *data)
{
    HostMemoryBackendClass *bc = MEMORY_BACKEND_CLASS(oc);

    bc->alloc = winshm_backend_memory_alloc;
    object_class_property_add_str(oc, "shm-name", winshm_get_shm_name, winshm_set_shm_name);
    object_class_property_set_description(oc, "shm-name", "Name of the Windows named file mapping (section) that holds the guest RAM");
}

static const TypeInfo winshm_backend_info = {
    .name = TYPE_MEMORY_BACKEND_WINSHM,
    .parent = TYPE_MEMORY_BACKEND,
    .instance_size = sizeof(HostMemoryBackendWinShm),
    .instance_finalize = winshm_backend_instance_finalize,
    .class_init = winshm_backend_class_init,
};

static void register_types(void)
{
    type_register_static(&winshm_backend_info);
}

type_init(register_types);
