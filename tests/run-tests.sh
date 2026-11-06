#!/usr/bin/env bash
# Test ps2client against tests/fake_ps2link.py (Linux only).
#
# ps2client and ps2link both use UDP port 0x4712, so the fake runs in its own
# network namespace (10.0.0.2), linked by a veth pair to the client's
# (10.0.0.1). Both are unprivileged user namespaces; no root needed.
#
#   tests/run-tests.sh [path/to/ps2client]

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CLIENT=$(realpath "${1:-$HERE/../bin/ps2client}")

if [ -z "${PS2CLIENT_TEST_NS:-}" ]; then
    exec unshare -rn env PS2CLIENT_TEST_NS=1 "$0" "$CLIENT"
fi

ip link set lo up

WORK=$(mktemp -d)
trap 'stop_fake; rm -rf "$WORK"' EXIT
cd "$WORK"
FAKE_PID=

start_fake() {
    # The link goes away with the namespace of the previous fake.
    ip link del veth0 2>/dev/null
    ip link add veth0 type veth peer name veth1
    ip addr add 10.0.0.1/24 dev veth0
    ip link set veth0 up
    # shellcheck disable=SC2016 # $0 and $@ expand in the inner shell
    unshare -n sh -c '
        while ! ip link show veth1 >/dev/null 2>&1; do sleep 0.02; done
        ip link set lo up; ip addr add 10.0.0.2/24 dev veth1; ip link set veth1 up
        exec python3 -I "$0" --bind 10.0.0.2 "$@"' "$HERE/fake_ps2link.py" "$@" &
    FAKE_PID=$!
    # Move the link only once the child has its own namespace.
    while [ "$(readlink /proc/$FAKE_PID/ns/net)" = "$(readlink /proc/self/ns/net)" ]; do sleep 0.01; done
    ip link set veth1 netns "$FAKE_PID"
    # Wait until it accepts connections. A plain connect, so that no command
    # reaches the fake before the test does.
    for _ in $(seq 100); do
        (exec 3<>/dev/tcp/10.0.0.2/18193) 2>/dev/null && return 0
        sleep 0.05
    done
    echo "fake ps2link did not start" >&2
    exit 1
}

stop_fake() {
    [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null && wait "$FAKE_PID" 2>/dev/null
    FAKE_PID=
}

PASS=0 FAIL=0
# Monotonic milliseconds; the wall clock can be adjusted during a run.
now_ms() { awk '{ printf "%d", $1 * 1000 }' /proc/uptime; }
# check <name> <expected status> <command...>: runs the client, keeps
# stdout/stderr in $OUT/$ERR and its run time (ms) in $MS.
check() {
    local name=$1 want=$2 start; shift 2
    start=$(now_ms)
    "$CLIENT" "$@" > out.txt 2> err.txt
    local rc=$?
    MS=$(( $(now_ms) - start ))
    OUT=$(cat out.txt) ERR=$(cat err.txt)
    if [ "$rc" = "$want" ]; then
        PASS=$((PASS + 1)); echo "PASS $name (status $rc, ${MS} ms)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL $name: status $rc, want $want"; echo "  stdout: $OUT"; echo "  stderr: $ERR"
    fi
}
expect() { # expect <name> <condition...>
    local name=$1; shift
    if "$@"; then PASS=$((PASS + 1)); echo "PASS $name"; else FAIL=$((FAIL + 1)); echo "FAIL $name"; echo "  stdout: $OUT"; echo "  stderr: $ERR"; fi
}

H=(-h 10.0.0.2)

# --- without ps2link
check "ping, connection refused" 69 -h 127.0.0.1 -t 1 ping
expect "ping fails fast when refused" test "$MS" -lt 500
check "execee, nothing listening" 69 "${H[@]}" -t 5 execee host:x.elf
expect "error on stderr, stdout empty" test -z "$OUT" -a -n "$ERR"

# --- usage errors
check "unknown command" 64 "${H[@]}" frobnicate
check "missing arguments" 64 "${H[@]}" dumpmem 0x100000
check "bad register type" 64 "${H[@]}" dumpreg eeregs x.bin
check "-e without marker" 64 "${H[@]}" -e
check "arguments too long" 64 "${H[@]}" execee host:x.elf "$(printf 'a%.0s' $(seq 300))"

start_fake

check "ping" 0 "${H[@]}" -t 2 ping
expect "ping reports round trip" grep -q "answered in" out.txt
check "ping, no answer" 69 -h 10.0.0.99 -t 1 ping
expect "ping gives up after -t" test "$MS" -ge 990 -a "$MS" -lt 2500

# --- the marker ends the run with its status
printf 'print hello\nprint @@END@@ status=3\nsleep 5\nprint late\n' > status.elf
check "marker status" 3 "${H[@]}" -t 10 -e @@END@@ execee host:status.elf one two
expect "output before marker" grep -q "^hello$" out.txt
expect "arguments passed" grep -q "^fake: args one two$" out.txt
expect "exits at the marker" test "$MS" -lt 3000
expect "nothing after the marker" bash -c '! grep -q late out.txt'

printf 'print @@END@@\n' > nostatus.elf
check "marker without status" 0 "${H[@]}" -t 10 -e @@END@@ execee host:nostatus.elf

# --- console packets are not null-terminated
printf 'raw 1024 A\nraw 10 B\nraw 1500 C\nprint\nprint @@END@@ status=0\n' > raw.elf
check "console packets" 0 "${H[@]}" -t 10 -e @@END@@ execee host:raw.elf
expect "exact console bytes, packets over 1 KB too" test "$(grep -c '^A\{1024\}B\{10\}C\{1500\}$' out.txt)" = 1

# --- ps2link going away
printf 'print bye\nclose\n' > close.elf
check "connection closed" 74 "${H[@]}" -t 10 -e @@END@@ execee host:close.elf
expect "closed: fast" test "$MS" -lt 3000
expect "closed: console kept" grep -q "^bye$" out.txt
check "connection closed, no marker option" 74 "${H[@]}" -t 10 execee host:close.elf

# --- output is written as it comes in, so a killed client loses nothing
printf 'print early\nsleep 10\n' > early.elf
"$CLIENT" "${H[@]}" -t 20 execee host:early.elf > early.txt 2>&1 &
CPID=$!
sleep 1.5
kill -TERM $CPID; wait $CPID 2>/dev/null
OUT=$(cat early.txt) ERR=
expect "unbuffered output survives kill" grep -q "^early$" early.txt

# --- idle timeout
printf 'print quiet\nsleep 10\n' > quiet.elf
check "idle timeout before marker" 124 "${H[@]}" -t 1 -e @@END@@ execee host:quiet.elf
check "idle timeout without -e" 0 "${H[@]}" -t 1 execee host:quiet.elf
expect "idle timeout waits" test "$MS" -ge 990

# --- host: file serving with big reads
head -c 300000 /dev/urandom > blob.bin
printf 'readback blob.bin\nprint @@END@@ status=0\n' > readback.elf
check "big host: read" 0 "${H[@]}" -t 10 -e @@END@@ execee host:readback.elf
expect "readback size and crc" grep -q "^readback 300000 $(python3 -c 'import sys,zlib;print("%08x"%zlib.crc32(open(sys.argv[1],"rb").read()))' blob.bin)$" out.txt

# --- a host: file opened for reading and writing (PS2 flags 3) can be read
printf 'rdwrback blob.bin\nprint @@END@@ status=0\n' > rdwr.elf
check "host: read of a read-write file" 0 "${H[@]}" -t 10 -e @@END@@ execee host:rdwr.elf
expect "read-write: size and crc, not truncated" grep -q "^rdwrback 300000 $(python3 -c 'import sys,zlib;print("%08x"%zlib.crc32(open(sys.argv[1],"rb").read()))' blob.bin)$" out.txt

# --- second client
"$CLIENT" "${H[@]}" -t 5 listen > /dev/null 2>&1 &
LISTENER=$!
sleep 0.5
check "console port in use" 75 "${H[@]}" -t 5 -e @@END@@ execee host:nostatus.elf
expect "port in use: clear message" grep -q "another ps2client" err.txt
kill $LISTENER; wait $LISTENER 2>/dev/null

# --- reset needs neither console nor request connection
check "reset" 0 "${H[@]}" reset

# --- ps2link not ready right after accepting
stop_fake
start_fake --ignore-dumpreg 1
check "handshake retries" 0 "${H[@]}" -t 10 -e @@END@@ execee host:nostatus.elf
expect "retried after 1 s" test "$MS" -ge 990
stop_fake

# --- the ps2 is reset or switched off during a run: it never closes the
# connection. Take the link down first, so the fake's FIN gets lost.
# power_off <name> <restart>: a run that loses the ps2 after 1 s; with
# restart, a new fake (a fresh network stack) comes up at the same address.
power_off() {
    local name=$1 restart=$2 start rc
    start_fake
    printf 'print running\nsleep 60\n' > long.elf
    start=$(now_ms)
    "$CLIENT" "${H[@]}" -t 60 -e @@END@@ execee host:long.elf > out.txt 2> err.txt &
    local cpid=$!
    sleep 1
    ip link set veth0 down
    stop_fake
    [ "$restart" = 1 ] && start_fake
    wait $cpid; rc=$?
    MS=$(( $(now_ms) - start ))
    OUT=$(cat out.txt) ERR=$(cat err.txt)
    expect "$name: connection lost" test "$rc" = 74
    expect "$name: noticed long before the timeout" test "$MS" -lt 25000
    stop_fake
}
power_off "ps2 reset" 1
expect "ps2 reset: noticed at the first keepalive" test "$MS" -lt 10000
power_off "ps2 switched off" 0

# --- status: answered without a host: connection, also while a program runs
start_fake
check "status, idle" 0 "${H[@]}" -t 2 status
expect "status: ready, returns, last status, model, rom, program" test "$OUT" = "state=ready returns=7 status=3 model=SCPH-70004 rom=0200EC20040614 program=host:fake.elf"
printf 'print running\nsleep 2\nprint @@END@@ status=0\n' > st.elf
"$CLIENT" "${H[@]}" -t 10 -e @@END@@ execee host:st.elf > run.txt 2>&1 &
cpid=$!
sleep 1
check "status during a run" 0 "${H[@]}" -t 2 status
expect "status: running" test "${OUT%% *}" = "state=running"
wait $cpid
expect "the run was not cut off" test $? = 0
stop_fake
start_fake --status-v1
check "status, an older mxlink" 0 "${H[@]}" -t 2 status
expect "status: no model and rom" test "$OUT" = "state=ready returns=7 status=3 program=host:fake.elf"
stop_fake
start_fake --menu
check "status, in the shell" 0 "${H[@]}" -t 2 status
expect "status: menu" test "${OUT%% *}" = "state=menu"
stop_fake
check "status, nothing there" 69 "${H[@]}" -t 1 status

expect "fast path server" python3 "$HERE/fastserve_test.py" "$CLIENT"

echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
