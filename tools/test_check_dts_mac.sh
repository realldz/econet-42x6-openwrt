#!/usr/bin/env bash
#
# Self-test for tools/check_dts_mac.py.
#
# The checker is the only thing between a well-meant DTS edit and an image whose
# interfaces come up with random addresses, so every one of its checks is
# exercised by breaking exactly that thing and requiring the checker to name it.
# Each case runs on a copy of the real files, never on the tree itself, which is
# also why the copy has to be rebuilt between cases: one mutation can trip two
# checks and hide which one the test is testing.
#
# Usage:  tools/test_check_dts_mac.sh            (PYTHON=python3 by default)

set -u

PYTHON=${PYTHON:-python3}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECK="$ROOT/tools/check_dts_mac.py"
DTS_REL=openwrt/overlay/target/linux/airoha/dts/en7523-vgp42x6v1.dts
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0

# A pristine copy of the file the checker reads.
fresh() {
    rm -rf "$WORK/repo"
    mkdir -p "$WORK/repo/$(dirname "$DTS_REL")"
    cp "$ROOT/$DTS_REL" "$WORK/repo/$DTS_REL"
}

run() { $PYTHON "$CHECK" --repo-root "$WORK/repo" "$@" 2>&1; }

expect_ok() {
    local what=$1; shift
    local out
    if out=$(run "$@"); then
        echo "ok   $what"
    else
        echo "FAIL $what: the checker rejected a correct tree"
        printf '%s\n' "$out" | sed 's/^/     /'
        fail=1
    fi
}

expect_fail() {
    local what=$1 want=$2; shift 2
    local out
    if out=$(run "$@"); then
        echo "FAIL $what: the checker accepted it"
        fail=1
    elif ! printf '%s' "$out" | grep -qF -- "$want"; then
        echo "FAIL $what: the report does not mention '$want'"
        printf '%s\n' "$out" | sed 's/^/     /'
        fail=1
    else
        echo "ok   $what"
    fi
}

# mutate FILE OLD NEW -- the pattern must occur exactly once, or the case would
# be testing something other than what it says.
mutate() {
    $PYTHON - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit("the pattern occurs %d times in %s: %r" % (text.count(old), path, old))
open(path, "w", encoding="utf-8").write(text.replace(old, new))
PY
}

must_mutate() {
    if ! mutate "$@"; then
        echo "FAIL internal: the fixture could not be rewritten; the checker's"
        echo "     wording or the DTS changed and this test needs updating"
        fail=1
    fi
}

DTS() { printf '%s/%s' "$WORK/repo" "$DTS_REL"; }

# ---------------------------------------------------------------------------
echo "== the tree as it stands"
fresh
expect_ok "every MAC comes from flash"

# ---------------------------------------------------------------------------
echo "== the window the environment lives in"
fresh
must_mutate "$(DTS)" 'reg = <0x07C000 0x4000>;' 'reg = <0x060000 0x20000>;'
expect_fail "an erase-block sized window instead of the real sector" '0x7C000'

# ---------------------------------------------------------------------------
echo "== the position in the partition table"
fresh
# Appending anything after the environment shifts no index, but inserting one
# before it does -- and this case is about the partition no longer being last.
# The anchor runs from the cell property to the end of the root node, because a
# shallower run of closing braces appears twice.
must_mutate "$(DTS)" $'\t\t\t\t#nvmem-cell-cells = <1>;\n\t\t\t};\n\t\t};\n\t};\n};\n' \
    $'\t\t\t\t#nvmem-cell-cells = <1>;\n\t\t\t};\n\t\t};\n\n\t\tpartition@7e000 {\n\t\t\tlabel = "afterwards";\n\t\t\treg = <0x07E000 0x200>;\n\t\t};\n\t};\n};\n'
expect_fail "a partition appended after it" 'last partition'

# ---------------------------------------------------------------------------
echo "== the cell node"
fresh
must_mutate "$(DTS)" 'ethaddr: ethaddr@19f {' 'ethaddr: ethernet-mac@19f {'
expect_fail "a cell node the lookup cannot find" 'named `ethaddr@19f`'

fresh
must_mutate "$(DTS)" 'ethaddr: ethaddr@19f {' 'ethaddr: ethaddr@300 {'
expect_fail "a cell whose name does not match its reg" 'named `ethaddr@19f`'

fresh
must_mutate "$(DTS)" $'\t\t\t\t#nvmem-cell-cells = <1>;\n' ''
expect_fail "a cell that cannot take an index" '#nvmem-cell-cells'

fresh
must_mutate "$(DTS)" $'\t\t\t\tcompatible = "mac-base";\n' ''
expect_fail "a cell without the mac-base fixup" 'compatible = "mac-base"'

fresh
must_mutate "$(DTS)" 'reg = <0x19F 0x11>;' 'reg = <0x19F 0x6>;'
expect_fail "a binary-sized cell for an ASCII value" '<0x19F 0x11>'

fresh
must_mutate "$(DTS)" 'reg = <0x19F 0x11>;' 'reg = <0x380 0x11>;'
expect_fail "a cell whose reg does not match its name" 'expected <0x19F 0x11>'

# ---------------------------------------------------------------------------
echo "== the consumers"
fresh
must_mutate "$(DTS)" 'nvmem-cells = <&ethaddr 4>;' 'nvmem-cells = <&ethaddr 3>;'
expect_fail "two interfaces asking for the same index" 'used twice'

fresh
must_mutate "$(DTS)" 'nvmem-cells = <&ethaddr 7>;' 'nvmem-cells = <&ethaddr 6>;'
expect_fail "both Wi-Fi bands reading the same cell" 'used twice'

fresh
must_mutate "$(DTS)" $'\t\t\tnvmem-cells = <&ethaddr 0>;\n' \
    $'\t\t\tmac-address = [02 00 00 00 00 00];\n\t\t\tnvmem-cells = <&ethaddr 0>;\n'
expect_fail "an address baked into the image again" 'still carries a `mac-address`'

fresh
must_mutate "$(DTS)" 'wifi@0,0 {' 'radio@0,0 {'
expect_fail "no device node for the Wi-Fi chip" 'no Wi-Fi device node'

# ---------------------------------------------------------------------------
echo "== the arithmetic, on a dump"
fresh
# The environment the live flash carries, at the offset the cell declares:
# NUL filler up to 0x197 counted from the partition start (the 4-byte CRC
# prefix stored first is part of it), the value at 0x19F.
$PYTHON - "$WORK/env.bin" "$WORK/win.bin" <<'PY'
import struct, sys, zlib

def win():
    text = b"ethaddr=24:0b:2a:fc:a6:f0\x00bootdelay=1\x00baudrate=115200\x00"
    filler = b"\x00" * 0x193
    return filler + text + b"\xff" * (0x4000 - 4 - len(filler) - len(text))

structured = b"\xff" * 0x7C000 + struct.pack("<I", zlib.crc32(win())) + win()
open(sys.argv[1], "wb").write(structured)
open(sys.argv[2], "wb").write(structured[0x7C000:])
PY
expect_ok "a dump whose CRC32 and layout match the DTS" --dump "$WORK/env.bin"
expect_ok "a bare environment window with the same layout" --dump "$WORK/win.bin"

$PYTHON - "$WORK/bad.bin" <<'PY'
import struct, sys, zlib

def win():
    text = b"ethaddr=24:0b:2a:fc:a6:f0\x00bootdelay=1\x00baudrate=115200\x00"
    filler = b"\x00" * 0x193
    return filler + text + b"\xff" * (0x4000 - 4 - len(filler) - len(text))

body = bytearray(win())
body[4] ^= 0xFF             # one bit of the text, CRC left alone
open(sys.argv[1], "wb").write(b"\xff" * 0x7C000 +
                              struct.pack("<I", zlib.crc32(win())) + bytes(body))
PY
expect_fail "a dump whose CRC32 does not match" 'CRC32' --dump "$WORK/bad.bin"

# The same variables written 0x90 bytes later in the window: the declared cell
# would read filler, and the post-process would hand consumers garbage.
$PYTHON - "$WORK/moved.bin" <<'PY'
import struct, sys, zlib
text = b"ethaddr=24:0b:2a:fc:a6:f0\x00bootdelay=1\x00"
filler = b"\x00" * (0x366 + 0x90)
win = filler + text + b"\xff" * (0x4000 - 4 - len(filler) - len(text))
open(sys.argv[1], "wb").write(b"\xff" * 0x7C000 +
                              struct.pack("<I", zlib.crc32(win)) + win)
PY
expect_fail "a dump whose ethaddr moved" 'layout moved' --dump "$WORK/moved.bin"

$PYTHON - "$WORK/noeth.bin" <<'PY'
import struct, sys, zlib
text = b"bootdelay=1\x00"
filler = b"\x00" * 0x193
win = filler + text + b"\xff" * (0x4000 - 4 - len(filler) - len(text))
open(sys.argv[1], "wb").write(b"\xff" * 0x7C000 +
                              struct.pack("<I", zlib.crc32(win)) + win)
PY
expect_fail "a dump with no ethaddr in it" 'no ethaddr' --dump "$WORK/noeth.bin"

# ---------------------------------------------------------------------------
if [ "$fail" -ne 0 ]; then
    echo "check_dts_mac: FAILED"
    exit 1
fi
echo "check_dts_mac: every case behaved as documented"
