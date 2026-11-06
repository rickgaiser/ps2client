#ifndef __FASTSERVE_H__
#define __FASTSERVE_H__

 // Serve files from the current directory over mxlink's fast path, on UDP port
 // 18197, for seconds (0: until killed). Returns an exit status.
 int fastserve_run(int seconds);

#endif
