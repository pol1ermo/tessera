// guard_test.c - runs the guard's "put back" on the Steam folders under $HOME (use a scratch HOME): a test program
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include "guard.h"
static void logf_(const char *fmt, ...) { va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap); printf("\n"); }
int main(void) {
    int back = 0, kept = 0;
    tessera_guard_put_back(getenv("HOME"), logf_, &back, &kept);
    printf("put back %d, kept parked %d\n", back, kept);
    return 0;
}
