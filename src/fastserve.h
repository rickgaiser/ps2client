#ifndef __FASTSERVE_H__
#define __FASTSERVE_H__

 // Serve files from the current directory over mxlink's fast path, on UDP port
 // 18197, for seconds (0: until killed), and tell the PS2 at hostname every
 // second that it can (0: nobody). Returns an exit status.
 int fastserve_run(char *hostname, int seconds);

 // The same beside a command: in a thread, until fastserve_stop. If the port is
 // in use there is simply no fast path.
 void fastserve_start(char *hostname);
 void fastserve_stop(void);

#endif
