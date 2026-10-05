#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ub_paste.py - Push one SMALL file into the 42X6 target's tmpfs over the UART console.

Context: the initramfs image that is running has NO /dev/mtd* (built without
CONFIG_MTD_CHAR/MTD_BLOCK), NO /dev/mem (built without CONFIG_DEVMEM), NO /proc/kcore,
and the busybox has NO base64/uudecode/xxd.  => The console is the only way in.

How it works: generate shell lines that use `printf` with octal escapes (\\ooo, always
3 digits for EVERY byte, so it can never be ambiguous with a digit that follows), then
pump them through the console.

TWO TRAPS THAT WERE PAID FOR (see docs/booting.md):

1. busybox ash limits the length of one line to CONFIG_FEATURE_EDITING_MAX_LEN.
   OpenWrt sets it to 512 (not 1024).  Go over it and the tail is CUT OFF -> the
   trailing '>> /tmp/...' is lost, so printf prints to the console, and the shell gets
   stuck in the PS2 '> ' prompt swallowing every command that follows.
   => BYTES_PER_LINE=100 (one line is ~430 characters).

2. The console has IXON enabled.  When the tty RX buffer fills up, the kernel sends
   XOFF (0x13) and reports "ttyS ttyS0: N input overrun(s)" in dmesg.  Ignoring XOFF
   loses a byte in the middle of a line -> the quoting shifts -> stuck in PS2.
   => this script PAUSES when it sees 0x13 and only continues when it sees 0x11 (XON),
   and it sends 64 bytes at a time.

  python tools/ub_paste.py --file path/to/ringwatch.ko
  python tools/ub_paste.py --file X --dst /tmp/y.ko --rate 2500

When the transfer is done the script runs `md5sum` itself and compares the result
against the md5 of the original file.
"""
import argparse
import hashlib
import os
import sys
import time

import serial

PORT = "COM23"
BYTES_PER_LINE = 100     # -> a line is ~430 characters, safely below 512
RATE = 2500.0            # bytes/second (115200 bps ~ 11520 B/s theoretical)
CHUNK = 64               # send in small chunks so XOFF can still be seen

# Console logs are written next to this script (tools/logs/), independent of the
# current working directory.
LOGDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")


def esc(chunk):
    return "".join("\\%03o" % b for b in chunk)


def build_lines(data, dst):
    lines = ["rm -f %s" % dst]
    for off in range(0, len(data), BYTES_PER_LINE):
        chunk = data[off:off + BYTES_PER_LINE]
        lines.append("printf '%s' >> %s" % (esc(chunk), dst))
    return lines


class Link:
    def __init__(self, port, logf, baud=115200):
        self.ser = serial.Serial(port, baud, timeout=0.02, write_timeout=20)
        self.ser.reset_input_buffer()
        self.logf = logf
        self.paused = False
        self.overrun_note = ""

    def drain(self, sec, produce=False):
        """Read every byte available for `sec` seconds; update the XOFF/XON flag."""
        end = time.time() + sec
        while time.time() < end:
            n = self.ser.in_waiting
            if n:
                b = self.ser.read(n)
                self.logf.write(b)
                if produce:
                    sys.stdout.write(b.decode("latin-1", "replace"))
                    sys.stdout.flush()
                if b"\x13" in b:
                    self.paused = True
                if b"\x11" in b:
                    self.paused = False
                if b"input overrun" in b:
                    self.overrun_note = "input overrun seen"
            else:
                time.sleep(0.002)

    def wait_xon(self, budget):
        end = time.time() + budget
        while self.paused and time.time() < end:
            self.drain(0.05)

    def send_line(self, line, rate):
        data = (line + "\r").encode("ascii")
        pos = 0
        while pos < len(data):
            self.wait_xon(20.0)
            chunk = data[pos:pos + CHUNK]
            self.ser.write(chunk)
            self.ser.flush()
            pos += len(chunk)
            self.drain(len(chunk) / rate)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    ap.add_argument("--dst", default=None)
    ap.add_argument("--port", default=PORT)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--rate", type=float, default=RATE)
    ap.add_argument("--tail-wait", type=float, default=6.0)
    args = ap.parse_args()

    data = open(args.file, "rb").read()
    dst = args.dst or ("/tmp/" + os.path.basename(args.file))
    md5 = hashlib.md5(data).hexdigest()

    lines = build_lines(data, dst)
    lines.append("md5sum %s" % dst)
    lines.append("ls -la %s" % dst)
    total = sum(len(l) + 1 for l in lines)
    print("file=%s  %d byte -> %s" % (os.path.basename(args.file), len(data), dst))
    print("expected md5 = %s" % md5)
    print("%d lines, %d bytes to send (~%.0f s @ %.0f B/s)"
          % (len(lines), total, total / args.rate, args.rate), flush=True)

    os.makedirs(LOGDIR, exist_ok=True)
    logpath = os.path.join(LOGDIR, "paste_%s_%s.log"
                           % (os.path.basename(args.file),
                              time.strftime("%Y%m%d_%H%M%S")))
    logf = open(logpath, "wb")
    print("[con] %s" % logpath, flush=True)

    link = Link(args.port, logf, args.baud)

    # Escape from a PS2 '> ' prompt if the previous run was cut in the middle of a
    # quoted string
    for _ in range(3):
        link.ser.write(b"\x03")
        link.ser.flush()
        time.sleep(0.15)
        link.ser.write(b"\r")
        link.ser.flush()
        link.drain(0.4)

    t0 = time.time()
    for i, line in enumerate(lines, 1):
        link.send_line(line, args.rate)
        if i % 10 == 0 or i == len(lines):
            pct = 100.0 * i / len(lines)
            print("  ... %d/%d lines (%.0f%%, %.0f s)"
                  % (i, len(lines), pct, time.time() - t0), flush=True)

    print("waiting for %s to answer..." % lines[-1].split()[0], flush=True)
    link.drain(args.tail_wait, produce=True)
    if link.overrun_note:
        print("[!] %s (check dmesg)" % link.overrun_note)
    logf.flush()
    logf.close()
    link.ser.close()

    txt = open(logpath, "rb").read().decode("latin-1", "replace")
    if md5 in txt:
        print("[OK] md5 matches: %s  (%.0f s)" % (md5, time.time() - t0))
        return 0
    print("[!!] md5 %s NOT seen in the log - see %s" % (md5, logpath))
    return 1


if __name__ == "__main__":
    sys.exit(main())
