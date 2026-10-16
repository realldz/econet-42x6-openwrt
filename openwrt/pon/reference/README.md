# PON reference material

`airoha_eth_xpon_lines.txt` was a raw `grep -n 'xpon'` dump of the community
EN7523 tree, kept here while the xPON hooks were being located. It is **not**
shipped in this repository, for two reasons:

1. it contained verbatim fragments of third-party kernel source, which belongs
   in that project, not copied into this one; and
2. it is reproducible in one command, so keeping it added no information.

Regenerate it on demand against the community tree
([`Sirherobrine23/airoha_kernel`](https://github.com/Sirherobrine23/airoha_kernel),
branch `airoha_en7523_all`):

```bash
SRC=/path/to/airoha_kernel

for f in drivers/net/ethernet/airoha/airoha_eth.c \
         drivers/net/ethernet/airoha/airoha_eth.h \
         drivers/net/ethernet/airoha/airoha_ppe.c; do
    echo "===== $f ($(wc -l < "$SRC/$f") lines) ====="
    grep -n 'xpon' "$SRC/$f"
done
```

The patches in `../patches/` were authored for this project. The files in
`../reference/` are third-party patches kept for comparison; their filenames
carry a `ref-` prefix to keep them apart from the ones we apply.

## Retired first-generation hooks (kept for history)

`010`/`011` (net Kconfig/Makefile), `020`/`021` (drivers/net optical
Kconfig/Makefile) and `032`/`033` (airoha Kconfig/Makefile) were the
first-generation xPON hook patches, applied by hand to a prepared kernel
tree. They are superseded by the route-A hooks -- `930-55`..`930-58` carry
the same hunks and `930-53`/`930-54` carry the optical pair -- which now live
in `../patches-6.18/` and are copied into the series only by
`scripts/apply-overlay.sh --with-pon`, because two of them make kconfig
source paths that only the community `airoha_en7523_all` branch carries.
They are kept here so the history stays readable, but nothing applies them
anymore.
