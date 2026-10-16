#!/usr/bin/env python3
"""Check what the release run actually published, against what it promised.

The CI verifies the images before publishing, but nothing checks the published
result: a release whose gh-pages push half-succeeded, or whose kmod index names a
directory that is not there, looks fine from the Actions tab.  This reads the
release, the branch and the live Pages URL and reports each piece.

    python3 tools/verify_publish.py [tag]

Run it against a tag that has been released.  Measured on v0.1.0-m2, the release of
run 38939207748: 19 checks, all passing (4 release assets, 59 files on gh-pages, 46
kernel modules, the index served as an apk v3 database).

One trap this tool fell into first and now documents: an apk index on main is the
binary ADB format (it begins 'ADBd'), not a text file with 'P: name' lines, so a
checker that parses it as text counts zero packages in a repository that is full of
them.  What says whether the modules are there is the published directory, which is
why the module count comes from the gh-pages listing and from metadata.json.

Exit status is 0 only when every piece is present.
"""

import json
import subprocess
import sys
import urllib.error
import urllib.request

REPO = "realldz/econet-42x6-openwrt"
PAGES = "https://realldz.github.io/econet-42x6-openwrt"
TAG = sys.argv[1] if len(sys.argv) > 1 else "v0.1.0-m2"

problems = []
lines = []


def gh(*args):
    res = subprocess.run(["gh"] + list(args), capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError("gh %s failed: %s" % (" ".join(args),
                                                res.stderr.strip()))
    return res.stdout


def check(what, ok, detail=""):
    lines.append("  %-4s %-46s %s" % ("ok" if ok else "FAIL", what, detail))
    if not ok:
        problems.append(what)
    return ok


def fetch(url):
    try:
        with urllib.request.urlopen(url, timeout=30) as resp:
            return resp.read()
    except urllib.error.HTTPError as exc:
        return b"!! HTTP %d" % exc.code
    except Exception as exc:                              # noqa: BLE001
        return ("!! %s: %s" % (type(exc).__name__, exc)).encode()


def main():
    print("== the GitHub Release %s" % TAG)
    try:
        release = json.loads(gh("release", "view", TAG, "--repo", REPO,
                                "--json", "assets,tagName,url,isDraft"))
    except RuntimeError as exc:
        print("  FAIL %s" % exc)
        print("\nthe release does not exist yet")
        return 1

    assets = {a["name"]: a["size"] for a in release["assets"]}
    check("release is not a draft", not release["isDraft"], release["url"])

    sysup = [n for n in assets if "sysupgrade" in n and n.endswith(".bin")]
    initr = [n for n in assets if "initramfs" in n and n.endswith(".bin")]
    ib = [n for n in assets if n.startswith("openwrt-imagebuilder-")
          and n.endswith(".tar.zst")]
    # A persistent image that lost its rootfs, or one built with the initramfs
    # embedded, is ~9.4 MB and ~12 MB against a 128 MiB flash: the earlier
    # accident is visible in the size alone, so it is worth asserting here too.
    check("a sysupgrade image", len(sysup) == 1, ", ".join(sysup) or "none")
    if sysup:
        size = assets[sysup[0]]
        check("its size is the persistent one", 8_000_000 < size < 11_000_000,
              "%d bytes" % size)
    check("an initramfs image", len(initr) == 1, ", ".join(initr) or "none")
    check("an Image Builder tarball", len(ib) == 1,
          "%s (%d bytes)" % (ib[0], assets[ib[0]]) if ib else "none")
    check("SHA256SUMS", "SHA256SUMS" in assets)

    print()
    print("== the gh-pages branch")
    try:
        tree = json.loads(gh("api", "repos/%s/contents?ref=gh-pages" % REPO))
        names = sorted(e["name"] for e in tree)
        check("releases.json", "releases.json" in names, ", ".join(names[:6]))
        check("the tag directory", TAG in names)
        if TAG in names:
            sub = json.loads(gh("api", "repos/%s/contents/%s?ref=gh-pages"
                                % (REPO, TAG)))
            files = sorted(e["name"] for e in sub)
            for want in ("install.md", "metadata.json"):
                check("%s/%s" % (TAG, want), want in files,
                      ", ".join(files))
        index = fetch("%s/releases.json" % PAGES)
        try:
            releases = json.loads(index)
            tags = [r.get("tag") for r in releases]
            check("releases.json lists the tag", TAG in tags, ", ".join(tags))
        except ValueError:
            check("releases.json parses", False, index[:80].decode(errors="replace"))
    except RuntimeError as exc:
        check("gh-pages exists", False, str(exc)[:80])

    print()
    print("== the live Pages URL (what a board would fetch)")
    index_url = "%s/%s/kmods/<kernel>/packages.adb" % (PAGES, TAG)
    install = fetch("%s/%s/install.md" % (PAGES, TAG))
    check("install.md is served", install[:2] != b"!!",
          "%d bytes" % len(install))
    if install[:2] != b"!!":
        text = install.decode(errors="replace")
        # The directory name is the one thing a user must not guess, so it has to
        # be in this file.
        check("install.md names the kmod directory", "kmods/" in text,
              [l for l in text.splitlines() if "kmods/" in l][:1])
    meta = fetch("%s/%s/metadata.json" % (PAGES, TAG))
    kernel = None
    recorded = {}
    if meta[:2] != b"!!":
        try:
            recorded = json.loads(meta)
            kernel = recorded.get("kmods")
        except ValueError:
            pass
    check("metadata.json names the repository", bool(kernel), str(kernel))
    if kernel:
        url = "%s/%s/%spackages.adb" % (PAGES, TAG, kernel)
        body = fetch(url)
        # apk v3 indexes are the binary ADB format -- 'ADBd' magic, no 'P: name'
        # lines -- so this only checks that the served file is a real index rather
        # than the 404 page.  An earlier version of this script parsed it as text and
        # counted zero kernel modules in a repository that holds 46 of them; the
        # published directory is what says whether they are there.
        ok = body[:4] == b"ADBd" and len(body) > 1024
        check("the index is served and is an apk v3 index", ok,
              "%s (%d bytes, magic %r)" % (url, len(body), body[:4]))
        check("metadata.json records kernel modules", recorded.get("kernel_modules", 0) > 0,
              "%s module(s), %s package(s) from %s"
              % (recorded.get("kernel_modules"), recorded.get("packages_published"),
                 recorded.get("source_dir")))
        # The branch is the published truth: list it and count the modules.
        try:
            listing = json.loads(gh(
                "api", "repos/realldz/econet-42x6-openwrt/contents/%s/%s?ref=gh-pages"
                % (TAG, kernel.strip("/"))))
            names = [e["name"] for e in listing]
            apks = [n for n in names if n.startswith("kmod-") and n.endswith(".apk")]
            check("gh-pages holds the kernel modules", bool(apks),
                  "%d kmod-*.apk of %d file(s), e.g. %s"
                  % (len(apks), len(names), apks[0] if apks else "-"))
            check("gh-pages holds the kernel package",
                  any(n.startswith("kernel-") and n.endswith(".apk") for n in names),
                  next((n for n in names if n.startswith("kernel-")), "-"))
            # A version string that is not the plain kernel version is normal: the
            # mac80211/cfg80211 backports are built as 6.18.54.7.2 and the mt76 ones
            # as 6.18.54.2026.09.01~be5ce791, and apk tells them apart by
            # `depends: kernel (=<version>)` rather than by file name.
            odd = [n for n in apks if not n.startswith("kmod-") or n.split("-", 1)[1]
                   .split("-r")[0] != "%s" % recorded.get("kernel")]
            check("every module names the kernel or a variant of it",
                  all(str(recorded.get("kernel")) in n for n in apks),
                  "%d with a suffixed version (backports/mt76), e.g. %s"
                  % (len(odd), odd[0] if odd else "-"))
        except (RuntimeError, ValueError, KeyError) as exc:
            check("gh-pages holds the kernel modules", False, str(exc)[:80])

    print()
    print("\n".join(lines))
    print()
    if problems:
        print("%d problem(s): %s" % (len(problems), ", ".join(problems)))
        return 1
    print("everything the release promised is published and reachable")
    return 0


if __name__ == "__main__":
    sys.exit(main())
