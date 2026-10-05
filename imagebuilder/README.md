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
| `packages.txt` | Curated optional package list used by `--all-packages`. Comment out what you do not want. |
| `files/` | Overlay copied into the image root. Currently a single first-boot script setting the hostname -- deliberately minimal, see the doc. |

You can also drive the Image Builder directly:

```bash
tar --zstd -xf openwrt-imagebuilder-airoha-en7523.*.tar.zst
cd openwrt-imagebuilder-airoha-en7523.*
make image PROFILE=econet_vgp-42x6v1 PACKAGES="luci luci-ssl"
```

The profile name is `econet_vgp-42x6v1`. Run `make info` inside the extracted
directory to list the profiles and packages your tarball actually contains --
useful when you are not sure whether a package was built.
