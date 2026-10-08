#!/usr/bin/env python3
"""Check that a published .dts is the one that was compiled into an image.

Reads an OpenWrt sysupgrade image, pulls the flat_dt sub-image out of the FIT,
parses the DTB by hand (no `dtc` needed, no OpenWrt tree needed) and compares it
against a board .dts plus the .dtsi files it includes -- the latter are only
needed to resolve `&label` references to node paths.

Every node and every property the .dts declares must exist in the image with the
same value.  Values are compared cell by cell: integer literals and phandle
targets are checked, macro-valued cells (GPIO_ACTIVE_LOW, EN7523_FE_RST, ...)
are wildcards because the binding headers are not available here.  A bare
phandle such as `led-boot = &led_power` is checked against the path string dtc
writes into /aliases, and /delete-node/ directives are checked backwards: the
node they remove must really be absent.

    python3 tools/dts_vs_image.py <image.bin> <board.dts> [<included.dtsi> ...]

Differences reported are real: either the .dts was edited after the image was
built, a property was hand-typed wrong, or -- expected, and the reason this
repository ships a placeholder -- a per-unit value was redacted, of which
mac-address is the usual one.
"""
import re
import struct
import sys

FDT_MAGIC = 0xD00DFEED
INT = re.compile(r"^-?(0[xX][0-9a-fA-F]+|\d+)$")
TOKEN = re.compile(r"<[^>]*>|\[[^\]]*\]|\"[^\"]*\"")


# ---------------------------------------------------------------------------
# FDT (binary device tree) -> {node path: {property: raw bytes}}
# ---------------------------------------------------------------------------
def fdt_nodes(blob):
    (magic, total, off_struct, off_strings, off_rsvmap, ver, lastcomp,
     bootcpu, size_strings, size_struct) = struct.unpack(">10I", blob[:40])
    if magic != FDT_MAGIC:
        raise SystemExit("not a device tree: magic 0x%08X" % magic)
    strings = blob[off_strings:off_strings + size_strings]
    if off_struct + size_struct > len(blob):
        raise SystemExit("device tree struct block runs past the buffer")

    def sname(off):
        end = strings.index(b"\x00", off)
        return strings[off:end].decode("latin-1")

    nodes = {}
    stack = [""]
    pos = off_struct
    end = off_struct + size_struct
    while pos < end:
        tok, = struct.unpack(">I", blob[pos:pos + 4])
        pos += 4
        if tok == 1:                                    # FDT_BEGIN_NODE
            e = blob.index(b"\x00", pos)
            name = blob[pos:e].decode("latin-1")
            pos = (e + 4) & ~3
            path = stack[-1] if name == "" else stack[-1] + "/" + name
            stack.append(path)
            nodes.setdefault(path, {})
        elif tok == 2:                                  # FDT_END_NODE
            stack.pop()
        elif tok == 3:                                  # FDT_PROP
            ln, noff = struct.unpack(">II", blob[pos:pos + 8])
            pos += 8
            nodes[stack[-1]][sname(noff)] = blob[pos:pos + ln]
            pos = (pos + ln + 3) & ~3
        elif tok == 4:                                  # FDT_NOP
            pass
        elif tok == 9:                                  # FDT_END
            break
        else:
            raise SystemExit("bad device tree token 0x%x" % tok)
    return nodes


def fit_subimages(blob):
    """{name: (properties, data)} for every /images/* sub-image of the FIT."""
    total, = struct.unpack(">I", blob[4:8])
    fit = blob[:total]
    out = {}
    for path, props in fdt_nodes(fit).items():
        m = re.match(r"^/images/([^/]+)$", path)
        if not m:
            continue
        if "data" in props:
            data = props["data"]
        else:
            off, = struct.unpack(">I", props.get("data-offset", b"\x00\x00\x00\x00"))
            size, = struct.unpack(">I", props.get("data-size", b"\x00\x00\x00\x00"))
            data = fit[off:off + size]
        out[m.group(1)] = (props, data)
    return out


# ---------------------------------------------------------------------------
# .dts / .dtsi -> {node path: {property: source text}}
# ---------------------------------------------------------------------------
def strip_comments(text):
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                if text[j] == "\\":
                    j += 1
                j += 1
            out.append(text[i:j + 1])
            i = j + 1
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def tokenize(text):
    """Split into ('stmt', text) / ('{',) / ('}',) / (';',) tokens."""
    toks = []
    buf = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                if text[j] == "\\":
                    j += 1
                j += 1
            buf.append(text[i:j + 1])
            i = j + 1
            continue
        if c in "{};":
            s = "".join(buf).strip()
            if s:
                toks.append(("stmt", s))
            toks.append((c,))
            buf = []
            i += 1
            continue
        buf.append(c)
        i += 1
    s = "".join(buf).strip()
    if s:
        toks.append(("stmt", s))
    return toks


def parse_dts(path, labels, nodes, directives):
    text = strip_comments(open(path, encoding="utf-8", errors="replace").read())
    text = re.sub(r"^[ \t]*#[^\n]*", "", text, flags=re.M)      # #include, #define
    text = text.replace("/dts-v1/", " ").replace("/plugin/", " ")
    text = re.sub(r"/memreserve/\s*[^;]*;", " ", text)

    # &{/some/path} -- a reference to a node by path, used to extend a node that
    # only the included .dtsi declares.  Give each one a synthetic label.
    pathrefs = {}

    def _pathref(m):
        label = "__pathref%d" % len(pathrefs)
        pathrefs[label] = m.group(1)
        return "&" + label

    text = re.sub(r"&\{([^}]*)\}", _pathref, text)
    labels.update(pathrefs)

    toks = tokenize(text)
    stack = [""]
    i = 0
    while i < len(toks):
        kind = toks[i][0]
        if kind == "stmt":
            header = re.sub(r"\s+", " ", toks[i][1].replace("\n", " ")).strip()
            nxt = toks[i + 1][0] if i + 1 < len(toks) else None
            if header.startswith("/delete-node/") or header.startswith("/delete-property/"):
                parts = header.split(None, 1)
                directives.append((parts[0], parts[1] if len(parts) > 1 else ""))
                i += 2 if nxt == ";" else 1
                continue
            if nxt == "{":
                m = re.match(r"^(?:([A-Za-z0-9_]+)\s*:\s*)?(\S+)$", header)
                lab, name = (m.group(1), m.group(2)) if m else (None, header)
                if name.startswith("&"):
                    node_path = labels.get(name[1:], "&" + name[1:])
                elif name == "/":
                    node_path = ""
                else:
                    node_path = stack[-1] + "/" + name
                if lab:
                    labels[lab] = node_path
                stack.append(node_path)
                nodes.setdefault(node_path, {})
                i += 2
                continue
            if nxt == ";":
                if "=" in header:
                    pname, val = header.split("=", 1)
                    nodes.setdefault(stack[-1], {})[pname.strip()] = val.strip()
                else:
                    nodes.setdefault(stack[-1], {})[header.strip()] = None
                i += 2
                continue
        elif kind == "}":
            if len(stack) > 1:
                stack.pop()
        i += 1
    return nodes


# ---------------------------------------------------------------------------
# comparing one property
# ---------------------------------------------------------------------------
def dts_value(text):
    """Canonical form of a property value, or None when it cannot be compared.

    ('bool',)                 a boolean property
    ('bytes', b'..')          [02 00 00 ..]
    ('str', (..))             "one", "two"
    ('cells', [('int', n) | ('phandle', label) | ('any',), ..])
    ('str-any',)              a string-valued macro, only its shape is checked
    """
    if text is None:
        return ("bool",)
    chunks = [c.strip() for c in TOKEN.findall(text) if c.strip()]
    if not chunks:
        bare = text.strip().rstrip(",").strip()
        if re.match(r"^&[A-Za-z0-9_]+$", bare):
            return ("cells", [("phandle", bare[1:])])
        if re.match(r"^[A-Z][A-Z0-9_]*$", bare):
            return ("str-any",)
        return None
    kinds = set()
    for c in chunks:
        kinds.add("cells" if c[0] == "<" else "bytes" if c[0] == "[" else "str")
    if kinds == {"bytes"} and len(chunks) == 1:
        return ("bytes", bytes(int(x, 16) for x in chunks[0][1:-1].split()))
    if kinds == {"str"}:
        return ("str", tuple(c[1:-1] for c in chunks))
    if kinds == {"cells"}:
        cells = []
        for c in chunks:
            for tok in c[1:-1].split():
                if tok.startswith("&"):
                    cells.append(("phandle", tok[1:]))
                elif INT.match(tok):
                    cells.append(("int", int(tok, 0)))
                else:
                    cells.append(("any",))
        return ("cells", cells)
    return None


def is_string(raw):
    return bool(raw) and raw.endswith(b"\x00") and \
        all(32 <= b < 127 or b == 0 for b in raw)


def dtb_compare(raw, canon, phandle_of, paths_of):
    """(ok, explanation) for one property."""
    kind = canon[0]
    if kind == "bool":
        return raw == b"", "raw=%s" % raw.hex()
    if kind == "bytes":
        return raw == canon[1], "raw=%s" % raw.hex()
    if kind == "str-any":
        return is_string(raw), "raw=%s" % raw.hex()
    if kind == "str":
        got = tuple(p.decode("latin-1") for p in raw.split(b"\x00")[:-1])
        return got == canon[1], "image=%r" % (got,)
    if kind == "cells":
        want = canon[1]
        if len(want) == 1 and want[0][0] == "phandle" and is_string(raw):
            # dtc writes /aliases entries as the target node's path string
            got = raw[:-1].decode("latin-1")
            path = paths_of.get(want[0][1], "&" + want[0][1])
            return got == path, "image=%r  dts path=%r" % (got, path)
        if len(raw) != 4 * len(want):
            return False, "cell count: image=%d dts=%d" % (len(raw) // 4, len(want))
        got = list(struct.unpack(">%dI" % len(want), raw))
        for i, w in enumerate(want):
            if w[0] == "int" and got[i] != w[1]:
                return False, "cell %d: image=%d dts=%d" % (i, got[i], w[1])
            if w[0] == "phandle":
                want_ph = phandle_of.get(w[1])
                if want_ph is None:
                    return False, "cell %d: label &%s has no phandle in the image" % (i, w[1])
                if got[i] != want_ph:
                    return False, "cell %d: image=0x%x (&%s=0x%x)" % (i, got[i], w[1], want_ph)
        return True, ""
    return False, "unhandled value kind %r" % (kind,)


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: python3 tools/dts_vs_image.py <image.bin> "
                         "<board.dts> [<included.dtsi> ...]")
    img_path, dts_path, dtsi_paths = sys.argv[1], sys.argv[2], sys.argv[3:]

    blob = open(img_path, "rb").read()
    imgs = fit_subimages(blob)
    fdt_name = fdt_data = None
    for name, (props, data) in sorted(imgs.items()):
        kind = props.get("type", b"").split(b"\x00")[0].decode("latin-1")
        if kind == "flat_dt" or "fdt" in name:
            fdt_name, fdt_data = name, data
            break
    if fdt_name is None:
        raise SystemExit("no flat_dt sub-image in the FIT (found: %s)"
                         % ", ".join(sorted(imgs)))
    dtb = fdt_nodes(fdt_data)
    print("image     : %s" % img_path)
    print("FIT fdt   : %s (%d bytes, %d nodes)" % (fdt_name, len(fdt_data), len(dtb)))

    labels, directives = {}, []
    for p in dtsi_paths:
        parse_dts(p, labels, {}, directives)
    nodes = parse_dts(dts_path, labels, {}, directives)
    print("dts       : %s (%d nodes declared)" % (dts_path, len(nodes)))

    phandle_of = {}
    for label, node_path in labels.items():
        node = dtb.get(node_path)
        if node and len(node.get("phandle", b"")) == 4:
            phandle_of[label] = struct.unpack(">I", node["phandle"])[0]

    for kind, target in directives:
        if kind != "/delete-node/":
            print("  ?    %s %s (not checked)" % (kind, target))
            continue
        node_path = labels.get(target.lstrip("&"), target.lstrip("&"))
        if node_path in dtb:
            print("  BAD  /delete-node/ %s: the node is still in the image" % node_path)
        else:
            print("  ok   /delete-node/ %s: absent from the image" % node_path)

    missing_node, missing_prop, compared, mismatch, skipped = [], [], 0, [], []
    for path, props in sorted(nodes.items()):
        if path.startswith("&"):
            missing_node.append(path + "  (unresolved label)")
            continue
        if path not in dtb:
            missing_node.append(path)
            continue
        for prop, text in sorted(props.items()):
            if prop not in dtb[path]:
                missing_prop.append("%s:%s" % (path or "/", prop))
                continue
            canon = dts_value(text)
            if canon is None:
                skipped.append("%s:%s  (%s)" % (path or "/", prop, text[:70]))
                continue
            compared += 1
            ok, why = dtb_compare(dtb[path][prop], canon, phandle_of, labels)
            if not ok:
                mismatch.append("%s:%s\n        dts  : %s\n        %s"
                                % (path or "/", prop, text[:100], why))

    print()
    print("nodes declared in the dts but absent from the image : %d" % len(missing_node))
    for m in missing_node:
        print("   %s" % m)
    print("properties declared in the dts but absent         : %d" % len(missing_prop))
    for m in missing_prop:
        print("   %s" % m)
    print("properties compared                                : %d" % compared)
    print("properties that DIFFER                             : %d" % len(mismatch))
    for m in mismatch:
        print("   %s" % m)
    print("properties not comparable (mixed value shapes)     : %d" % len(skipped))
    for m in skipped:
        print("   %s" % m)
    return 1 if (missing_node or missing_prop) else 0


sys.exit(main())
