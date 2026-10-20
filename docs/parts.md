# Parts list (first draft)

| Part                 | Example                    | Notes                         |
|----------------------|----------------------------|-------------------------------|
| CPU                  | MC68HC000 / MC68SEC000     | CMOS, 3.3 V option on SEC000  |
| Main SRAM            | IS61WV51216 (1 MB, 10 ns)  | 3.3 V, needs level care       |
| Boot ROM             | SST39SF010 ×2              | 5 V flash, 8-bit each         |
| Glue logic           | ATF1508 CPLD               | or put it in the FPGA         |
| FPGA                 | ECP5 LFE5U-25F / GW2A      | open toolchain on ECP5        |
| Video SRAM           | IS61WV25616                | FPGA side                     |
| UART                 | MC68681 DUART or FT232 + FPGA |                            |
| Audio DAC            | PCM5102A                   | I2S                           |
| Oscillators          | 16–20 MHz (CPU), 25.175 MHz (VGA) |                       |

Watch voltage levels: a 5 V 68000 next to a 3.3 V FPGA needs level shifters (74LVC245 / 74LVC8T245) or a 3.3 V CPU like the 68SEC000.
