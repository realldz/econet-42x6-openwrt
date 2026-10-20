# Image Builder helpers

See [docs/image-builder.md](../docs/image-builder.md) for the full explanation of
why this project ships its own Image Builder instead of using OpenWrt's.

Quick reference:

```bash
# once, from source: produce the Image Builder
./scripts/build-imagebuilder.sh /path/to/openwrt -j8
# -> dist/openwrt-imagebuilder-airoha-en7523.*.tar.zst

# then, as often as you like: compose an image
./imagebuilder/build-image.sh dist/openwrt-imagebuilder-airoha-en7523.*.tar.zst \
    --all-packages
```

| File | Purpose |
|---|---|
| `build-image.sh` | Extracts the Image Builder, runs `make image`, and collects the results with checksums. |
| `packages.txt` | Curated package list used by `--all-packages`: the Wi-Fi AP daemon, the web UI, the package manager and diagnostics. Comment out what you do not want. They need to be baked in, because target airoha/en7523 is source-only: no `kmods/` directory is published for it, so every kernel module the image wants has to be inside it. |
| `files/` | Overlay copied into the image root. Currently a single first-boot script setting the hostname -- deliberately minimal, because the board generates its own network and wireless configuration, and the wireless interfaces stay disabled until an operator enables them. |

Two things that commonly go into `files/`:

* `/etc/config/wireless` -- if you want a pinned configuration instead of the
  generated one, start from
  [`openwrt/optional-configs/etc-config-wireless.example`](../openwrt/optional-configs/etc-config-wireless.example).
* `/lib/firmware/mediatek/mt7916_eeprom.bin` -- the default eeprom blob with
  your unit's MAC written into it, otherwise Wi-Fi comes up with a random MAC
  on every boot (the Image Builder tree has no flash-backed MAC cell). Produce
  it with
  [`tools/mt7916_eeprom_mac.py`](../tools/mt7916_eeprom_mac.py).

You can also drive the Image Builder directly:

```bash
tar --zstd -xf openwrt-imagebuilder-airoha-en7523.*.tar.zst
cd openwrt-imagebuilder-airoha-en7523.*
make image PROFILE=econet_vgp-42x6v1 PACKAGES="luci luci-ssl"
```

The profile name is `econet_vgp-42x6v1`. Run `make info` inside the extracted
directory to list the profiles and packages your tarball actually contains --
useful when you are not sure whether a package was built.

## Before you publish an image

One per-unit thing ends up inside an image built this way, and it identifies the
unit that built it: the eeprom blob in `files/`, once you have written your MAC
into it (above). The flashed sysupgrade image does not have this problem: its
device tree reads the base MAC from the U-Boot environment in flash, so nothing
per-unit is baked in.

An image built that way is fine for the unit it was made for, but it is not
something to hand out: it carries that unit's address. The repository ships no
eeprom blob for exactly this reason -- each owner runs
[`tools/mt7916_eeprom_mac.py`](../tools/mt7916_eeprom_mac.py) against their own
board, so no two published images share an identity.
