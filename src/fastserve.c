 // The host's side of mxlink's fast path: files to the PS2 past its TCP/IP stack.
 //
 // Requests and data are UDP datagrams on port 18197. A datagram starts with a
 // 22-byte header, so that its data lies 64 bytes into the Ethernet frame, and
 // holds 1408 bytes of data, which makes a frame of 1472 bytes: on the PS2, DMA
 // takes it from there without a copy. A READ names a range of a file, so this
 // side keeps no state of a transfer: a lost frame is asked for by a READ of its
 // range again. The numbers are little endian.
 //
 //   0 magic "MF"   2 op   3 unused   4 id
 //   8 a           12 len 14 b       18 c

 #include <arpa/inet.h>
 #include <errno.h>
 #include <fcntl.h>
 #include <netinet/in.h>
 #include <stdint.h>
 #include <stdio.h>
 #include <stdlib.h>
 #include <string.h>
 #include <sys/select.h>
 #include <sys/socket.h>
 #include <time.h>
 #include <unistd.h>

 #include "fastserve.h"
 #include "ps2link.h"

 #define FAST_PORT 18197
 #define FAST_HDR 22
 #define FAST_CHUNK 1408
 #define FAST_MAX (256 * 1024)
 // A frame to the PS2 in about this time: a little under what 100 Mbit/s takes,
 // as SMAP's receive FIFO is 16 KiB and a faster host would overrun it.
 #define FAST_FRAME_NS 125000

 // Testing: PS2CLIENT_FAST_DROP=<n> leaves out every n-th frame.
 static unsigned int drop_every, frames_sent;

 enum { OP_OPEN = 1, OP_CLOSE, OP_READ, OP_LOG, OP_DATA, OP_ANSWER = 0x80 };

 static uint32_t get32(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
 static void put32(unsigned char *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

 static void header(unsigned char *b, int op, uint32_t id, uint32_t a, int len, uint32_t v) {

  memset(b, 0, FAST_HDR);
  b[0] = 'M'; b[1] = 'F'; b[2] = op;
  put32(b + 4, id); put32(b + 8, a);
  b[12] = len; b[13] = len >> 8;
  put32(b + 14, v);

 }

 static long long now_ns(void) { struct timespec t;

  clock_gettime(CLOCK_MONOTONIC, &t);
  return (long long)t.tv_sec * 1000000000 + t.tv_nsec;

 }

 static void answer(int sock, struct sockaddr_in *to, unsigned char *request, int result) { unsigned char b[FAST_HDR];

  header(b, request[2] | OP_ANSWER, get32(request + 4), (uint32_t)result, 0, 0);
  sendto(sock, b, sizeof(b), 0, (struct sockaddr *)to, sizeof(*to));

 }

 // A range of a file, as DATA datagrams: their offsets count from at.
 static void serve_read(int sock, struct sockaddr_in *to, unsigned char *request) {
  static unsigned char buffer[FAST_MAX + FAST_CHUNK];
  static unsigned char frame[FAST_HDR + FAST_CHUNK];
  uint32_t id = get32(request + 4), fd = get32(request + 8), position = get32(request + 14);
  uint32_t size = get32(request + 18), at = get32(request + FAST_HDR), sent = 0, total;
  long long next = now_ns();
  ssize_t got;

  if (size > FAST_MAX) { size = FAST_MAX; }
  got = pread((int)fd, buffer, size, position);
  if (got < 0) { got = 0; }
  // The end of the transfer, if this range reaches the end of the file: a range
  // asked for again says nothing about the rest.
  total = (uint32_t)got < size ? at + (uint32_t)got : 0xFFFFFFFF;

  do { uint32_t len = (uint32_t)got - sent, padded;

   if (len > FAST_CHUNK) { len = FAST_CHUNK; }
   padded = (len + 15) & ~15u;
   header(frame, OP_DATA, id, at + sent, (int)len, total);
   memcpy(frame + FAST_HDR, buffer + sent, len);
   memset(frame + FAST_HDR + len, 0, padded - len);
   while (now_ns() < next) { }
   if (!drop_every || ++frames_sent % drop_every) { sendto(sock, frame, FAST_HDR + padded, 0, (struct sockaddr *)to, sizeof(*to)); }
   next += FAST_FRAME_NS;
   sent += len;

  } while (sent < (uint32_t)got);

 }

 int fastserve_run(int seconds) { static unsigned char request[2048];
  struct sockaddr_in me, from;
  long long end = seconds ? now_ns() + (long long)seconds * 1000000000 : 0;
  int sock = socket(AF_INET, SOCK_DGRAM, 0), size = 4 << 20;

  if (getenv("PS2CLIENT_FAST_DROP")) { drop_every = strtoul(getenv("PS2CLIENT_FAST_DROP"), NULL, 0); }
  memset(&me, 0, sizeof(me));
  me.sin_family = AF_INET;
  me.sin_port = htons(FAST_PORT);
  me.sin_addr.s_addr = htonl(INADDR_ANY);
  setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
  if (sock < 0 || bind(sock, (struct sockaddr *)&me, sizeof(me)) < 0) {
   fprintf(stderr, "Error: Could not bind UDP port %d: %s\n", FAST_PORT, strerror(errno));
   return PS2CLIENT_EXIT_PORTBUSY;
  }

  while (!end || now_ns() < end) { fd_set set; struct timeval wait = { 0, 200000 };
   socklen_t length = sizeof(from);
   ssize_t got;

   FD_ZERO(&set); FD_SET(sock, &set);
   if (select(sock + 1, &set, NULL, NULL, &wait) <= 0) { continue; }
   got = recvfrom(sock, request, sizeof(request) - 1, 0, (struct sockaddr *)&from, &length);
   if (got < FAST_HDR || request[0] != 'M' || request[1] != 'F') { continue; }
   request[got] = 0;

   switch (request[2]) {
    case OP_OPEN: { char *path = (char *)request + FAST_HDR;
     while (*path == '/') { path++; }
     answer(sock, &from, request, open(path, O_RDONLY));
     break;
    }
    case OP_CLOSE: answer(sock, &from, request, close((int)get32(request + 8))); break;
    case OP_READ: if (got >= FAST_HDR + 4) { serve_read(sock, &from, request); } break;
    case OP_LOG: printf("%s", (char *)request + FAST_HDR); break;
   }

  }

  close(sock);
  return PS2CLIENT_EXIT_OK;

 }
