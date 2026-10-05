#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ub_uart.py - 42X6 UART toolchain (U-Boot + Linux), reusable many times WITHOUT rebooting.

  python tools/ub_uart.py boot-shell        # boot slot B with rdinit=/bin/sh (does NOT load modules)
  python tools/ub_uart.py send --file X     # send a list of commands, write a log
  python tools/ub_uart.py send --cmd "ls /proc"
  python tools/ub_uart.py init              # undo WiFi autoload + exec /sbin/init (full OpenWrt)
  python tools/ub_uart.py peek              # read only, 3 s

Note: the UART connection is not exclusive, so once `boot-shell` has finished, every
later `send` run talks to the shell that is already alive on the machine.

The vendor U-Boot asks for a user name and a password before it gives you its prompt.
They are NOT stored in this file: export UB_USER / UB_PASSWORD (see tools/README.md).
"""
import argparse
import os
import re
import sys
import time

import serial

SLOT_B = 0x28C0000
# Length of the FIT currently sitting in slot B. 0x6F0F5C = original vendor FIT; our
# OpenWrt image is bigger: 0x7407C8 (7 604 168 B, the wifi-fix build carrying the PCI
# quirk). Update this number every time a new image is loaded, otherwise `flash read`
# truncates it.
FIT_LEN = 0x7407C8
LOAD_ADDR = 0x88000000

BOOTARGS_BASE = ("console=ttyS0,115200n8 earlycon=uart8250,mmio32,0x1fbf0000 "
                 "ignore_loglevel loglevel=8")

MOUNTS = [
    "mount -t proc proc /proc",
    "mount -t sysfs sysfs /sys",
    "mount -t debugfs none /sys/kernel/debug 2>/dev/null",
]

WIFI_AUTOLOAD = ("rm -f /etc/modules.d/mt7915e /etc/modules.d/mt7916* "
                 "/etc/modules.d/mt76* /etc/modules.d/mac80211 /etc/modules.d/etc80211")

PORT = "COM23"
# Console logs are written next to this script (tools/logs/), independent of the
# current working directory.
LOGDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")

# Vendor U-Boot login. Deliberately not baked into the source - export these.
UB_USER = os.environ.get("UB_USER", "")
UB_PASSWORD = os.environ.get("UB_PASSWORD", "")

ser = None
logf = None


def raw(b):
    if logf:
        logf.write(b)
        logf.flush()
    sys.stdout.write(b.decode("utf-8", "replace"))
    sys.stdout.flush()


def note(m):
    line = "\n[#] %s\n" % m
    if logf:
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


def send(c, read_s, marks=()):
    note("$ %s" % c)
    ser.write((c + "\r").encode())
    ser.flush()
    return pump(read_s, marks)


def open_port(baud=115200):
    global ser
    ser = serial.Serial(PORT, baud, timeout=0.05, write_timeout=10)
    ser.reset_input_buffer()


def log_open(tag):
    global logf
    os.makedirs(LOGDIR, exist_ok=True)
    p = os.path.join(LOGDIR, "%s_%s.log" % (tag, time.strftime("%Y%m%d_%H%M%S")))
    logf = open(p, "wb")
    note("[con] %s" % p)
    return p


# ---------------------------------------------------------------- u-boot

def ub_prompt(wait=600):
    note("waiting for the U-Boot prompt (max %d s)" % wait)
    end = time.time() + wait
    while time.time() < end:
        ser.write(b"\r")
        ser.flush()
        _, m = pump(0.4, (b"ECNT>", b"UserName:"))
        if m == b"ECNT>":
            return True
        if m == b"UserName:":
            for _ in range(3):
                send(UB_USER, 5, (b"Password:", b"ECNT>"))
                send(UB_PASSWORD, 6, (b"ECNT>",))
                ser.write(b"\r")
                ser.flush()
                _, m2 = pump(1.0, (b"ECNT>",))
                if m2 == b"ECNT>":
                    return True
            return False
    return False


def wait_shell(timeout=120, needle=b"@@RDY@@"):
    note("waiting for the shell to answer (max %d s)" % timeout)
    end = time.time() + timeout
    hits = 0
    while time.time() < end:
        ser.write(b"echo @@RDY@@\r")
        ser.flush()
        buf, _ = pump(1.2)
        if buf.count(needle) >= 2:
            hits += 1
            if hits >= 1:
                return True
    return False


def do_boot_shell(args):
    bootargs = BOOTARGS_BASE + " rdinit=/bin/sh"
    if not ub_prompt(args.wait):
        note("CANNOT GET INTO U-BOOT")
        return 1
    send('setenv bootargs "%s"' % bootargs, 3)
    send("printenv bootargs", 4)
    note("=== flash read slot B ===")
    send("flash read 0x%X 0x%X 0x%X" % (SLOT_B, FIT_LEN, LOAD_ADDR), 45)
    buf, _ = send("iminfo 0x%X" % LOAD_ADDR, 12)
    txt = buf.decode("latin-1", "replace")
    m = re.search(r"Load Address:\s+(0x[0-9a-fA-F]+)", txt)
    note("iminfo load = %s (must be 0x80208000)" % (m.group(1) if m else "?"))
    note("=== bootm 0x%X ===" % LOAD_ADDR)
    ser.write(("bootm 0x%X\r" % LOAD_ADDR).encode())
    ser.flush()
    pump(args.watch, (b"Run /init as init process", b"Kernel panic"))
    if not wait_shell(90):
        note("NO SHELL")
        return 2
    note("=== mount proc/sys/debugfs ===")
    for c in MOUNTS:
        send(c, 2)
    send("echo @@SHELL_READY@@; uname -a; cat /proc/mounts | wc -l", 4)
    note("SHELL READY - use `send` to talk to it further, no need to reboot")
    return 0


def do_init(args):
    send("ls /etc/modules.d/", 3)
    send(WIFI_AUTOLOAD, 3)
    send("echo @@AFTER_RM@@; ls /etc/modules.d/", 3)
    note("=== exec /sbin/init ===")
    ser.write(b"exec /sbin/init\r")
    ser.flush()
    pump(35, (b"Please press Enter",))
    ser.write(b"\r")
    ser.flush()
    pump(6)
    if not wait_shell(60, needle=b"@@RDY@@"):
        note("procd did not answer; trying Enter")
        ser.write(b"\r")
        ser.flush()
        pump(6)
    send("echo @@OPENWRT_UP@@; uname -a; ps w | head -20", 8)
    return 0


# ---------------------------------------------------------------- send

def do_send(args):
    cmds = []
    if args.file:
        with open(args.file, "r", encoding="utf-8") as f:
            for ln in f:
                ln = ln.strip()
                if ln and not ln.startswith("#"):
                    cmds.append(ln)
    if args.cmd:
        cmds.append(args.cmd)
    if not cmds:
        note("no commands given")
        return 1
    if not args.no_enter:
        ser.write(b"\r")
        ser.flush()
        pump(0.5)
    for i, c in enumerate(cmds, 1):
        note("=== [%d/%d] %s" % (i, len(cmds), c))
        ser.write(("echo @@B%d@@\r" % i).encode())
        ser.flush()
        pump(0.6)
        ser.write((c + "\r").encode())
        ser.flush()
        pump(args.wait)
        ser.write(("echo @@E%d@@\r" % i).encode())
        ser.flush()
        pump(1.0)
    return 0


def do_peek(args):
    note("peek %d s" % args.sec)
    ser.write(b"\r")
    ser.flush()
    pump(args.sec)
    return 0


def main():
    global PORT
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["boot-shell", "send", "init", "peek"])
    ap.add_argument("--port", default=PORT)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--wait", type=int, default=600)
    ap.add_argument("--watch", type=int, default=120)
    ap.add_argument("--file")
    ap.add_argument("--cmd")
    ap.add_argument("--wait-per-cmd", dest="wait", type=int, default=5)
    ap.add_argument("--no-enter", action="store_true")
    ap.add_argument("--sec", type=int, default=3)
    args = ap.parse_args()

    PORT = args.port
    open_port(args.baud)
    log_open("ub_%s" % args.action)
    try:
        if args.action == "boot-shell":
            return do_boot_shell(args)
        if args.action == "init":
            return do_init(args)
        if args.action == "send":
            return do_send(args)
        return do_peek(args)
    finally:
        if logf:
            logf.close()
        ser.close()


if __name__ == "__main__":
    sys.exit(main())
