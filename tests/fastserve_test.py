#!/usr/bin/env python3
"""ps2client serve, over the loopback: the layout of its frames, a range, the end
of a file and a range asked for again.  fastserve_test.py <ps2client>"""
import os, socket, struct, subprocess, sys, tempfile, time

PORT, HDR, CHUNK = 18197, 22, 1408
OPEN, CLOSE, READ, DATA, WRITE, COMMIT, TTY, ANSWER = 1, 2, 3, 5, 6, 7, 10, 0x80
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
server = subprocess.Popen([sys.argv[1], "-t", "8", "serve"], stdout=subprocess.PIPE)
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

    w = request(s, header(OPEN, 8, 1) + b"w.bin\0", 8)
    assert w >= 0, "open to write"
    frames = [(0, data[:CHUNK]), (CHUNK, data[CHUNK:2 * CHUNK]), (2 * CHUNK, data[2 * CHUNK:2 * CHUNK + 100])]
    for at, d in frames[:2]:  # the last one lost
        s.send(header(WRITE, 9, w, len(d), at, at) + d)
    time.sleep(0.1)
    s.send(header(COMMIT, 9, w))
    r = s.recv(2048)
    assert struct.unpack("<I", r[14:18])[0] == 3, "two frames of three"
    at, d = frames[2]
    s.send(header(WRITE, 9, w, len(d), at, at) + d + bytes(12))
    at, d = frames[0]
    s.send(header(WRITE, 9, w, len(d), at, at) + d)  # one twice
    time.sleep(0.1)
    s.send(header(COMMIT, 9, w))
    r = s.recv(2048)
    assert struct.unpack("<I", r[14:18])[0] == 7, "all three"
    s.send(header(COMMIT, 10, w))
    r = s.recv(2048)
    assert struct.unpack("<I", r[14:18])[0] == 0, "another id has none"
    assert request(s, header(CLOSE, 11, w), 11) == 0
    assert open("w.bin", "rb").read() == data[:2 * CHUNK + 100]

    # the console: each byte once and in order, the answer saying how far
    def tty(at, text, stream=1):
        s.send(header(TTY, 0, at, len(text), stream) + text)
        r = s.recv(2048)
        assert r[2] == TTY | ANSWER, r[:4]
        return struct.unpack("<I", r[14:18])[0]
    assert tty(5000, b"one ") == 5004, "the stream starts at the first frame"
    assert tty(5008, b"late") == 5004, "a gap: not printed, asked for again"
    assert tty(5000, b"one two ") == 5008, "overlapping: only what is new"
    assert tty(5004, b"two ") == 5008, "twice: nothing"
    assert tty(5008, b"three\n") == 5014
    assert tty(0, b"four\n", 2) == 5, "a new stream (the IOP was reset) from its first frame"
    print("fastserve: all passed")
finally:
    server.terminate()
out = server.communicate()[0]
assert out == b"one two three\nfour\n", out
print("fastserve: console passed")
