; retro68k boot ROM, phase 2: start-up checks over the USB serial link.
;
;   1. banner and SYSID (a 32-bit register read in two halves)
;   2. vector table built in Chip RAM, then the reset overlay turned off
;   3. Chip RAM test: address pattern, its inverse, and byte writes
;   4. a deliberate bus error, checked against BUSERRADDR and BUSERRWHY
;   5. the software interrupt, through its own vector
;   5b. timer 0 interrupts, against the time counter
;   6. the vertical blank interrupt from the video
;   7. a bitmap layer (layer 1, 4 planes, 2x) fetched from Chip RAM: no overruns
;   8. "PASS" or "FAIL", then echo whatever arrives over USB
;
; Everything printed also appears on the screen: an 80 x 30 console drawn
; with the ROM font into a 1-plane 640 x 480 bitmap (layer 0), shown as a
; centred window in the 720 x 576 (576p) screen, with the background
; colour as a border.
; From step 6 on, the vertical blank interrupt stays on: it resets the
; layers' plane pointers for each frame (spec 4, 4.4; the copper's job later).
;
; Assemble: vasmm68k_mot -Fbin -I ../include [-DSIM] -o boot.bin boot.s
; With SIM defined, the RAM test covers only 8 KB, to keep simulation short.

            include "hw.inc"

; While the reset overlay is on, reads of 0-$7FFF come from the ROM, so the
; stack and variables live above that.
VECTORS     equ $000000             ; 256 vectors, 1 KB
VARS        equ $008000             ; boot ROM variables
STACK_TOP   equ $010000             ; stack grows down from here
RAMTEST     equ $040000             ; RAM test starts here (above the console and picture)

; variables
v_fail      equ VARS+0              ; long: number of failed checks
v_savesp    equ VARS+4              ; long: stack pointer for the bus error test
v_berr      equ VARS+8              ; long: bus errors seen
v_irq       equ VARS+12             ; long: software interrupts seen
v_vbl       equ VARS+16             ; long: vertical blank interrupts seen
v_col       equ VARS+20             ; word: text cursor column
v_row       equ VARS+22             ; word: text cursor row
v_tmr       equ VARS+24             ; long: timer 0 interrupts seen

CON         equ $030000             ; the console: 640 x 480, 1 bit per pixel
CON_LINE    equ 640/8               ; bytes per line
CON_X       equ (720-640)/2         ; where the console sits on the screen
CON_Y       equ (576-480)/2
CON_COLS    equ 80
CON_ROWS    equ 30                  ; of 16 lines
BITMAP      equ $020000             ; the test picture for layer 1
BM_W        equ 64                  ; 64 x 32 pixels, 4 interleaved planes:
BM_H        equ 32                  ; each line is plane 0 (8 bytes), plane 1, plane 2, plane 3
BM_PL       equ 4
BM_LINE     equ BM_W/8              ; bytes per plane line
BM_X        equ 400                 ; shown 2x at (400, 300)
BM_Y        equ 300

            org ROM                 ; $F80000; also seen at 0 while the reset overlay is on
            dc.l STACK_TOP          ; initial supervisor stack pointer
            dc.l start              ; initial program counter
            dcb.l 254,unhandled     ; remaining exception vectors

start:      move.w  #$2700,sr                   ; supervisor mode, interrupts off
            lea     SYSTEM,a5
            move.l  #SERCON_EN_M|SERCON_CTLEN_M|SERCON_TXDROP_M,SERCON(a5)  ; USB serial on, PC commands on, never block (no module fitted)
            clr.l   v_fail                      ; (overlay on: writes still reach Chip RAM)
            bsr     screen_init
            bsr     bitmap_init

            lea     s_banner(pc),a0
            bsr     puts

; ---- 1. SYSID
            lea     s_sysid(pc),a0
            bsr     puts
            move.l  SYSID(a5),d0
            bsr     puthex8
            cmp.l   #$5236384B,d0
            bsr     okfail

; ---- 2. vector table in RAM, overlay off
            lea     VECTORS,a0
            move.l  #STACK_TOP,(a0)+
            move.l  #start,(a0)+
            move.w  #254-1,d0
.vec:       move.l  #unhandled,(a0)+
            dbra    d0,.vec
            move.l  #buserr,VECTORS+2*4
            move.l  #nmi,VECTORS+31*4

            lea     s_overlay(pc),a0
            bsr     puts
            move.l  #0,SYSCON(a5)                  ; overlay off
            move.l  VECTORS+4,d0                ; now read from Chip RAM, not ROM
            cmp.l   #start,d0
            bne.s   .ovl_bad
            move.l  VECTORS+8,d0
            cmp.l   #buserr,d0
.ovl_bad:   bsr     okfail

; ---- 3. RAM test
            lea     s_ram(pc),a0
            bsr     puts
            move.l  #RAMTEST,d0
            bsr     puthex8
            moveq   #'-',d0
            bsr     putc
            bsr     ramtop
            move.l  d0,d7                       ; d7 = end of the test area
            bsr     puthex8
            moveq   #' ',d0
            bsr     putc

            ; a) each long holds its own address
            lea     RAMTEST,a0
.wa:        move.l  a0,(a0)+
            cmp.l   d7,a0
            blo.s   .wa
            lea     RAMTEST,a0
.ra:        move.l  (a0),d0
            cmp.l   a0,d0
            bne     .ramfail
            addq.l  #4,a0
            cmp.l   d7,a0
            blo.s   .ra

            ; b) the inverse
            lea     RAMTEST,a0
.wb:        move.l  a0,d0
            not.l   d0
            move.l  d0,(a0)+
            cmp.l   d7,a0
            blo.s   .wb
            lea     RAMTEST,a0
.rb:        move.l  a0,d1
            not.l   d1
            move.l  (a0),d0
            cmp.l   d1,d0
            bne     .ramfail
            addq.l  #4,a0
            cmp.l   d7,a0
            blo.s   .rb

            ; c) byte writes: 256 bytes counting up, read back as words
            lea     RAMTEST,a0
            moveq   #0,d2
.wc:        move.b  d2,(a0)+
            addq.b  #1,d2
            bne.s   .wc
            lea     RAMTEST,a0
            move.w  #$0001,d1
            moveq   #128-1,d3
.rc:        move.w  (a0),d0
            cmp.w   d1,d0
            bne.s   .ramfail
            addq.l  #2,a0
            add.w   #$0202,d1
            dbra    d3,.rc

            moveq   #0,d0                       ; Z set: ok
            bsr     okfail
            bra.s   .ramdone

.ramfail:   move.l  a0,-(sp)
            move.l  d0,-(sp)
            moveq   #1,d0                       ; Z clear: fail
            bsr     okfail
            lea     s_at(pc),a0
            bsr     puts
            move.l  4(sp),d0
            bsr     puthex8
            lea     s_read(pc),a0
            bsr     puts
            move.l  (sp),d0
            bsr     puthex8
            bsr     newline
            addq.l  #8,sp
.ramdone:

; ---- 4. bus error
            lea     s_berr(pc),a0
            bsr     puts
            clr.l   v_berr
            move.l  sp,v_savesp
            tst.w   $400000                     ; reserved: bus error
berr_back:  move.l  v_berr,d0                   ; the handler comes back here
            cmp.l   #1,d0
            bne.s   .berr_bad
            move.l  BUSERRADDR(a5),d0
            cmp.l   #$400000,d0
            bne.s   .berr_bad
            move.l  BUSERRWHY(a5),d0
            cmp.l   #BUSERRWHY_UNMAPPED_M,d0
.berr_bad:  bsr     okfail

; ---- 5. interrupts: the software interrupt (source 18, level 1, vector 82)
            lea     s_irq(pc),a0
            bsr     puts
            clr.l   v_irq
            move.l  #softirq,VECTORS+(VECBASE_DEFAULT+INT_SOFT)*4
            move.w  #(INTENA_SETCLRH_M|(1<<INTB_SOFT))>>16,INTENA(a5)   ; high half: sources 15-23
            move.l  #INTCON_MASTER_M,INTCON(a5)
            move.w  #$2000,sr                   ; CPU takes interrupts of level 1 and up
            move.l  #SOFTINT_SET_M,SOFTINT(a5)
            nop                                 ; the interrupt is taken around here
            nop
            move.w  #$2700,sr
            move.l  #0,INTCON(a5)
            move.w  #(1<<INTB_SOFT)>>16,INTENA(a5)       ; (SET/CLR bit clear: clear)
            move.l  v_irq,d0
            cmp.l   #1,d0
            bne.s   .irq_bad
            move.l  INTID(a5),d0
            cmp.l   #INT_SOFT,d0
.irq_bad:   bsr     okfail

; ---- 5b. timers: timer 0 at 1 MHz, every 10 us, three interrupts (level 6)
            lea     s_tmr(pc),a0
            bsr     puts
            clr.l   v_tmr
            move.l  #timer0,VECTORS+(VECBASE_DEFAULT+INT_TIMER0)*4
            move.l  #99,TMR0+TMR_PRESCALE(a5)      ; 100 MHz / 100 = 1 MHz
            move.l  #9,TMR0+TMR_RELOAD(a5)         ; every 10 ticks
            move.l  #9,TMR0+TMR_COUNT(a5)
            move.w  #INTENA_SETCLRL_M|(1<<INTB_TIMER0),INTENA+2(a5)    ; low half: sources 0-14
            move.l  #INTCON_MASTER_M,INTCON(a5)
            move.l  TIMEHI(a5),d0                  ; the time now, in 10 ns ticks
            move.l  TIMELO(a5),d6
            move.w  #$2000,sr
            move.l  #TMR_CTRL_EN_M|TMR_CTRL_REPEAT_M|TMR_CTRL_IRQ_M,TMR0+TMR_CTRL(a5)
.wait_tmr:  cmp.l   #3,v_tmr
            blo.s   .wait_tmr
            move.l  TIMEHI(a5),d0
            move.l  TIMELO(a5),d5
            move.w  #$2700,sr
            move.l  #0,TMR0+TMR_CTRL(a5)        ; (CLR.L would write the low half first)
            move.l  #0,INTCON(a5)
            move.w  #1<<INT_TIMER0,INTENA+2(a5)
            sub.l   d6,d5                       ; 3 x 10 us plus the 68000's own time: 30-50 us
            moveq   #' ',d0
            bsr     putc
            move.l  d5,d0
            bsr     puthex8
            cmp.l   #2900,d5
            blo.s   .tmr_bad
            cmp.l   #5000,d5
            bhs.s   .tmr_bad
            moveq   #0,d0                       ; Z set: ok
            bra.s   .tmr_ok
.tmr_bad:   moveq   #1,d0
.tmr_ok:    bsr     okfail

; ---- 6. video: wait for the vertical blank interrupt (source 0, level 5)
            lea     s_vbl(pc),a0
            bsr     puts
            clr.l   v_vbl
            lea     CUSTOM,a4
            move.l  #vblank,VECTORS+(VECBASE_DEFAULT+INT_VBLANK)*4
            move.l  #VIDSTAT_VBLANK_M,VIDSTAT(a4)       ; clear any old flag
            move.l  #VIDSTAT_VBLANK_M,VIDINTEN(a4)
            move.w  #INTENA_SETCLRL_M|(1<<INTB_VBLANK),INTENA+2(a5)
            move.l  #INTCON_MASTER_M,INTCON(a5)
            move.w  #$2000,sr
.wait_vbl:  tst.l   v_vbl
            beq.s   .wait_vbl
            move.l  FRAMECOUNT(a4),d0           ; frames have been counted
            tst.l   d0
            seq     d1
            tst.b   d1                          ; Z set if FRAMECOUNT != 0
            bsr     okfail

; ---- 7. the bitmap layer has been on screen for a frame or more: no overruns
            lea     s_layer(pc),a0
            bsr     puts
            move.l  VIDSTAT(a4),d0
            and.l   #VIDSTAT_OVERRUN_M,d0
            bsr     okfail

; ---- 8. result
            tst.l   v_fail
            bne.s   .fail
            lea     s_pass(pc),a0
            bsr     puts
            bra.s   echoloop
.fail:      lea     s_fail(pc),a0
            bsr     puts

; echo everything that arrives over USB
echoloop:   move.l  SERDATA(a5),d0
            btst    #SERDATA_EMPTY_B,d0
            bne.s   echoloop
            bsr     putc
            bra.s   echoloop

; ---------------------------------------------------------------- routines

; d0 = end of Chip RAM to test
ramtop:
    ifd SIM
            move.l  #RAMTEST+$2000,d0
    else
            move.l  SYSCFG(a5),d0
            and.l   #SYSCFG_CHIPMB_M,d0
            moveq   #SYSCFG_CHIPMB_B,d1
            lsr.l   d1,d0
            swap    d0
            lsl.l   #4,d0                       ; MB -> bytes
    endif
            rts

; print " ok" if Z is set, else " FAIL" and count it
okfail:     beq.s   .ok
            addq.l  #1,v_fail
            lea     s_bad(pc),a0
            bra.s   .p
.ok:        lea     s_ok(pc),a0
.p:         bsr     puts
            rts

; print zero-terminated string at a0
puts:       move.b  (a0)+,d0
            beq.s   .done
            bsr     putc
            bra.s   puts
.done:      rts

newline:    moveq   #13,d0
            bsr     putc
            moveq   #10,d0
            ; fall through

; send d0.b over the USB serial link (spec 14) and to the screen; a5 = SYSTEM
putc:       move.w  SERSTAT+2(a5),d1            ; low half: TXSPACE
            and.w   #SERSTAT_TXSPACE_M,d1
            beq.s   putc                        ; no room yet
            move.b  d0,SERDATA+3(a5)            ; low byte of SERDATA sends one byte
            ; fall through

; put d0.b on the screen at the cursor: CR, LF, or a character
scrputc:    movem.l d0-d1/a0-a1,-(sp)
            cmp.b   #13,d0
            bne.s   .lf
            clr.w   v_col
            bra.s   .done
.lf:        cmp.b   #10,d0
            bne.s   .chr
            move.w  v_row,d1
            addq.w  #1,d1
            cmp.w   #CON_ROWS,d1
            blo.s   .row
            moveq   #0,d1                       ; back to the top
.row:       move.w  d1,v_row
            bsr     rowaddr
            move.w  #16*CON_LINE/4-1,d1         ; clear the new row
.clr:       move.l  #0,(a0)+
            dbra    d1,.clr
            bra.s   .done
.chr:       move.w  v_col,d1
            cmp.w   #CON_COLS,d1
            bhs.s   .done                       ; past the right edge: dropped
            move.w  v_row,d1
            bsr     rowaddr
            add.w   v_col,a0
            lea     font(pc),a1
            and.w   #$FF,d0
            lsl.w   #4,d0                       ; 16 bytes per character
            add.w   d0,a1
            moveq   #16-1,d1
.glyph:     move.b  (a1)+,(a0)
            add.w   #CON_LINE,a0
            dbra    d1,.glyph
            addq.w  #1,v_col
.done:      movem.l (sp)+,d0-d1/a0-a1
            rts

; a0 = the console address of text row d1.w
rowaddr:    lea     CON,a0
            mulu    #16*CON_LINE,d1
            add.l   d1,a0
            rts

; palette, clear the console, layer 0 = the console over the whole screen, video on
screen_init:
            lea     CUSTOM,a4
            move.l  #$0000AA,PALETTE+0*4(a4)    ; console: blue
            move.l  #$FFFFFF,PALETTE+1*4(a4)    ; and white
            lea     CON+CON_ROWS*16*CON_LINE,a0
            moveq   #0,d1
            moveq   #0,d2
            moveq   #0,d3
            moveq   #0,d4
            moveq   #0,d5
            moveq   #0,d6
            moveq   #0,d7
            move.l  d1,a1
            move.w  #CON_ROWS*16*CON_LINE/32-1,d0
.clr:       movem.l d1-d7/a1,-(a0)              ; 32 bytes at a time
            dbra    d0,.clr
            clr.l   v_col                       ; column and row
            move.l  #$202020,BGCOLOR(a4)
            lea     L0(a4),a0
            move.l  #CON,L_BPL0PT(a0)
            move.l  #0,L_BPLMOD(a0)
            move.l  #(CON_X<<16)|(CON_X+640),L_WINX(a0)
            move.l  #(CON_Y<<16)|(CON_Y+480),L_WINY(a0)
            move.l  #L_CTRL_EN_M,L_CTRL(a0)     ; chunky, 1 bit per pixel, colours 0-1
            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BPLEN_M,DMACON+2(a4)
            move.l  #VIDCON_EN_M,VIDCON(a4)
            rts

; print d0.l as 8 hex digits (d0 kept)
puthex8:    movem.l d0-d2,-(sp)
            move.l  d0,d2
            moveq   #8-1,d1
.dig:       rol.l   #4,d2
            move.b  d2,d0
            and.b   #$0F,d0
            add.b   #'0',d0
            cmp.b   #'9',d0
            bls.s   .out
            addq.b  #'A'-'9'-1,d0
.out:       move.l  d1,-(sp)
            bsr     putc
            move.l  (sp)+,d1
            dbra    d1,.dig
            movem.l (sp)+,d0-d2
            rts

; bus error handler for the test: count it, then carry on after the access
; (a 68000 bus error can't simply return, so restore the stack and jump back)
buserr:     addq.l  #1,v_berr
            move.l  v_savesp,sp
            jmp     berr_back

; NMI (button or USB BREAK): say so and carry on
nmi:        movem.l d0-d1/a0/a5,-(sp)
            lea     SYSTEM,a5
            move.l  #NMISTAT_BUTTON_M|NMISTAT_USB_M,NMISTAT(a5)
            lea     s_nmi(pc),a0
            bsr     puts
            movem.l (sp)+,d0-d1/a0/a5
            rte

; timer 0: clear its flag and count it
timer0:     move.l  #TMR_STAT_UNDER_M,TMR0+TMR_STAT(a5)
            addq.l  #1,v_tmr
            rte

; software interrupt handler: clear it and count it
softirq:    move.l  #SOFTINT_CLR_M,SOFTINT(a5)
            addq.l  #1,v_irq
            rte

; layer 1: a 64 x 32 picture at BITMAP in 4 interleaved planes, pixel
; (x, y) = (x xor y) and 15, shown 2x in front of the text; colours 16-31
; (PALOFS 1): colour 16 + i = (16i, 255 - 16i, $80)
bitmap_init:
            lea     CUSTOM,a4
            lea     PALETTE+16*4(a4),a0
            moveq   #0,d0
.pal:       move.w  d0,d2
            lsl.w   #4,d2                       ; 16i
            moveq   #0,d1
            move.w  d2,d1
            swap    d1                          ; red = 16i
            neg.w   d2
            add.w   #255,d2
            lsl.w   #8,d2                       ; green = 255 - 16i
            or.w    #$80,d2                     ; blue = $80
            move.w  d2,d1
            move.l  d1,(a0)+
            addq.w  #1,d0
            cmp.w   #16,d0
            bne.s   .pal
            ; bit p of pixel x in a 16-pixel word: $5555, $3333, $0F0F, $00FF;
            ; inverted on lines where bit p of y is set
            lea     BITMAP,a0
            moveq   #0,d3                       ; y
.row:       lea     planebits(pc),a1
            moveq   #0,d4                       ; plane
.plane:     move.w  (a1)+,d0
            btst    d4,d3
            beq.s   .noinv
            not.w   d0
.noinv:     moveq   #BM_W/16-1,d1
.word:      move.w  d0,(a0)+
            dbra    d1,.word
            addq.w  #1,d4
            cmp.w   #BM_PL,d4
            bne.s   .plane
            addq.w  #1,d3
            cmp.w   #BM_H,d3
            bne.s   .row
            lea     L1(a4),a0
            bsr     bm_ptrs
            move.l  #(BM_PL-1)*BM_LINE,L_BPLMOD(a0)
            move.l  #(BM_X<<16)|(BM_X+2*BM_W),L_WINX(a0)
            move.l  #(BM_Y<<16)|(BM_Y+2*BM_H),L_WINY(a0)
            move.l  #L_CTRL_EN_M|L_CTRL_PLANAR_M|((BM_PL-1)<<L_CTRL_PLANES_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)|(1<<L_CTRL_PALOFS_B),L_CTRL(a0)
            move.l  #(2<<4)|(0<<2)|1,PRIO(a4)   ; layer 1 in front, then 0, then 2
            rts

; layer 1's plane pointers for the top of the picture (a0 = layer 1)
bm_ptrs:    move.l  #BITMAP+0*BM_LINE,L_BPL0PT(a0)
            move.l  #BITMAP+1*BM_LINE,L_BPL1PT(a0)
            move.l  #BITMAP+2*BM_LINE,L_BPL2PT(a0)
            move.l  #BITMAP+3*BM_LINE,L_BPL3PT(a0)
            rts

planebits:  dc.w    $5555,$3333,$0F0F,$00FF

; vertical blank: count it, clear the flag, reset layer 1's plane pointers
vblank:     move.l  a0,-(sp)
            lea     CUSTOM,a0
            move.l  #VIDSTAT_VBLANK_M,VIDSTAT(a0)
            move.l  #CON,L0+L_BPL0PT(a0)
            lea     L1(a0),a0
            bsr     bm_ptrs
            addq.l  #1,v_vbl
            move.l  (sp)+,a0
            rte

unhandled:  bra.s   unhandled

; the console font: Spleen 8x16, code page 437 (third_party/spleen, BSD licence)
font:       incbin  "font8x16.bin"

s_banner:   dc.b    13,10,"retro68k boot ROM",13,10,0
s_sysid:    dc.b    "SYSID ",0
s_overlay:  dc.b    "overlay off",0
s_ram:      dc.b    "RAM ",0
s_berr:     dc.b    "bus error",0
s_irq:      dc.b    "interrupt",0
s_vbl:      dc.b    "vertical blank",0
s_tmr:      dc.b    "timer",0
s_layer:    dc.b    "bitmap layer",0
s_nmi:      dc.b    "NMI",13,10,0
s_ok:       dc.b    " ok",13,10,0
s_bad:      dc.b    " FAIL",13,10,0
s_at:       dc.b    "  at ",0
s_read:     dc.b    " read ",0
s_pass:     dc.b    "PASS",13,10,0
s_fail:     dc.b    "FAIL",13,10,0
            even
