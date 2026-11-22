// guard.h - the games guard inside Steam (guard.c)
#ifndef TESSERA_GUARD_H
#define TESSERA_GUARD_H

typedef void (*tessera_guard_log_t)(const char *fmt, ...);

/// Puts parked install records back for the games Steam has a compatibility tool chosen for; counts the records
/// put back and the ones that stay parked.
void tessera_guard_put_back(const char *home, tessera_guard_log_t logf, int *back, int *kept);

/// At Steam's start: put the records back, leave this process's marker, start the guard that parks them again.
void tessera_guard_start(tessera_guard_log_t logf);

#endif
