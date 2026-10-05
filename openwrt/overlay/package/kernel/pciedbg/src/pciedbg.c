// SPDX-License-Identifier: GPL-2.0
/*
 * pciedbg.c - cong cu chan doan PCIe cho EN7523 (42X6).
 *
 * Giao dien /proc/pciedbg:
 *   echo 'r  0x1fa91438'          > /proc/pciedbg   -> doc 32-bit
 *   echo 'w  0x1fa91448 0x21'     > /proc/pciedbg   -> ghi 32-bit
 *   echo 'rb 0x1fa91000 0x480'    > /proc/pciedbg   -> dump tu addr, do dai
 *   echo 'rb 0x20000000 0x40'     > /proc/pciedbg   -> doc BAR0 cua MT7915
 *   cat /proc/pciedbg                                -> xem ket qua
 *
 * Moi lenh deu ioremap vung trang tuong ung nen KHONG dung cho RAM thuong.
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/stdarg.h>
#include <linux/mm.h>
#include <linux/init.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/uaccess.h>
#include <linux/io.h>
#include <linux/slab.h>
#include <linux/string.h>

#define PCIEDBG_MAXOUT 16384
#define PCIEDBG_MAXCMD 256

static char *outbuf;
static size_t outlen;
static struct proc_dir_entry *pde;

static void outf(const char *fmt, ...)
{
	va_list ap;
	int n;

	if (outlen >= PCIEDBG_MAXOUT - 128)
		return;
	va_start(ap, fmt);
	n = vscnprintf(outbuf + outlen, PCIEDBG_MAXOUT - outlen, fmt, ap);
	va_end(ap);
	if (n > 0)
		outlen += n;
}

static int parse_u32(const char *s, unsigned long *v)
{
	char *end;
	unsigned long r = simple_strtoul(s, &end, 0);

	if (end == s)
		return -EINVAL;
	*v = r;
	return 0;
}

static void do_read(unsigned long phys)
{
	void __iomem *p;
	unsigned long base = phys & PAGE_MASK;
	unsigned int off = phys & ~PAGE_MASK;
	u32 v;

	p = ioremap(base, PAGE_SIZE);
	if (!p) {
		outf("r 0x%08lx = IOREMAP-FAIL\n", phys);
		return;
	}
	v = readl(p + off);
	iounmap(p);
	outf("r 0x%08lx = 0x%08x\n", phys, v);
}

static void do_write(unsigned long phys, u32 val)
{
	void __iomem *p;
	unsigned long base = phys & PAGE_MASK;
	unsigned int off = phys & ~PAGE_MASK;
	u32 old;

	p = ioremap(base, PAGE_SIZE);
	if (!p) {
		outf("w 0x%08lx <- IOREMAP-FAIL\n", phys);
		return;
	}
	old = readl(p + off);
	writel(val, p + off);
	outf("w 0x%08lx: 0x%08x -> 0x%08x (readback 0x%08x)\n",
	     phys, old, val, readl(p + off));
	iounmap(p);
}

static void do_rdump(unsigned long phys, unsigned long len)
{
	void __iomem *p;
	unsigned int off = phys & ~PAGE_MASK;
	unsigned long base = phys & PAGE_MASK;
	unsigned long total = len + off;
	unsigned long i;

	if (total > 4096)
		total = 4096;

	p = ioremap(base, PAGE_ALIGN(total));
	if (!p) {
		outf("rb 0x%08lx IOREMAP-FAIL\n", phys);
		return;
	}
	for (i = 0; i < total; i += 16) {
		int j;
		outf("%08lx:", base + i);
		for (j = 0; j < 16 && (i + j) < total; j += 4)
			outf(" %08x", readl(p + i + j));
		outf("\n");
	}
	iounmap(p);
}

static ssize_t pciedbg_write(struct file *f, const char __user *ubuf,
			     size_t count, loff_t *ppos)
{
	char kcmd[PCIEDBG_MAXCMD];
	char op[8], a1[32], a2[32];
	unsigned long p1, p2;
	int n;

	if (count >= sizeof(kcmd))
		count = sizeof(kcmd) - 1;
	if (copy_from_user(kcmd, ubuf, count))
		return -EFAULT;
	kcmd[count] = '\0';

	/* reset output cho moi lenh */
	outlen = 0;
	n = sscanf(kcmd, "%7s %31s %31s", op, a1, a2);
	if (n < 2) {
		outf("usage: r <phys> | w <phys> <val> | rb <phys> <len>\n");
		return count;
	}
	if (parse_u32(a1, &p1))
		return -EINVAL;

	if (!strcmp(op, "r")) {
		do_read(p1);
	} else if (!strcmp(op, "w")) {
		if (n < 3 || parse_u32(a2, &p2))
			return -EINVAL;
		do_write(p1, (u32)p2);
	} else if (!strcmp(op, "rb")) {
		p2 = 64;
		if (n >= 3)
			parse_u32(a2, &p2);
		do_rdump(p1, p2);
	} else {
		outf("unknown op '%s'\n", op);
	}
	return count;
}

static int pciedbg_show(struct seq_file *m, void *v)
{
	if (outlen)
		seq_write(m, outbuf, outlen);
	else
		seq_puts(m, "(chua co lenh nao)\n");
	return 0;
}

static int pciedbg_open(struct inode *inode, struct file *file)
{
	return single_open(file, pciedbg_show, NULL);
}

static const struct proc_ops pciedbg_pops = {
	.proc_open	= pciedbg_open,
	.proc_read	= seq_read,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
	.proc_write	= pciedbg_write,
};

static int __init pciedbg_init(void)
{
	outbuf = kzalloc(PCIEDBG_MAXOUT, GFP_KERNEL);
	if (!outbuf)
		return -ENOMEM;
	outlen = 0;
	outf("pciedbg ready. commands: r <phys> | w <phys> <val> | rb <phys> <len>\n");
	pde = proc_create("pciedbg", 0600, NULL, &pciedbg_pops);
	if (!pde) {
		kfree(outbuf);
		return -ENOMEM;
	}
	pr_info("pciedbg: /proc/pciedbg registered\n");
	return 0;
}

static void __exit pciedbg_exit(void)
{
	if (pde)
		proc_remove(pde);
	kfree(outbuf);
}

module_init(pciedbg_init);
module_exit(pciedbg_exit);
MODULE_LICENSE("GPL v2");
MODULE_DESCRIPTION("EN7523 PCIe register poking tool");
MODULE_AUTHOR("42X6 bring-up");
