#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ub_push.py - Push one file from the PC into NAND through U-Boot (YMODEM + flash write),
             then read it back from Linux with `dd /dev/mtdN`. Used to move small
             .ko / script / binary files.

  python tools/ub_push.py --file path/to/pciedbg.ko
  python tools/ub_push.py --file X --dst 0x38C0000 --mtd 3

By default it writes into the EMPTY area of slot B (tclinux_slave, mtd3):
  slot B  = 0x28C0000..0x50C0000
  our FIT occupies the first 0x6F0F5C -> using +0x1000000 (16 MB) is safe.

MTD NUMBERING: the --mtd default of 3 is slot B only under this repository's OpenWrt
7-partition device tree, where slot B is mtd3 and data is mtd4. The vendor firmware's
11-entry /proc/mtd numbers slot B as mtd7, and mtd3 there is slot A's rootfs -- the same
default would then write to the wrong partition and damage the stock firmware. Run
`cat /proc/mtd` on the target and pass --mtd explicitly unless you are running this
repository's kernel.

Reading it back from Linux (the offset is derived from --dst, there is no separate
offset option):
  dd if=/dev/mtd3 of=/tmp/<name> bs=512 skip=32768 count=<n>

The vendor U-Boot asks for a user name and a password before it gives you its prompt.
They are NOT stored in this file: export UB_USER / UB_PASSWORD (see tools/README.md).
"""
import argparse
import os
import sys
import time

import serial

ACK, NAK, CAN, EOT, SOH, STX, C = 0x06, 0x15, 0x18, 0x04, 0x01, 0x02, 0x43
ERASE = 0x20000          # 128 KiB block

# Console logs are written next to this script (tools/logs/), independent of the
# current working directory.
LOGDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")

# Vendor U-Boot login. Deliberately not baked into the source - export these.
UB_USER = os.environ.get("UB_USER", "")
UB_PASSWORD = os.environ.get("UB_PASSWORD", "")

CRC_TABLE = []
for _i in range(256):
    _c = _i << 8
    for _ in range(8):
        _c = ((_c << 1) ^ 0x1021) & 0xFFFF if (_c & 0x8000) else (_c << 1) & 0xFFFF
    CRC_TABLE.append(_c)


def crc16(data):
    crc = 0
    for b in data:
        crc = ((crc << 8) & 0xFFFF) ^ CRC_TABLE[((crc >> 8) ^ b) & 0xFF]
    return crc


def ymodem_send(ser, logf, data, fname, blk=1024):
    total = len(data)
    print("[ymodem] waiting for 'C'...", flush=True)
    end = time.time() + 60
    got = False
    while time.time() < end:
        b = ser.read(1)
        if b:
            logf.write(b)
            if b[0] == C:
                got = True
                break
            if b[0] == CAN:
                print("[ymodem] CAN -> abort", flush=True)
                return False
        else:
            time.sleep(0.01)
    if not got:
        print("[ymodem] no 'C' received", flush=True)
        return False

    hdr = fname.encode() + b"\x00" + ("%d 0" % total).encode() + b"\x00"
    hdr = (hdr + bytes(128 - len(hdr))) if len(hdr) <= 128 else hdr[:128]
    pkt = bytes([SOH, 0, 0xFF]) + hdr + crc16(hdr).to_bytes(2, "big")
    for _ in range(12):
        ser.write(pkt)
        ser.flush()
        r = ser.read(1)
        if r:
            logf.write(r)
            if r[0] == ACK:
                break
            if r[0] == NAK:
                continue
    else:
        print("[ymodem] header failed", flush=True)
        return False

    nblk = (total + blk - 1) // blk
    pos = 0
    for i in range(nblk):
        seq = (i + 1) & 0xFF
        chunk = data[pos:pos + blk]
        pos += len(chunk)
        if len(chunk) == blk:
            head, body = STX, chunk
        elif len(chunk) <= 128:
            head, body = SOH, chunk + bytes(128 - len(chunk))
        else:
            head, body = STX, chunk + bytes(blk - len(chunk))
        pkt = bytes([head, seq, (0xFF - seq) & 0xFF]) + body + crc16(body).to_bytes(2, "big")
        ok = False
        for _ in range(15):
            ser.write(pkt)
            ser.flush()
            r = ser.read(1)
            if not r:
                continue
            logf.write(r)
            if r[0] == ACK:
                ok = True
                break
            if r[0] == CAN:
                print("  block %d: CAN" % seq, flush=True)
                return False
        if not ok:
            print("  *** block %d failed ***" % seq, flush=True)
            return False
    print("[ymodem] sent %d blocks" % nblk, flush=True)

    for _ in range(12):
        ser.write(bytes([EOT]))
        ser.flush()
        r = ser.read(1)
        if r and r[0] == ACK:
            logf.write(r)
            break
    pkt = bytes([SOH, 0, 0xFF]) + bytes(128) + crc16(bytes(128)).to_bytes(2, "big")
    for _ in range(8):
        ser.write(pkt)
        ser.flush()
        r = ser.read(1)
        if r and r[0] == ACK:
            break
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    ap.add_argument("--port", default="COM23")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--addr", default="0x88000000")
    ap.add_argument("--dst", default="0x38C0000")
    ap.add_argument("--mtd", default="3")
    ap.add_argument("--wait", type=int, default=600)
    args = ap.parse_args()

    data = open(args.file, "rb").read()
    name = os.path.basename(args.file)
    print("file=%s  %d byte" % (name, len(data)))

    os.makedirs(LOGDIR, exist_ok=True)
    logpath = os.path.join(LOGDIR, "push_%s_%s.log"
                           % (name, time.strftime("%Y%m%d_%H%M%S")))
    logf = open(logpath, "wb")
    ser = serial.Serial(args.port, args.baud, timeout=0.05, write_timeout=10)
    ser.reset_input_buffer()
    print("[con] %s" % logpath, flush=True)

    def raw(b):
        logf.write(b)
        logf.flush()
        sys.stdout.write(b.decode("utf-8", "replace"))
        sys.stdout.flush()

    def note(m):
        line = "\n[#] %s\n" % m
        logf.write(line.encode("utf-8", "replace"))
        logf.flush()
        print(line, end="", flush=True)

    def pump(sec, marks=()):
        buf = bytearray()
        end = time.time() + sec
        while time.time() < end:
            n = ser.in_waiting
            if n:
                c = ser.read(n)
                buf += c
                raw(c)
                for m in marks:
                    if m in buf:
                        return bytes(buf), m
            else:
                time.sleep(0.01)
        return bytes(buf), None

    def send(c, read_s, marks=(b"ECNT>",)):
        note("$ %s" % c)
        ser.write((c + "\r").encode())
        ser.flush()
        return pump(read_s, marks)

    note("waiting for the U-Boot prompt")
    end = time.time() + args.wait
    ok = False
    while time.time() < end:
        ser.write(b"\r")
        ser.flush()
        _, m = pump(0.4, (b"ECNT>", b"UserName:"))
        if m == b"ECNT>":
            ok = True
            break
        if m == b"UserName:":
            send(UB_USER, 5, (b"Password:", b"ECNT>"))
            send(UB_PASSWORD, 6, (b"ECNT>",))
            ser.write(b"\r")
            ser.flush()
            _, m2 = pump(1.0, (b"ECNT>",))
            if m2 == b"ECNT>":
                ok = True
                break
    if not ok:
        note("CANNOT GET INTO U-BOOT")
        logf.close()
        return 1

    note("=== loady %s + YMODEM ===" % args.addr)
    send("loady %s" % args.addr, 3)
    if not ymodem_send(ser, logf, data, name):
        note("YMODEM FAILED")
        logf.close()
        return 2
    pump(3)

    total = len(data)
    erase_len = ((total + ERASE - 1) // ERASE) * ERASE
    note("=== flash erase %s 0x%X ===" % (args.dst, erase_len))
    send("flash erase %s 0x%X" % (args.dst, erase_len), 25)
    note("=== flash write %s 0x%X %s ===" % (args.dst, total, args.addr))
    send("flash write %s 0x%X %s" % (args.dst, total, args.addr), 40)
    note("=== readback of the first 64 bytes ===")
    send("md.b %s 0x40" % args.addr, 5)

    # how to read it back from Linux
    mtd_off = int(args.dst, 16) - 0x28C0000
    skip = mtd_off // 512
    count = (total + 511) // 512
    note("ON LINUX: dd if=/dev/mtd%s of=/tmp/%s bs=512 skip=%d count=%d"
         % (args.mtd, name, skip, count))
    note("THEN: insmod /tmp/%s" % name)
    note("log: %s" % logpath)
    logf.close()
    ser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
