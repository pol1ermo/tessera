// hook.h - Tessera's arm64 inline hooking (see hook.c).
#pragma once
#include <stdint.h>

enum { TH_OK = 0, TH_NO_MEMORY = 1, TH_UNRELOCATABLE = 2, TH_PROTECT_FAILED = 3 };

// Redirects target to replacement; *orig receives a callable copy of the original function.
int th_hook(void *target, void *replacement, void **orig);
// Overwrites one instruction.
int th_patch_insn(void *addr, uint32_t insn);
