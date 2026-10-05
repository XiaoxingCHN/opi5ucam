#!/usr/bin/env python3
"""DTB surgery for Orange Pi 5 Ultra camera stabilization.

Base variant (rk3588-orangepi-5-ultra-vbus.dts):
  - vcc5v0-host / vcc5v0-otg regulators lose their gpio control (become virtual
    always-on rails, so u2phy consumers are unaffected).
  - Two gpio-leds nodes take over the same pins (gpio3_D5 = VBUS of usbdrd3_1
    type-A port / u2phy1 rail; gpio4_B1 = PB1, VBUS of usbdrd3_0 / u2phy0 rail),
    default-state on. VBUS toggle then works via /sys/class/leds/*/brightness.

HS variant (same + maximum-speed = "high-speed" on both usbdp dwc3 nodes) to
bypass the defective SS link entirely (~30 fps cap instead of ~77 fps).
"""
import re
import sys

SRC = '/tmp/opi5u.dts'

src = open(SRC).read()

# --- 1. strip gpio/pinctrl from the two vbus fixed regulators -------------
for name, gpio_pat, pctrl in [('vcc5v0-host', '0x11a 0x1d', '0x1f1'),
                              ('vcc5v0-otg',  '0x11d 0x09', '0x1f2')]:
    m = re.search(r'\t' + name + r' \{.*?\n\t\};', src, re.S)
    assert m, f'node {name} not found'
    block = m.group(0)
    nb = block
    nb = re.sub(r'\t*gpio = <' + re.escape(gpio_pat) + r' 0x00>;\n', '', nb)
    nb = re.sub(r'\t*enable-active-high;\n', '', nb)
    nb = re.sub(r'\t*pinctrl-names = "default";\n', '', nb)
    nb = re.sub(r'\t*pinctrl-0 = <' + re.escape(pctrl) + r'>;\n', '', nb)
    assert nb != block and 'gpio = <' not in nb, f'strip failed for {name}'
    src = src.replace(block, nb, 1)

# --- 2. append gpio-leds vbus-recover node (right after vcc5v0-otg) -------
m = re.search(r'\tvcc5v0-otg \{.*?\n\t\};\n', src, re.S)
assert m, 'vcc5v0-otg block end not found'
leds = '''
	vbus-recover {
		compatible = "gpio-leds";

		vbus-host {
			gpios = <0x11a 0x1d 0x00>;
			default-state = "on";
			label = "vbus-host";
			pinctrl-names = "default";
			pinctrl-0 = <0x1f1>;
		};

		vbus-otg {
			gpios = <0x11d 0x09 0x00>;
			default-state = "on";
			label = "vbus-otg";
			pinctrl-names = "default";
			pinctrl-0 = <0x1f2>;
		};
	};
'''
src = src[:m.end()] + leds + src[m.end():]

open('/tmp/dts-base.dts', 'w').write(src)

# --- 3. HS variant: cap both usbdp dwc3 controllers at high-speed ---------
hs = src
count = 0
def add_maxspeed(mo):
    global count
    count += 1
    return mo.group(0) + '\t\t\tmaximum-speed = "high-speed";\n'

hs = re.sub(r'\t\tusb@fc[04]00000 \{\n\t\t\tcompatible = "snps,dwc3";\n',
            add_maxspeed, hs)
assert count == 2, f'expected 2 dwc3 nodes, patched {count}'
open('/tmp/dts-hs.dts', 'w').write(hs)

print('OK: /tmp/dts-base.dts and /tmp/dts-hs.dts written')
