// hook.c - minimal arm64 inline function hooking for Tessera's Steam integration.
//
// th_hook(target, replacement, &orig) overwrites the first 16 bytes of target with an absolute jump to replacement
// (LDR X16, #8 ; BR X16 ; .quad replacement). The four instructions it displaces are copied into a trampoline that
// then jumps back to target+16, so calling *orig runs the original function. PC-relative instructions among the
// displaced four are rewritten for their new address (ADRP, ADR, B, BL, LDR literal); anything else that is
// PC-relative (B.cond, CBZ/CBNZ, TBZ/TBNZ) makes th_hook refuse, rather than risk a wrong branch.
// X16 is the intra-procedure-call scratch register, free at a function's entry by the arm64 calling convention.
#if defined(__arm64__)
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "hook.h"

#define TRAMP_SLOT 128          // bytes per trampoline (4 relocated instructions, up to 16 bytes each, + jump back)

static uint8_t *tramp_page;
static size_t tramp_used;

static uint32_t *tramp_alloc(void) {
    size_t page = (size_t)getpagesize();
    if (!tramp_page || tramp_used + TRAMP_SLOT > page) {
        void *p = mmap(NULL, page, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
        if (p == MAP_FAILED) return NULL;
        tramp_page = p;
        tramp_used = 0;
    }
    uint32_t *slot = (uint32_t *)(tramp_page + tramp_used);
    tramp_used += TRAMP_SLOT;
    return slot;
}

// Emits "LDR Xd, #8 ; B #12 ; .quad value" (materialise a 64-bit constant), returns words written.
static int emit_mov_abs(uint32_t *out, unsigned rd, uint64_t value) {
    out[0] = 0x58000040u | rd;          // ldr xd, #8
    out[1] = 0x14000003u;               // b #12
    memcpy(&out[2], &value, 8);
    return 4;
}

// Emits "LDR X16, #8 ; BR X16 ; .quad target".
static int emit_jump_abs(uint32_t *out, uint64_t target) {
    out[0] = 0x58000050u;               // ldr x16, #8
    out[1] = 0xD61F0200u;               // br x16
    memcpy(&out[2], &target, 8);
    return 4;
}

static int64_t sext(uint64_t v, int bits) {
    uint64_t m = 1ull << (bits - 1);
    return (int64_t)((v ^ m) - m);
}

// Relocates one instruction from pc to out. Returns words written, or -1 if it cannot be relocated.
static int relocate(uint32_t *out, uint32_t w, uint64_t pc) {
    if ((w & 0x9F000000u) == 0x90000000u) {                                 // ADRP
        int64_t imm = sext(((w >> 29) & 3) | (((w >> 5) & 0x7FFFF) << 2), 21) << 12;
        return emit_mov_abs(out, w & 31, (pc & ~0xFFFull) + (uint64_t)imm);
    }
    if ((w & 0x9F000000u) == 0x10000000u) {                                 // ADR
        int64_t imm = sext(((w >> 29) & 3) | (((w >> 5) & 0x7FFFF) << 2), 21);
        return emit_mov_abs(out, w & 31, pc + (uint64_t)imm);
    }
    if ((w & 0x7C000000u) == 0x14000000u) {                                 // B / BL
        uint64_t target = pc + (uint64_t)(sext(w & 0x3FFFFFF, 26) * 4);
        int n = 0;
        if (w & 0x80000000u) {                                              // BL: set LR, then jump
            n += emit_mov_abs(out, 16, target);
            out[n++] = 0xD63F0200u;                                         // blr x16
            return n;
        }
        return emit_jump_abs(out, target);
    }
    if ((w & 0xBF000000u) == 0x18000000u) {                                 // LDR (literal) Wt/Xt
        uint64_t addr = pc + (uint64_t)(sext((w >> 5) & 0x7FFFF, 19) * 4);
        unsigned rt = w & 31;
        int n = emit_mov_abs(out, rt, addr);
        out[n++] = ((w & 0x40000000u) ? 0xF9400000u : 0xB9400000u) | (rt << 5) | rt;   // ldr xt/wt, [xt]
        return n;
    }
    if ((w & 0xFF000010u) == 0x54000000u ||                                 // B.cond
        (w & 0x7E000000u) == 0x34000000u ||                                 // CBZ / CBNZ
        (w & 0x7E000000u) == 0x36000000u ||                                 // TBZ / TBNZ
        (w & 0x3B000000u) == 0x18000000u)                                   // other literal loads (SIMD)
        return -1;
    out[0] = w;
    return 1;
}

static int write_code(void *addr, const void *src, size_t len) {
    mach_port_t task = mach_task_self();
    vm_size_t page = (vm_size_t)getpagesize();
    vm_address_t start = (vm_address_t)addr & ~(page - 1);
    vm_size_t span = (((vm_address_t)addr + len + page - 1) & ~(page - 1)) - start;
    if (vm_protect(task, start, span, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) return 0;
    memcpy(addr, src, len);
    int ok = vm_protect(task, start, span, FALSE, VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS;
    sys_icache_invalidate(addr, len);
    return ok;
}

int th_patch_insn(void *addr, uint32_t insn) {
    return write_code(addr, &insn, 4);
}

int th_hook(void *target, void *replacement, void **orig) {
    const uint32_t *src = (const uint32_t *)target;
    uint32_t *t = tramp_alloc();
    if (!t) return TH_NO_MEMORY;
    uint32_t buf[TRAMP_SLOT / 4];
    int n = 0;
    for (int i = 0; i < 4; i++) {
        int k = relocate(buf + n, src[i], (uint64_t)(uintptr_t)(src + i));
        if (k < 0) return TH_UNRELOCATABLE;
        n += k;
    }
    n += emit_jump_abs(buf + n, (uint64_t)(uintptr_t)(src + 4));
    pthread_jit_write_protect_np(0);
    memcpy(t, buf, (size_t)n * 4);
    pthread_jit_write_protect_np(1);
    sys_icache_invalidate(t, (size_t)n * 4);
    uint32_t jump[4];
    emit_jump_abs(jump, (uint64_t)(uintptr_t)replacement);
    if (orig) *orig = t;
    if (!write_code(target, jump, sizeof jump)) return TH_PROTECT_FAILED;
    return TH_OK;
}
#endif
