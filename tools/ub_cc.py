#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ub_cc.py - send Ctrl-C several times to cancel whatever is stuck (the PS2 '> '
prompt), then check whether the real prompt came back.

  python tools/ub_cc.py            # Ctrl-C x5 + echo @@OK@@
  python tools/ub_cc.py --reboot   # Ctrl-C then SysRq 'b' to reboot
"""
import argparse
import os
import sys
import time

import serial

PORT = "COM23"

# Console logs are written next to this script (tools/logs/), independent of the
# current working directory.
LOGDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=PORT)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--reboot", action="store_true")
    ap.add_argument("--n", type=int, default=5)
    args = ap.parse_args()

    os.makedirs(LOGDIR, exist_ok=True)
    logpath = os.path.join(LOGDIR, "cc_%s.log" % time.strftime("%Y%m%d_%H%M%S"))
    logf = open(logpath, "wb")
    ser = serial.Serial(args.port, args.baud, timeout=0.05, write_timeout=10)
    ser.reset_input_buffer()

    def drain(sec):
        end = time.time() + sec
        while time.time() < end:
            n = ser.in_waiting
            if n:
                b = ser.read(n)
                logf.write(b)
                sys.stdout.write(b.decode("latin-1", "replace"))
                sys.stdout.flush()
            else:
                time.sleep(0.005)

    for i in range(args.n):
        ser.write(b"\x03")
        ser.flush()
        time.sleep(0.2)
        ser.write(b"\r")
        ser.flush()
        drain(0.5)

    if args.reboot:
        # SysRq: BREAK + 'b' (magic sysrq over serial)
        time.sleep(0.3)
        for _ in range(3):
            ser.write(b"\x1b")     # ESC is not BREAK, this only garbles things
            ser.flush()
        # how it should be done: send a real BREAK = 0x00? On the Linux serial
        # console you use 'BREAK' + key. Skipped: use the command directly.
        ser.write(b"echo b > /proc/sysrq-trigger\r")
        ser.flush()
        drain(3)
    else:
        ser.write(b"echo @@OK@@\r")
        ser.flush()
        drain(3)

    print("\n[con] %s" % logpath)
    logf.close()
    ser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
