#import "SidebarSpaceTransfer.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/nlist.h>
#import <string.h>

// Runtime-only bridge, following yabai's SIP-enabled transfer operation:
// https://github.com/asmvik/yabai/blob/master/src/space_manager.c
// Keep the API behind this boundary; never activate, restore or order windows here.
@interface NSObject (SidebarSpaceTransferInitialization)
- (instancetype)initWithWindows:(NSArray<NSNumber *> *)windows spaceID:(uint64_t)spaceID;
@end

static int64_t (*submitOperation)(void *);

// This is a local C++ symbol, absent from dlsym's exported-symbol lookup.
// Resolve the exact symbol from the loaded image, as yabai does in macho_dlsym.h.
// Do not scan instructions or guess addresses when an OS removes the symbol.
static void *findTransferOperation(void) {
    const char *symbolName = "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation";
    for (uint32_t image = 0; image < _dyld_image_count(); image++) {
        const char *name = _dyld_get_image_name(image);
        if (!name || !strstr(name, "/SkyLight.framework/") || strcmp(strrchr(name, '/'), "/SkyLight")) continue;
        const struct mach_header_64 *header = (const void *)_dyld_get_image_header(image);
        if (!header || header->magic != MH_MAGIC_64) return NULL;
        const uint8_t *cursor = (const uint8_t *)(header + 1);
        const uint8_t *end = cursor + header->sizeofcmds;
        const struct segment_command_64 *linkedit = NULL, *text = NULL;
        const struct symtab_command *symbols = NULL;
        for (uint32_t command = 0; command < header->ncmds; command++) {
            if ((size_t)(end - cursor) < sizeof(struct load_command)) return NULL;
            const struct load_command *load = (const void *)cursor;
            if (load->cmdsize < sizeof(*load) || load->cmdsize > (size_t)(end - cursor)) return NULL;
            if (load->cmd == LC_SEGMENT_64 && load->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *segment = (const void *)cursor;
                if (!strncmp(segment->segname, SEG_LINKEDIT, sizeof(segment->segname))) linkedit = segment;
                if (!strncmp(segment->segname, SEG_TEXT, sizeof(segment->segname))) text = segment;
            } else if (load->cmd == LC_SYMTAB && load->cmdsize >= sizeof(struct symtab_command)) {
                symbols = (const void *)cursor;
            }
            cursor += load->cmdsize;
        }
        if (!linkedit || !text || !symbols || linkedit->vmaddr < linkedit->fileoff) return NULL;
        uint64_t limit = linkedit->fileoff + linkedit->filesize;
        if (limit < linkedit->fileoff || symbols->symoff < linkedit->fileoff || symbols->stroff < linkedit->fileoff ||
            (uint64_t)symbols->symoff + (uint64_t)symbols->nsyms * sizeof(struct nlist_64) > limit ||
            (uint64_t)symbols->stroff + symbols->strsize > limit) return NULL;
        intptr_t slide = _dyld_get_image_vmaddr_slide(image);
        uintptr_t base = (uintptr_t)(linkedit->vmaddr - linkedit->fileoff + slide);
        const struct nlist_64 *table = (const void *)(base + symbols->symoff);
        const char *strings = (const void *)(base + symbols->stroff);
        for (uint32_t index = 0; index < symbols->nsyms; index++) {
            const struct nlist_64 *entry = &table[index];
            uint32_t offset = entry->n_un.n_strx;
            if ((entry->n_type & N_STAB) || (entry->n_type & N_TYPE) != N_SECT || offset >= symbols->strsize) continue;
            const char *candidate = strings + offset;
            if (!memchr(candidate, '\0', symbols->strsize - offset) || strcmp(candidate, symbolName)) continue;
            if (entry->n_value < text->vmaddr || entry->n_value - text->vmaddr >= text->vmsize) return NULL;
            return (void *)(uintptr_t)(entry->n_value + slide);
        }
        return NULL;
    }
    return NULL;
}

BOOL SidebarSpaceTransferIsAvailable(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (handle) submitOperation = findTransferOperation();
        // Keep the framework loaded while its function pointer is in use.
    });
    Class operationClass = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    return submitOperation && operationClass &&
        [operationClass instancesRespondToSelector:@selector(initWithWindows:spaceID:)];
}

BOOL SidebarSpaceTransferSubmit(uint32_t windowID, uint64_t desktopID) {
    if (!windowID || !desktopID || !SidebarSpaceTransferIsAvailable()) return NO;
    @try {
        Class operationClass = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
        id operation = [[operationClass alloc] initWithWindows:@[@(windowID)] spaceID:desktopID];
        if (!operation) return NO;
        submitOperation((__bridge void *)operation);
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}
