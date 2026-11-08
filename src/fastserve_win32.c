/*
 * The fast path is not available on Windows (fastserve.c uses POSIX sockets
 * and threads): serve says so, and the other commands run without it, over
 * ps2link's host: as before.
 */
#include <stdio.h>

#include "fastserve.h"
#include "ps2link.h"

int fastserve_run(char *hostname, int seconds)
{
  (void)hostname;
  (void)seconds;
  fprintf(stderr, "Error: serve (the fast path) is not available on Windows.\n");
  return PS2CLIENT_EXIT_USAGE;
}

void fastserve_start(char *hostname) { (void)hostname; }

void fastserve_stop(void) { }
