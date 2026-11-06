#!/usr/bin/env python3
"""ps2client serve, over the loopback: the layout of its frames, a range, the end
of a file and a range asked for again.  fastserve_test.py <ps2client>"""
import os, socket, struct, subprocess, sys, tempfile, time

PORT, HDR, CHUNK = 18197, 22, 1408
OPEN, CLOSE, READ, DATA, ANSWER = 1, 2, 3, 5, 0x80
FULL = 0xFFFFFFFF  # no end of file in this range


def header(op, ident, a=0, length=0, b=0, c=0):
    return struct.pack("<2sBBIIHII", b"MF", op, 0, ident, a, length, b, c)


def request(s, data, ident):
    for _ in range(50):
        s.send(data)
        try:
            r = s.recv(2048)
        except OSError:
            continue
        magic, op, _, rid, a = struct.unpack("<2sBBII", r[:12])
        assert magic == b"MF" and op & ANSWER and rid == ident, r[:12]
        return struct.unpack("<i", r[8:12])[0]
    sys.exit("no answer")


def read(s, ident, handle, pos, size, at):
    s.send(header(READ, ident, handle, 0, pos, size) + struct.pack("<I", at))
    got = {}
    total = None
    while True:
        try:
            d = s.recv(2048)
        except OSError:
            return got, total
        assert d[:2] == b"MF" and d[2] == DATA, d[:4]
        rid, off, length, total = struct.unpack("<IIHI", d[4:18])
        assert rid == ident
        assert (len(d) - HDR) % 16 == 0, "not padded to 16 bytes"
        assert len(d) - HDR <= CHUNK and off % CHUNK == 0
        assert HDR + 42 == 64, "the data must lie 64 bytes into the frame"
        got[off] = d[HDR:HDR + length]


os.chdir(tempfile.mkdtemp())
data = bytes((i * 7 + (i >> 8)) & 255 for i in range(10000))
open("f.bin", "wb").write(data)
server = subprocess.Popen([sys.argv[1], "-t", "8", "serve"])
time.sleep(0.3)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.connect(("127.0.0.1", PORT))
s.settimeout(0.2)
try:
    h = request(s, header(OPEN, 1) + b"/f.bin\0", 1)
    assert h >= 0, "open"
    assert request(s, header(OPEN, 2) + b"none.bin\0", 2) < 0, "open of a missing file"

    got, total = read(s, 3, h, 0, 4000, 0)
    assert total == FULL and sorted(got) == [0, 1408, 2816], (total, sorted(got))
    assert b"".join(got[o] for o in sorted(got)) == data[:4000]

    got, total = read(s, 4, h, 1408, 1408, 1408)  # one frame again
    assert total == FULL, "a range again says nothing about the end"
    assert sorted(got) == [1408] and got[1408] == data[1408:2816]

    got, total = read(s, 5, h, 9000, 4000, 0)  # past the end
    assert total == 1000 and got[0] == data[9000:]

    got, total = read(s, 6, h, 20000, 16, 0)  # all past the end
    assert total == 0 and got == {0: b""}

    assert request(s, header(CLOSE, 7, h), 7) == 0
    print("fastserve: all passed")
finally:
    server.terminate()
