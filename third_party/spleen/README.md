# Spleen 8×16, code page 437

The boot ROM's console font (spec 4, section 4.7) is Spleen by Frederic Cambus, BSD 2-Clause licence (see `LICENSE`), from https://github.com/fcambus/spleen (commit 5116f8e). There is no text layer: the console code in the boot ROM draws the characters into a 1-plane bitmap.

`tools/bdf2font.py` turns `spleen-8x16-ibm-437.bdf` into `firmware/boot/font8x16.bin` (4096 bytes), which the boot ROM includes.
