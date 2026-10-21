# Spleen 8×16, code page 437

The power-on font of the text layer (spec 4, section 4.7) is Spleen by Frederic Cambus, BSD 2-Clause licence (see `LICENSE`), from https://github.com/fcambus/spleen (commit 5116f8e).

`tools/bdf2font.py` turns `spleen-8x16-ibm-437.bdf` into `fpga/rtl/font8x16.hex`, the font RAM's initial contents.
