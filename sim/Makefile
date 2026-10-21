# retro68k simulation (Icarus Verilog)
#
#   make            build and run the system test
#   make run ARGS=+dma      with the DMA port kept busy
#   make run ARGS=+trace    print the first bus cycles
#
# Needs: iverilog, sv2v (to convert fx68k), vasmm68k_mot, python3.
# Tools can be given explicitly: make SV2V=/path/sv2v VASM=/path/vasmm68k_mot

SV2V  ?= sv2v
VASM  ?= vasmm68k_mot
IVERILOG ?= iverilog
VVP   ?= vvp

ROOT  := ..
RTL   := $(ROOT)/fpga/rtl
FX68K := $(ROOT)/fpga/third_party/fx68k
BUILD := build

RTL_SRC := $(RTL)/timebase.v $(RTL)/cpu_fx68k.v $(RTL)/sram_ctl.v $(RTL)/bus_if.v \
           $(RTL)/bootrom.v $(RTL)/fifo8.v $(RTL)/sysregs.v $(RTL)/serial.v $(RTL)/intc.v $(RTL)/timers.v $(RTL)/layer_pix.v $(RTL)/vfetch.v $(RTL)/sprite_pix.v $(RTL)/sprites.v $(RTL)/video.v $(RTL)/retro68k.v
SIM_SRC := $(RTL)/platform/sim/oddr.v $(RTL)/platform/sim/pixclk.v sram_model.v ft232h_model.v tb.v

.PHONY: all run frame clean
all: run

$(BUILD):
	mkdir -p $(BUILD)

# fx68k is SystemVerilog; Icarus needs it as Verilog
$(BUILD)/fx68k.v: $(FX68K)/fx68k.sv $(FX68K)/fx68kAlu.sv $(FX68K)/uaddrPla.sv | $(BUILD)
	$(SV2V) $^ > $@

$(BUILD)/microrom.mem $(BUILD)/nanorom.mem: | $(BUILD)
	cp $(FX68K)/microrom.mem $(FX68K)/nanorom.mem $(BUILD)/

$(BUILD)/boot.bin: $(ROOT)/firmware/boot/boot.s $(ROOT)/firmware/include/hw.inc | $(BUILD)
	$(VASM) -quiet -Fbin -DSIM -I $(ROOT)/firmware/include -o $@ $<

$(BUILD)/boot.hex: $(BUILD)/boot.bin
	python3 $(ROOT)/tools/bin2hex.py $< $@

$(BUILD)/tb.vvp: $(BUILD)/fx68k.v $(RTL_SRC) $(SIM_SRC) $(RTL)/regmap.vh
	$(IVERILOG) -g2005 -Wall -Wno-timescale -Wno-implicit-dimensions -I $(RTL) -s tb -o $@ \
	    $(BUILD)/fx68k.v $(RTL_SRC) $(SIM_SRC)

$(BUILD)/font8x16.hex: $(RTL)/font8x16.hex | $(BUILD)
	cp $< $@

run: $(BUILD)/tb.vvp $(BUILD)/boot.hex $(BUILD)/microrom.mem $(BUILD)/font8x16.hex
	cd $(BUILD) && $(VVP) -n tb.vvp $(ARGS) | tee sim.log
	@grep -q "^TEST PASSED" $(BUILD)/sim.log

# The screen as a PNG (needs Pillow): runs the test with +frame
frame: $(BUILD)/tb.vvp $(BUILD)/boot.hex $(BUILD)/microrom.mem $(BUILD)/font8x16.hex
	cd $(BUILD) && $(VVP) -n tb.vvp +frame $(ARGS) | tee sim.log
	python3 -c "from PIL import Image; Image.open('$(BUILD)/frame.ppm').save('$(BUILD)/frame.png')"
	@echo "wrote $(BUILD)/frame.png"

clean:
	rm -rf $(BUILD)
