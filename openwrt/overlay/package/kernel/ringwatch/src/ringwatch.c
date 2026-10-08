// SPDX-License-Identifier: GPL-2.0
/*
 * ringwatch.c - theo doi bang ring + trang thai WFDMA cua MT7916 tu phia host.
 *
 * Muc dich: tra loi "driver mt76 ghi desc_base vao thanh ghi ring cua chip,
 * gia tri co landing khong, WFDMA co duoc BAT khong, va sau do co bi reset
 * khong?" - bang cach poll moi 20 ms va IN RA moi thay doi kem so tick.
 * Khong can patch mt76 (nhung chay kem thi cang tot).
 *
 *   MT7916 BAR0 (function WF, 14c3:7906) = 0x22000000
 *   WFDMA0        tai BAR0 + 0xd4000 : RST +0x100, BUSY_ENA +0x13c,
 *                                     GLO_CFG +0x208, bang ring +0x300
 *   WFDMA0/PCIE1  tai BAR0 + 0xd8000 : cung layout (HIF thu hai)
 *
 * !!!! HAI HAZARD DA TRA GIA -- doc ky truoc khi sua:
 *
 *  (1) DOC BAR0 KHI `PCI_COMMAND.MEMORY = 0` => TREO CUNG SoC VINH VIEN.
 *      EN7523 khong co completion timeout: readl() tren PCIe master-abort quay
 *      mai; dang o softirq nen softirq bi chan => console chet han, khong oops,
 *      khong watchdog, chi power-cycle moi cuu.  => Phai doc PCI_COMMAND qua
 *      config space va CHI readl() BAR0 khi MEMORY = 1.
 *
 *  (2) KHONG duoc goi `ioremap()` TRONG CALLBACK CUA TIMER.
 *      `__get_vm_area_node()` co `BUG_ON(in_interrupt())`; BUG() tren ARM la
 *      `udf` => "Oops - undefined instruction", kernel hong trang thai va panic
 *      som.  => `ioremap()` chi dung bang trang, KHONG dung thiet bi, nen goi
 *      mot lan trong module_init (an toan ke ca khi MemEn = 0).
 *
 * KHONG autoload. Dung:
 *   insmod /tmp/ringwatch.ko
 *   (roi moi insmod mt7915e.ko)
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/timer.h>
#include <linux/jiffies.h>
#include <linux/pci.h>

#define RW_BAR0		0x22000000UL	/* MT7916 WF  (14c3:7906) */
#define RW_BAR0_HIF	0x20000000UL	/* MT7916 HIF (14c3:790a) */
#define RW_VENDOR	0x14c3
#define RW_W0_OFF	0xd4000UL
#define RW_W1_OFF	0xd8000UL
#define RW_WIN		0x1000UL
#define RW_TBL		0x300UL
#define RW_STRIDE	0x10UL
#define RW_NQ		24
#define RW_RST		0x100UL		/* MT_WFDMA0_RST */
#define RW_BUSY_ENA	0x13cUL		/* MT_WFDMA0_BUSY_ENA */
#define RW_GLO		0x208UL		/* MT_WFDMA0_GLO_CFG */
#define RW_GLO_TX_DMA_EN	0x00000001	/* BIT(0) */
#define RW_GLO_RX_DMA_EN	0x00000004	/* BIT(2) */
#define RW_PERIOD_MS	20
#define RW_MAX_TICKS	4000	/* 80 s */

struct rw_win {
	const char *tag;
	void __iomem *map;
	u32 snap[RW_NQ * 4];
	u32 rst, busy, glo;
};

static struct rw_win rw[2] = {
	{ .tag = "w0" },
	{ .tag = "w1" },
};

static struct timer_list rw_timer;
static unsigned int rw_tick;
static int rw_seen;
static struct pci_dev *rw_wf, *rw_hif;

static void rw_rearm(void)
{
	if (rw_tick < RW_MAX_TICKS)
		mod_timer(&rw_timer,
			  jiffies + msecs_to_jiffies(RW_PERIOD_MS));
}

/* Tim thiet bi PCI co BAR0 dung bang `bar`. Tra ve pci_dev DA giu refcount. */
static struct pci_dev *rw_find(u32 bar)
{
	struct pci_dev *p = NULL;

	while ((p = pci_get_device(PCI_ANY_ID, PCI_ANY_ID, p))) {
		if (p->vendor == RW_VENDOR && p->resource[0].start == bar)
			return p;
	}
	return NULL;
}

/* CHI doc config space - an toan ke ca khi thiet bi chua duoc enable. */
static int rw_mem_enabled(struct pci_dev *p)
{
	u16 cmd = 0;

	if (!p)
		return 0;
	if (pci_read_config_word(p, PCI_COMMAND, &cmd))
		return 0;
	return (cmd & PCI_COMMAND_MEMORY) ? 1 : 0;
}

static void rw_scan(struct rw_win *w)
{
	unsigned int i;

	for (i = 0; i < RW_NQ; i++) {
		void __iomem *r = w->map + RW_TBL + i * RW_STRIDE;
		u32 b, c, ci, di, *s = &w->snap[i * 4];

		b = readl(r + 0x00);
		c = readl(r + 0x04);
		ci = readl(r + 0x08);
		di = readl(r + 0x0c);
		if (rw_seen && b == s[0] && c == s[1] &&
		    ci == s[2] && di == s[3])
			continue;

		pr_info("RINGW t=%u %s q%-2u base=%08x cnt=%08x cidx=%-4u didx=%-4u\n",
			rw_tick, w->tag, i, b, c, ci, di);
		s[0] = b;
		s[1] = c;
		s[2] = ci;
		s[3] = di;
	}
}

static void rw_status(struct rw_win *w)
{
	u32 v;

	v = readl(w->map + RW_RST);
	if (!rw_seen || v != w->rst) {
		pr_info("RINGW t=%u %s RST=%08x\n", rw_tick, w->tag, v);
		w->rst = v;
	}
	v = readl(w->map + RW_BUSY_ENA);
	if (!rw_seen || v != w->busy) {
		pr_info("RINGW t=%u %s BUSY_ENA=%08x\n", rw_tick, w->tag, v);
		w->busy = v;
	}
	v = readl(w->map + RW_GLO);
	if (!rw_seen || v != w->glo) {
		pr_info("RINGW t=%u %s GLO_CFG=%08x tx_en=%u rx_en=%u\n",
			rw_tick, w->tag, v,
			!!(v & RW_GLO_TX_DMA_EN), !!(v & RW_GLO_RX_DMA_EN));
		w->glo = v;
	}
}

static void rw_tick_fn(struct timer_list *t)
{
	rw_tick++;

	if (!rw_wf) {
		rw_wf = rw_find(RW_BAR0);
		rw_hif = rw_find(RW_BAR0_HIF);
		if (rw_wf)
			pr_info("RINGW t=%u: thay WF %s, HIF %s\n", rw_tick,
				pci_name(rw_wf),
				rw_hif ? pci_name(rw_hif) : "(khong co)");
		else if (rw_tick == 1 || rw_tick % 250 == 0)
			pr_info("RINGW t=%u: chua thay thiet bi BAR0=%08lx\n",
				rw_tick, RW_BAR0);
	}

	/* CHUA MemEn thi TUYET DOI khong cham vao BAR0 (xem hazard (1)) */
	if (!rw_wf || !rw_mem_enabled(rw_wf))
		goto rearm;

	if (!rw_seen)
		pr_info("RINGW t=%u: MemEn BAT tren %s -> bat dau doc\n",
			rw_tick, pci_name(rw_wf));

	rw_status(&rw[0]);
	rw_scan(&rw[0]);

	/* Cua so PCIE1 chi doc khi HIF cung da bat MemEn (neu tim thay HIF). */
	if (!rw_hif || rw_mem_enabled(rw_hif)) {
		rw_status(&rw[1]);
		rw_scan(&rw[1]);
	}
	rw_seen = 1;

rearm:
	rw_rearm();
}

static int __init rw_init(void)
{
	/* ioremap chi dung bang trang - KHONG dung thiet bi -> an toan o day. */
	rw[0].map = ioremap(RW_BAR0 + RW_W0_OFF, RW_WIN);
	rw[1].map = ioremap(RW_BAR0 + RW_W1_OFF, RW_WIN);
	if (!rw[0].map || !rw[1].map) {
		pr_err("RINGW: ioremap that bai\n");
		if (rw[0].map)
			iounmap(rw[0].map);
		if (rw[1].map)
			iounmap(rw[1].map);
		return -ENOMEM;
	}

	pr_info("RINGW: theo doi BAR0 %08lx (w0 +%lx, w1 +%lx) moi %d ms, toi da %d tick\n",
		RW_BAR0, RW_W0_OFF, RW_W1_OFF, RW_PERIOD_MS, RW_MAX_TICKS);
	pr_info("RINGW: se KHONG readl() BAR0 cho toi khi PCI_COMMAND.MemEn = 1\n");

	timer_setup(&rw_timer, rw_tick_fn, 0);
	mod_timer(&rw_timer, jiffies + msecs_to_jiffies(RW_PERIOD_MS));
	return 0;
}

static void __exit rw_exit(void)
{
	timer_delete_sync(&rw_timer);
	iounmap(rw[0].map);
	iounmap(rw[1].map);
	if (rw_wf)
		pci_dev_put(rw_wf);
	if (rw_hif)
		pci_dev_put(rw_hif);
	pr_info("RINGW: dung\n");
}

module_init(rw_init);
module_exit(rw_exit);
MODULE_LICENSE("GPL v2");
MODULE_DESCRIPTION("MT7916 WFDMA ring/status watcher (42X6 bring-up)");
MODULE_AUTHOR("42X6 bring-up");
