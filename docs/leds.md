# Front-panel LEDs, buttons, and the WLAN 2.4/5 GHz LED fix in mt76

Target: Econet vGP-42X6V1 GPON ONU, Airoha EN7523 SoC (2x Cortex-A53 running AArch32), SPI-NAND, MediaTek MT7916 Wi-Fi behind PCIe, OpenWrt on Linux
6.18.

This document covers the eleven front-panel LEDs, the two buttons, and the defect that took the longest to find: the 2.4 GHz and 5 GHz LEDs are
**not** board GPIOs. They are two pads of the MT7916, reachable only through a four-bit pad-mux register, and the mt76 driver never wrote it. Every
number, register name and log line below comes from measurements on the unit, the board device tree, or the three mt76 patches in this repository;
anything not confirmed on hardware is marked as such, and the WPS LED is still an open question.

- board device tree: [en7523-vgp42x6v1.dts](../openwrt/overlay/target/linux/airoha/dts/en7523-vgp42x6v1.dts)
- mt76 patches: [100](../openwrt/overlay/package/kernel/mt76/patches/100-mt7916-pcie-led-mux.patch),
  [101](../openwrt/overlay/package/kernel/mt76/patches/101-mt7916-led-mux-control.patch),
  [102](../openwrt/overlay/package/kernel/mt76/patches/102-mt7916-led-follow-radio.patch)

The bring-up scripts (`ledmap.sh`, `find42x6.sh`, `ledprop.sh`, `socpads.sh`, `mux_manual.sh`) live outside this repository. LED and button statements
in [docs/status.md](status.md), section 9 of [docs/hardware.md](hardware.md) and the LED item in [docs/roadmap.md](roadmap.md) predate this mapping.

## 1. Front panel inventory

| LED | Silkscreen | Driven by | Pad | Mapped? |
|---|---|---|---|---|
| Power | PWR | `gpio-leds` | gpio 27 | yes, lit from boot |
| PON | PON | `gpio-leds` | gpio 10 | yes |
| LOS | **ALM** | `gpio-leds` | gpio 6 | yes |
| Internet | **INET** | `gpio-leds` | gpio 1 | yes |
| LAN1..LAN4 | LAN1..LAN4 | internal switch LED engine | 22..25 (muxed to the switch) | not a Linux GPIO |
| WPS | WPS | not found | -- | **no** (open) |
| 2.4G | 2.4G | MT7916 pad via `MT_LED_GPIO_MUX1` | chip pad 14 | yes, patches 100+101+102 |
| 5G | 5G | MT7916 pad via `MT_LED_GPIO_MUX1` | chip pad 15 | yes, patches 100+101+102 |

## 2. The measured LED map, and why PWR needs `default-state = "on"`

Method: drive every pad high (LEDs off), then **one** pad low, and read back the register of live pad levels (`data[]`, offset `0x04` of `0x1fbf0200`)
to prove the pad really moved; register and eye agreed in every case, and `gpio = 512 + pad` (gpio 513 is pad 1, gpio 539 is pad 27).

**PWR needs a `default-state` because of its power-on level.** Right after boot the only lit LED is PWR and `data[]` reads `07abf6cb`: the nibble
covering bits 27..24 is `0,1,1,1`, so **bit 27 is 0** at reset. The pad is low because of the register's power-on value, not because a driver drove it
-- the earlier device tree had no LED node on pad 27 at all -- so the device tree keeps `default-state = "on"` and PWR is lit from boot, as on the
stock firmware. The output-enable register (`0x14`) reads `0x08000442`, enabling exactly pads 1, 6, 10 and 27.

**The wrong guesses, and the bug they caused.** Images 15 and 16 declared `led_power` on gpio 11, `led_los` on gpio 3, `led_wps` on gpio 26 and
`led_wlan` on gpio 6, all copied from the vendor table. Pads 11, 3 and 26 have no LED, which is the **"POWER cannot be controlled"** bug those images
shipped, and the LED on pad 6 is the **red LOS/ALM**, not a WLAN LED. Image 17 fixed the map: PWR to 27 with `default-state = "on"`, LOS to 6, INET
added on 1, WLAN and WPS nodes deleted, class names `green:power` -> `blue:power` (nothing on the board used the old names).

**LAN1..LAN4 are not Linux GPIOs**: pads 22..25 are muxed to the internal switch's LED engine, whose mode bits SCU `0x1fa20210` bits 3, 5, 7 and 9
(`LAN0..3_LED0_MODE`, together `0x2a8`) the switch driver restores after the pinctrl driver cleared them, logging `mt7530-mmio 1fb58000.switch: EN7523: SCU 0x0210 restored 0x0->0x2a8`. Writing those pads from Linux does nothing, and no LED node exists for them.

## 3. What the stock firmware does, and why its LED table was only a hint

The stock rootfs ships a vendor LED module, `tcledctrl.ko` (58,728 bytes, `TC3162 LED Manager 0.1`). It is an SoC-level manager, not a board driver:
it reads a table of four bytes per LED `{gpio, mode, speed, onoff}` (`ledGetGpio()` is `base[led_no * 4]`) from a per-board file under `/userfs`
(`led.conf`, `7523duled.conf`, `7523guled.conf`, `7523suled.conf`, `7529_62led.conf`, `led_fpga.conf`), and it is driven through
`/proc/tc3162/led_test` (`echo on|off|status <led_no> >`). A userspace helper, `bin/ledctrl`, carries its own compiled-in table naming pads 27, 11,
10, 7, 6, 12 and 1 only, with no WLAN entry.

On this board the stock init script does not take the branch that copies a per-board file, and there is no `/etc/led.conf` in the rootfs, so the
reference table `7523duled.conf` is a **hint**, not the truth -- and as a hint it was misleading: it maps PWR to gpio 11, LOS to gpio 3, WLAN 2.4G to
gpio 6, WPS to gpio 26 and Internet to gpio 29, while pads 11, 3 and 26 have no LED, the LED on pad 6 is the **red LOS/ALM**, gpio 29 is
`pcie_reset1`, and the vendor's WLAN LED numbers (`13/14/15`) are zero in every one of the six config files. The vendor data narrowed the search; the
final map came from measuring the unit, one pad at a time.

**The pads are plain GPIOs**: no SIPO and no expander is in the path -- SCU `0x1fbf0218` reads 0, so `SIPO` and `SIPO_RCLK` are not selected as pin
functions; `tcledctrl.ko` contains no SIPO, shift-register or LED-controller strings; and there is no I2C GPIO expander on the board.

## 4. Buttons

Reset is **gpio 0** (`KEY_RESTART`): the hotplug log shows pressed/released events and a short press reboots. WPS is **gpio 7** (`KEY_WPS_BUTTON`); it
was unresponsive before image 16 (30 s hold, nothing). Both are declared `gpio-keys-polled` with `poll-interval = <100>` (100 ms), not as interrupt
keys, because the GPIO bank that existed before image 16 (`airoha,en7523-gpio`) declared **no** `interrupt-controller` and this SoC only lets
GPIO0..GPIO15 raise an interrupt ("only GPIO0-GPIO15 can raise an interrupt, poll the rest", as an in-tree board file for a sibling SoC puts it).
Image 16 replaced that bank with the pinctrl node, which **does** declare an interrupt controller (GIC SPI 26), so interrupt-driven keys became
possible; the polled binding was kept on purpose to change one variable at a time, and moving to `gpio-keys` with real interrupts is an open item, not
a problem.

Button events do not use the input subsystem: OpenWrt is built with `# CONFIG_INPUT is not set`, so `/dev/input` and `/sys/class/input` **never**
exist even when the buttons work -- do not look for `event*`, do not reach for `evtest`. The chain is `gpio_keys_polled` ->
`button_hotplug_create_event()` -> `/etc/hotplug.json` (`SUBSYSTEM == "button"` => `[ "button", "/etc/rc.button/%BUTTON%" ]`) ->
`/etc/rc.button/<name>`, run by procd; the string `rc.button` does not appear in the driver source.

Default `reset.orig`: a quick press reboots, and **holding 5 s or more runs `factoryreset -y`**. Verification without the input subsystem:
`/sys/class/leds`, `/sys/kernel/debug/gpio`, the binding under `/sys/bus/platform/drivers/gpio-keys-polled/keys`, a logging wrapper around
`/etc/rc.button/<name>`, `logread`, and `gpio_button_hotplug` in the module list. **Trap:** a button held while the board boots sends it into failsafe
-- that is how the WPS button was found to work.

## 5. One gpiochip instead of two register banks

The EN7523 device tree shipped two legacy GPIO banks (`airoha,en7523-gpio`, mapped over `0x1fbf0204/0200/0220/0214` and `0x1fbf0270/0260/0264/0278`).
Those windows overlap the pinctrl window `0x1fbf0200..0x1fbf02bf`, so the two drivers cannot coexist: both were deleted (`/delete-node/ &gpio0;` and
`&gpio1;`), and every pad the board uses -- five LED pads and two button pads at the time, four LEDs after image 17 -- now comes from one gpiochip.

```text
system-controller@1fbf0200 {
        compatible = "syscon", "simple-mfd";  reg = <0x1fbf0200 0xc0>;
        pinctrl { compatible = "airoha,en7523-pinctrl";  airoha,chip-scu = <&scu>;
                  interrupts = <GIC_SPI 26 IRQ_TYPE_LEVEL_HIGH>;
                  gpio-controller;  #gpio-cells = <2>;
                  interrupt-controller;  #interrupt-cells = <2>;
                  gpio-ranges = <&en7523_pinctrl 0 12 30>; }; };
```

- `reg` must be `0xc0`, not the vendor tree's `0x80`: the interrupt registers reach `0x94` and `LAN_LED1_MAPPING` is at `0x7c`. `airoha,chip-scu = <&scu>` is **mandatory** -- without the phandle the driver falls back to a compatible string no device tree declares, the probe returns `-ENODEV`, and
  there is no gpiochip at all, so every LED and button disappears.
- `gpio-ranges` is **mandatory** in practice: `airoha_convert_pin_to_reg_offset()` goes through `pinctrl_find_gpio_range_from_pin_nolock()`, so without
  a range every set/get returns `-EINVAL`; pad N maps to pinctrl line N, and after boot `gpio-ranges` reports `GPIOS [512 - 541] PINS [12 - 41]`.

The kernel patch `203-02-pinctrl-airoha-reset-SCU-IOMUX-registers-at-probe.patch` writes 0 to five SCU IOMUX registers during probe, before the
gpiochip is registered: `0x1fa20210` (`REG_GPIO_2ND_I2C_MODE`, second I2C plus the switch's eight LED pins), `0x1fa20214` (`REG_GPIO_SPI_CS1_MODE`,
PCM/SPI plus the LOS pad), `0x1fa20218` (`REG_GPIO_PON_MODE`, SIPO and the PON LED path), `0x1fa20220` (`REG_NPU_UART_EN`) and `0x1fa20224`
(`REG_FORCE_GPIO_EN`, JTAG/DFD). On EN7523 the polarity is **0 = GPIO**; AN7583 is the opposite (bits 15..26 must be 1), so values from an AN7583 port
must not be copied.

**What the register-level investigation ruled out.** Reading the registers of the running board showed the state was already what the design intends,
so any further register poke is a no-op -- recorded so nobody repeats it. SCU `0x1fa20210` read `0x2a8`, exactly `LAN0..3_LED0_MODE`, with no bit for
any LED or button pad; SCU `0x1fa20214/0218/0220/0224` all read 0, i.e. SPI_CS1, PON_MODE (SIPO/SIPO_RCLK), NPU UART and FORCE_GPIO were already in
GPIO mode; and `0x1fbf0234`/`0x1fbf0268` (`REG_GPIO_FLASH_MODE_CFG` and `_EXT`) read 0, so no pad was stuck in PWM/flash mode. Two traps:
`pinmux-pins` output is pinctrl-core bookkeeping (the driver has no `.pinmux_get`), not a mux read; and the `out lo`/`out hi` column of
`/sys/kernel/debug/gpio` is gpiolib's cached state -- on image 15 `gpio-11` showed `out lo` while its LED did not move.

## 6. The WLAN 2.4/5 GHz LEDs are not board GPIOs

They are not on the SoC at all: driving 17 candidate pads (`2,3,4,5,8,9,11,12,13,14,15,17,18,19,20,21,26`) high at once lit no WLAN LED; driving 30
pads low one at a time lit only pad 1 (INET), 6 (LOS/ALM), 10 (PON) and 27 (PWR); driving the switch LED engine's eight outputs (gpio 22..25 and 4..7)
in both polarities lit nothing; and reading the whole MT7916 GPIO page `0x70005000..0x7000507c` while toggling `brightness` showed no register there
reflects the pad level. The stock firmware does light both LEDs, so they are connected -- to the MT7916's own LED pads, which a pad-mux register
routes to physical pins, four bits per pad:

| Register | Address | Pads | Field of pad *p* |
|---|---|---|---|
| `MT_LED_GPIO_MUX0` | `0x70005050` | 0..7 | bits `4*p .. 4*p+3` |
| `MT_LED_GPIO_MUX1` | `0x70005054` | 8..15 | bits `4*(p-8) ..` |
| `MT_LED_GPIO_MUX2` | `0x70005058` | 16..23 | bits `4*(p-16) ..` |
| `MT_LED_GPIO_MUX3` | `0x7000505c` | 24..31 | bits `4*(p-24) ..` |

```text
2.4 GHz LED -> chip pad 14 -> MT_LED_GPIO_MUX1 bits [27:24]      pad function code 4 = ON, 0 = OFF
5.0 GHz LED -> chip pad 15 -> MT_LED_GPIO_MUX1 bits [31:28]
```

The first reading showed the contradiction that started the hunt: `MT_LED_EN(0)` and `MT_LED_EN(1)` were 1 and `MT_LED_STATUS_0(0)` was `0x00ffffff`
(ON = `0xff`, i.e. "on"), while all four `MT_LED_GPIO_MUX*` registers read `0x00000000` -- the LED block was powered and configured, but nothing was
routed to a pad. The pad mux is the **only** switch that reaches the pins: experiments against the chip's internal LED block (writing
`MT_LED_STATUS_0/1` PWM duty, then `MT_LED_CTRL` TX_BLINK, BLINK_MODE and POLARITY, then clearing bits 14/15 in `0x70005040`) all held the values
written when read back and never moved a pad, whereas writing the mux field does change the pad level (`4` = on, `0` = off; code `15` also lights it).
So the LED has two states and blinking has to be produced in software.

Chip registers are reachable from Linux without `/dev/mem` through mt76's debugfs, which takes the chip's own remap path (`mt7915_wr`); with
`D=/sys/kernel/debug/ieee80211/phy0/mt76`, `echo 0x70005054 > $D/regidx; cat $D/regval` reads `MT_LED_GPIO_MUX1` and `echo 0x44000000 > $D/regval`
lights both pads. Code `4` was the **first** candidate tried and both LEDs lit at once, so the other fifteen codes were never needed (code `15`
behaves the same, code `3` does not work on this chip).

## 7. Root cause and fix: patches 100, 101 and 102

### 7.1 Patch 100 -- the driver never wrote the mux

`mt76_chip()` returns `dev->rev >> 16`, and on a PCIe card `dev->rev` is built from the **PCI device id**. This board's Wi-Fi function is `14c3:7906`,
so `mt76_chip()` is `0x7906` -- not `0x7916`, which is the SoC-integrated MT7916 inside MT7986. `mt7915_init_led_mux()` had cases for `0x7915` and
`0x7916` plus a `default:` that does nothing, so for this chip **no mux register was ever written**: that is why the LEDs stayed dark while the LED
block was fully enabled. Patch 100 adds `case 0x7906` to all three switch sites in `mt7915/init.c`, writing the 2.4 GHz field, the 5 GHz field, or
both:

```c
case 0x7906:
	/* discrete MT7916 (PCI id 0x7906): pad function code is 4, not 3 */
	mt76_rmw_field(dev, MT_LED_GPIO_MUX1, GENMASK(27, 24), 4);
	mt76_rmw_field(dev, MT_LED_GPIO_MUX1, GENMASK(31, 28), 4);
	break;
```

### 7.2 Patch 101 -- brightness drives the mux, and the LED core does the blinking

Patch 101 maps the class device's brightness onto the pad mux, per band, and deliberately does **not** install `blink_set` for `0x7906`, so the LED
core blinks in software through `brightness_set`:

```c
void mt7915_led_mux_set(struct led_classdev *led_cdev, bool on)
{
	/* DBDC: band 0 -> pad 14 ([27:24]), band 1 -> pad 15 ([31:28]) */
	u32 shift = mphy->band_idx ? 28 : 24, mask = GENMASK(shift + 3, shift);

	/* mt76_rmw(), not mt76_rmw_field(): FIELD_PREP needs a constant mask */
	mt76_rmw(dev, MT_LED_GPIO_MUX1, mask, on ? 4U << shift : 0);
}
```

Keeping the trigger makes the rest almost free: mt76 already registers the class devices with mac80211's throughput trigger, which already implements
the agreed behaviour (cadence `334 ms` idle to `50 ms` at ~300 KB/s, `on=1/off=0` when idle, `LED_OFF` when the radio stops); only the output path was
wrong. Measured on hardware without flashing, by reloading the module (`wifi down; rmmod mt7915e; insmod <patched>.ko; wifi up`):

| Pad | Band | 400 consecutive samples | Meaning |
|---|---|---|---|
| 15 | 5 GHz, idle | `400/400 = 4` | solid on, 100% |
| 14 | 2.4 GHz, one client | `201` off / `199` on | blinking, ~50% duty |

That sampling also settled the band mapping (band 0 = 2.4 GHz = pad 14, band 1 = 5 GHz = pad 15), so `shift = band_idx ? 28 : 24` needs no inversion;
an isolation test (`MUX1 = 0`, then `255` to one class device) gave `mt76-phy0 -> pad 14`, `mt76-phy1 -> pad 15`, both -> `0x44000000`.

### 7.3 Patch 102 -- the LEDs follow the radio, not an interface event

Patch 100 set the mux **ON** at init, and the only path that cleared it again was mac80211's interface-down path (`ieee80211_stop_tpt_led_trig()` ->
`led_trigger_event(tpt_led, LED_OFF)`). With Wi-Fi disabled -- the stock OpenWrt configuration here, `disabled '1'` with zero interfaces -- no
interface is ever torn down, so nothing cleared the mux and **both LEDs stayed lit from boot with Wi-Fi off**. That is the reported defect: "Wi-Fi is
off by default but the 2.4G/5G LEDs are on, as if they were switched on at boot regardless of Wi-Fi". Patch 102 makes the state follow the radio:
`mt7915_init_led_mux()` now writes **0 (off)** for `0x7906`, `mt7915_start()` turns the LED on when the radio really starts, and `mt7915_stop()` turns
it off without waiting for any interface event.

```c
	/* mt7915_start(), after flush_work(&dev->init_work); */
	if (IS_ENABLED(CONFIG_MT76_LEDS) && mt76_chip(&dev->mt76) == 0x7906) {
		struct led_classdev *led = &mt7915_hw_phy(hw)->mt76->leds.cdev;

		if (led->dev) {
			led_set_brightness(led, LED_FULL);
			mt7915_led_mux_set(led, true);
		}
	}
	/* mt7915_stop(), after clear_bit(MT76_STATE_RUNNING, ...) */
	led_set_brightness(&phy->mt76->leds.cdev, LED_OFF);
	mt7915_led_mux_set(&phy->mt76->leds.cdev, false);
```

Two details are the point of the patch: it calls `led_set_brightness()` as well as writing the mux, so the LED core's cached brightness agrees with
the hardware and a late `stop_tpt_led_trig()` work item can no longer turn the LED off behind the driver's back; and `mt7915_led_mux_set()` is no
longer `static` (prototype above the definition, plus an `extern` declaration in `mt7915/main.c`), so start/stop write the mux **directly** instead of
depending on when the trigger happens to fire.

That second point also removes the `wifi reload` race patches 100+101 still had: reloading left the 2.4 GHz pad **off** in about three runs out of
four (register samples `0x00000000`, `0x00000000`, `0x00000000`, `0x44000000`), because `wifi down` makes mac80211 emit `LED_OFF` and stop the
software blink while the LED core's blink helpers carry an explicit comment that *"consecutive led_set_brightness(LED_OFF)/(LED_FULL) could have been
executed out of order"*. The race was **not** re-measured after patch 102; the driver write is what makes the result independent of trigger timing.

### 7.4 Kernel API notes for Linux 6.18

| Item | Note |
|---|---|
| `led_set_brightness()` | exported, "guaranteed not to sleep"; what patch 102 uses |
| `led_set_brightness_nosleep()` | **no longer in the header** on 6.18 -- it is a static helper inside `drivers/leds/led-core.c`; calling it fails the build with an implicit-declaration error |
| `led_set_brightness_sync()` | exists, but may sleep |
| `<linux/leds.h>` | must be included explicitly (patch 102 adds it to `mt7915/main.c`) for `led_set_brightness()` and `LED_FULL` |
| `-Werror=missing-prototypes` | a non-static helper needs a prototype visible in the same file before its definition, or the build stops |

Sysfs `brightness` is a **cached** value and `brightness_set_blocking` runs in a workqueue, so a sysfs read can lag the register by tens of
milliseconds: when checking a state, read the mux register (`0x70005054`), not `brightness`.

## 8. Agreed semantics, and how each part was verified

| State | LED behaviour | How it is known |
|---|---|---|
| Radio off | LED off | register: `wifi down` -> `MUX1 = 0x00000000` on the flashed image; mac80211 emits `LED_OFF` |
| Radio on, idle | LED solid on | 400/400 samples of pad 15 = `4`, and `delay_on`/`delay_off` empty with `brightness = 255` (the LED core's "never off, keep brightness" branch) |
| Traffic on a band | that band's LED blinks | pad 14: 201 off / 199 on over 400 samples with a client on 2.4 GHz |
| Per-band routing | 2.4 GHz -> pad 14, 5 GHz -> pad 15 | isolation test (`MUX1 = 0`, then one class device at a time) |
| Wi-Fi disabled at boot | LEDs off | patch 102 intent, **confirmed by eye** `[hardware]` on the flashed image (`ledfollowradio`, the img22 line): with a radio disabled at boot its LED stays dark, and it follows the radio after it is enabled |

Confirmed **by eye** on the panel `[hardware]`: the first pad function code test (code 4, both LEDs lit), the flashed image carrying patches 100+101
(three states checked by looking at the board), and the flashed image carrying patch 102 -- the owner checked the whole table above on the board,
2026-10-08: radio down -> both dark, radio up and idle -> solid, traffic -> blink. Before that check, patch 102 had only been verified at image
level (module on flash changed, no `/etc/config/wireless` in the image, `sysupgrade -T` passes). Confirmed **by instrumented measurement**: all mux
register values, the 400-sample duty cycles, the band mapping, and the pad map of section 2 (register readback). These LEDs are ordinary mt76 class
devices, `mt76-phy0` and `mt76-phy1` under `/sys/class/leds`, with `max_brightness = 255` (unlike `gpio-leds`, whose maximum is 1), and the triggers
`[phy0tpt]`/`[phy1tpt]` are registered by mt76 itself, so no device-tree LED node is needed.

## 9. Design decision: fix the driver, not userspace

The first working approach was entirely in userspace: an `init.d` script that set the mux when a radio was enabled, a netdev hotplug handler, and a
daemon polling the interface counters at 100 ms to blink the LED. It worked and it was **rejected**: driving the LED from userspace is not optimal.
The LED belongs to `mt76` -- the class device and the throughput trigger are registered by the driver -- so the mux write belongs in the driver;
script, hotplug handler and daemon were all removed, and current images contain no userspace LED file. Two lessons from that detour: the Wi-Fi netdevs
here are named `phy0-ap0` and `phy1-ap0`, **not** `wlan0`, so a hotplug rule written as `case "$INTERFACE" in wlan*)` never matches and `wifi down`
silently did nothing; and calling `/sbin/hotplug-call net` by hand with a self-set `INTERFACE=wlan0` "passed" both directions and hid the bug. A fake
test can be worse than no test.

## 10. HARDWARE HAZARDS

Read this before touching any GPIO on this board.

| Pin | What it is | Rule |
|---|---|---|
| gpio 16 | laser TX-disable (`LED_PHY_TX_POWER_DISABLE` in the vendor config, mode 1) | **never drive it**; polarity not confirmed |
| gpio 28 | `pcie_reset0` | never drive it |
| gpio 29 | `pcie_reset1` (the vendor table calls it the Internet LED) | never drive it; pulling it low resets PCIe and loses Wi-Fi until reboot |
| gpio 0 | Reset button | a short press reboots; 5 s or more factory-resets |
| gpio 7 | WPS button | a press at boot enters failsafe |

On kernel 6.18, **never write the LED `trigger` sysfs attribute**: a parallel port project on the same kernel hit a NULL dereference inside
`led_trigger_set()` when writing it, and although that was not reproduced here the rule stands -- read `trigger`, write `brightness`. Related: a sysfs
`brightness` write goes through the LED core's sysfs path, which drops the LED's trigger on a `0` write (`led_trigger_remove()`), whereas a driver
calling `led_set_brightness()` does not. `[not verified]` -- the trigger-detach path is kernel behaviour read from the sources, not re-measured on
this board; what *was* measured here is that the throughput trigger has already stopped its software-blink timer when there is no traffic, so a
brightness write does stick while the link is idle.

## 11. Open items

Nothing here blocks using the board; every entry says what would close it.

- **WPS LED: unresolved, deliberately left blocked.** All 28 safe pads were driven low one at a time, plus pad 16 and pad 28, and the WPS button was
  held for 5 s; no pad lights that LED. Either it is not wired to the SoC or it is not populated on this variant. No LED node is declared for it, and
  no further pad sweeping is planned -- closure needs either the pad's second function muxed away (the pad is not yet identified) or an explicit
  decision to close it as "no LED". `[not verified]`
- **`case 0x7916` (MT7986) is untested** `[not verified]`: the mux patch covers chip id `0x7906` only, and `0x7916` keeps function code `3` because no
  MT7986 board was available. Also cosmetic: `mt7915_led_mux_set()` carries a prototype in two files (`init.c`, `main.c`) that would be cleaner in
  `mt7915.h`.
- **The `wifi reload` race was not re-measured after patch 102** `[not verified]`: on the patch-101 image, 2.4 GHz sometimes failed to come back on
  after a `wifi reload`. The owner has not seen the LEDs misbehave on the patch-102 image, but no scripted reload loop was run to prove it is gone.
- **Buttons are polled, not interrupt-driven** `[not verified]`: `gpio-keys-polled` is used because only GPIO 0..15 can raise an interrupt. The
  pinctrl node can raise GIC SPI 26, so an interrupt-driven `gpio-keys` binding is possible -- it has not been tried, and the claim that this would
  work is read from the device tree, not measured.
- **Closed since the previous revision:** the eye check of the patch-102 image (section 8) -- done on the board by the owner, and the LED semantics
  table is now `[hardware]` throughout.
