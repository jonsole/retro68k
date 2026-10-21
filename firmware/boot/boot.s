; retro68k boot ROM, phase 2: start-up checks over the USB serial link.
;
;   1. banner and SYSID (a 32-bit register read in two halves)
;   2. vector table built in Chip RAM, then the reset overlay turned off
;   3. Chip RAM test: address pattern, its inverse, and byte writes
;   4. a deliberate bus error, checked against BUSERRADDR and BUSERRWHY
;   5. the software interrupt, through its own vector
;   5b. timer 0 interrupts, against the time counter
;   6. the vertical blank interrupt from the video
;   7. a bitmap layer (layer 1, 8 bpp, 2x) fetched from Chip RAM: no overruns
;   8. four sprites (spec 9): collisions, no missed fetches
;   9. "PASS" or "FAIL", then echo whatever arrives over USB
;
; Everything printed also appears on the screen (text layer 0, 80 x 30).
;
; Assemble: vasmm68k_mot -Fbin -I ../include [-DSIM] -o boot.bin boot.s
; With SIM defined, the RAM test covers only 8 KB, to keep simulation short.

            include "hw.inc"

; While the reset overlay is on, reads of 0-$7FFF come from the ROM, so the
; stack and variables live above that.
VECTORS     equ $000000             ; 256 vectors, 1 KB
VARS        equ $008000             ; boot ROM variables
STACK_TOP   equ $010000             ; stack grows down from here
RAMTEST     equ $010000             ; RAM test starts here

; variables
v_fail      equ VARS+0              ; long: number of failed checks
v_savesp    equ VARS+4              ; long: stack pointer for the bus error test
v_berr      equ VARS+8              ; long: bus errors seen
v_irq       equ VARS+12             ; long: software interrupts seen
v_vbl       equ VARS+16             ; long: vertical blank interrupts seen
v_col       equ VARS+20             ; word: text cursor column
v_row       equ VARS+22             ; word: text cursor row
v_tmr       equ VARS+24             ; long: timer 0 interrupts seen

ATTR        equ $1F                 ; text colours: white (15) on blue (1)
BITMAP      equ $020000             ; the test picture for layer 1
BM_W        equ 64                  ; 64 x 32 pixels at 8 bits per pixel
BM_H        equ 32
BM_X        equ 400                 ; shown 2x at (400, 300)
BM_Y        equ 300
SPRDATA     equ $030000             ; sprite images

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
            bsr     sprite_init

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
            move.l  #1<<INT_SOFT,INTENA(a5)
            move.l  #INTCON_MASTER_M,INTCON(a5)
            move.w  #$2000,sr                   ; CPU takes interrupts of level 1 and up
            move.l  #SOFTINT_SET_M,SOFTINT(a5)
            nop                                 ; the interrupt is taken around here
            nop
            move.w  #$2700,sr
            move.l  #0,INTCON(a5)
            move.l  v_irq,d0
            cmp.l   #1,d0
            bne.s   .irq_bad
            move.l  LASTSRC(a5),d0
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
            move.l  #1<<INT_TIMER0,INTENA(a5)
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
            move.l  #1<<INT_VBLANK,INTENA(a5)
            move.l  #INTCON_MASTER_M,INTCON(a5)
            move.w  #$2000,sr
.wait_vbl:  tst.l   v_vbl
            beq.s   .wait_vbl
            move.w  #$2700,sr
            move.l  #0,INTCON(a5)
            move.l  #0,VIDINTEN(a4)
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

; ---- 8. sprites: collisions from the last complete frame (spec 9, section 7)
            lea     s_spr(pc),a0
            bsr     puts
            move.l  SPRHIT0(a4),d0
            bsr     puthex8
            moveq   #' ',d0
            bsr     putc
            move.l  CLXGRP(a4),d0
            bsr     puthex8
            move.l  SPRHIT0(a4),d0
            cmp.l   #%1101,d0                   ; 0 hit 2, 2 hit 0, 3 hit the text layer
            bne.s   .spr_bad
            move.l  SPRHIT1(a4),d0
            bne.s   .spr_bad
            move.l  CLXGRP(a4),d0
            cmp.l   #(1<<(4*0+1))|(1<<(4*1+0)),d0   ; groups 0 and 1 touched
            bne.s   .spr_bad
            move.l  VIDSTAT(a4),d0
            and.l   #VIDSTAT_SPRMISS_M|VIDSTAT_SPROVF_M,d0
.spr_bad:   bsr     okfail

; ---- 9. result
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
scrputc:    movem.l d1/a0,-(sp)
            cmp.b   #13,d0
            bne.s   .lf
            clr.w   v_col
            bra.s   .done
.lf:        cmp.b   #10,d0
            bne.s   .chr
            addq.w  #1,v_row
            and.w   #31,v_row                   ; wraps round the 32-row buffer
            bra.s   .done
.chr:       move.w  v_row,d1
            lsl.w   #7,d1                       ; 128 cells per row
            add.w   v_col,d1
            add.w   d1,d1                       ; 2 bytes per cell
            lea     TEXT,a0
            move.b  #ATTR,0(a0,d1.w)
            move.b  d0,1(a0,d1.w)
            addq.w  #1,v_col
.done:      movem.l (sp)+,d1/a0
            rts

; palette, clear text, layer 0 = text over the whole screen, video on
screen_init:
            lea     CUSTOM,a4
            lea     PALETTE(a4),a0
            lea     palette(pc),a1
            moveq   #16-1,d0
.pal:       move.l  (a1)+,(a0)+
            dbra    d0,.pal
            lea     TEXT,a0
            move.l  #(ATTR<<24)|($20<<16)|(ATTR<<8)|$20,d1
            move.w  #128*32/2-1,d0
.clr:       move.l  d1,(a0)+
            dbra    d0,.clr
            clr.l   v_col                       ; column and row
            move.l  #$202020,BGCOLOR(a4)
            move.l  #L_CTRL_EN_M|L_CTRL_TYPE_M,L0+L_CTRL(a4)
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

; layer 1: a 64 x 32 8 bpp picture at BITMAP, pixel (x, y) = (4x) xor (8y),
; shown 2x in front of the text; palette 256-511: colour i = (i, 255 - i, $80)
bitmap_init:
            lea     CUSTOM,a4
            lea     PALETTE+256*4(a4),a0
            moveq   #0,d0
.pal:       move.l  d0,d1
            swap    d1                          ; red = i
            move.w  #255,d2
            sub.w   d0,d2
            lsl.w   #8,d2                       ; green = 255 - i
            or.w    #$80,d2                     ; blue = $80
            move.w  d2,d1
            move.l  d1,(a0)+
            addq.w  #1,d0
            cmp.w   #256,d0
            bne.s   .pal
            lea     BITMAP,a0
            moveq   #0,d3                       ; y
.row:       moveq   #0,d4                       ; x
.pix:       move.b  d4,d0
            lsl.b   #2,d0
            move.b  d3,d1
            lsl.b   #3,d1
            eor.b   d1,d0
            move.b  d0,(a0)+
            addq.b  #1,d4
            cmp.b   #BM_W,d4
            bne.s   .pix
            addq.b  #1,d3
            cmp.b   #BM_H,d3
            bne.s   .row
            lea     L0+L_SPAN(a4),a0            ; layer 1
            move.l  #BITMAP,L_PTR(a0)
            move.l  #BM_W,L_STRIDE(a0)
            move.l  #(BM_X<<16)|(BM_X+2*BM_W),L_WINX(a0)
            move.l  #(BM_Y<<16)|(BM_Y+2*BM_H),L_WINY(a0)
            move.l  #$0080,L_HSTEP(a0)          ; 2x
            move.l  #$0080,L_VSTEP(a0)
            move.l  #L_CTRL_EN_M|(3<<L_CTRL_BPP_B)|(16<<L_CTRL_PALOFS_B),L_CTRL(a0)
            move.l  #(3<<6)|(2<<4)|(0<<2)|1,PRIO(a4)    ; layer 1 in front, then 0, 2, 3
            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_VIDEN_M,DMACON+2(a4)
            rts

; Four sprites (spec 9), with their images at SPRDATA:
;   0: 16x16 4 bpp at (480, 48), pixel (x, y) = x xor y; group 0, reacts to group 1
;   1: 32x16 2 bpp, 2x, flipped, at (-24, 100): bands of 8 pixels, x / 8
;   2: 16x16 8 bpp at (488, 56), under sprite 0: 16x + y; group 1, reacts to group 0
;   3: 16x16 4 bpp at (300, 300), behind all layers: hidden, but reacts to layer 0
; Palette 512-527: colour i = (16i, $40, 255 - 16i); 529-531 red, green, yellow
sprite_init:
            lea     CUSTOM,a4
            lea     PALETTE+512*4(a4),a0
            moveq   #0,d0
.pal:       move.l  d0,d1
            lsl.l   #4,d1
            swap    d1                          ; red = 16i
            move.w  #255,d2
            move.l  d0,d3
            lsl.w   #4,d3
            sub.w   d3,d2                       ; blue = 255 - 16i
            or.w    #$4000,d2                   ; green = $40
            move.w  d2,d1
            move.l  d1,(a0)+
            addq.w  #1,d0
            cmp.w   #16,d0
            bne.s   .pal
            move.l  #$FF0000,(a0)+              ; 528 (unused: 0 is transparent)
            move.l  #$FF0000,(a0)+              ; 529 red
            move.l  #$00FF00,(a0)+              ; 530 green
            move.l  #$FFFF00,(a0)+              ; 531 yellow
            ; sprite 0: 8 bytes per line, nibble pixels, x xor y
            lea     SPRDATA,a0
            moveq   #0,d3                       ; y
.s0y:       moveq   #0,d4                       ; x (two pixels a byte)
.s0x:       move.b  d4,d0
            eor.b   d3,d0
            and.b   #15,d0
            lsl.b   #4,d0
            move.b  d4,d1
            addq.b  #1,d1
            eor.b   d3,d1
            and.b   #15,d1
            or.b    d1,d0
            move.b  d0,(a0)+
            addq.b  #2,d4
            cmp.b   #16,d4
            bne.s   .s0x
            addq.b  #1,d3
            cmp.b   #16,d3
            bne.s   .s0y
            ; sprite 1 at SPRDATA+$100: 32 pixels at 2 bpp = 8 bytes: bands 0,1,2,3 of 8 pixels
            lea     SPRDATA+$100,a0
            moveq   #16-1,d3
.s1y:       move.l  #$00005555,(a0)+
            move.l  #$AAAAFFFF,(a0)+
            dbra    d3,.s1y
            ; sprite 2 at SPRDATA+$200: 16 bytes a line, 16x + y
            lea     SPRDATA+$200,a0
            moveq   #0,d3
.s2y:       moveq   #0,d4
.s2x:       move.b  d4,d0
            lsl.b   #4,d0
            add.b   d3,d0
            move.b  d0,(a0)+
            addq.b  #1,d4
            cmp.b   #16,d4
            bne.s   .s2x
            addq.b  #1,d3
            cmp.b   #16,d3
            bne.s   .s2y
            ; sprite 3 at SPRDATA+$400: all colour 5
            lea     SPRDATA+$400,a0
            move.w  #128/4-1,d3
.s3:        move.l  #$55555555,(a0)+
            dbra    d3,.s3
            ; the table
            lea     SPRTAB(a4),a1
            lea     spr_table(pc),a0
            moveq   #4-1,d3
.ent:       moveq   #6-1,d2
.wd:        move.l  (a0)+,(a1)+
            dbra    d2,.wd
            lea     SPR_SIZEOF-6*4(a1),a1
            dbra    d3,.ent
            move.l  #SPRCON_EN_M,SPRCON(a4)
            move.w  #DMACON_SETCLR_M|DMACON_SPREN_M,DMACON+2(a4)
            rts

; POS, PTR, SIZE, CTRL, SCALE, COLL
spr_table:  dc.l    (48<<16)|480,     SPRDATA,      (8<<16)|15,  $00200009, $01000100, $00000020
            dc.l    (100<<16)|$FE8,   SPRDATA+$100, (8<<16)|15,  $00210023, $00800080, $00000003
            dc.l    (56<<16)|488,     SPRDATA+$200, (16<<16)|15, $00100011, $01000100, $00000011
            dc.l    (300<<16)|300,    SPRDATA+$400, (8<<16)|15,  $00200409, $01000100, $00000102

; vertical blank: count it and clear the flag
vblank:     move.l  a4,-(sp)
            lea     CUSTOM,a4
            move.l  #VIDSTAT_VBLANK_M,VIDSTAT(a4)
            addq.l  #1,v_vbl
            move.l  (sp)+,a4
            rte

unhandled:  bra.s   unhandled

; the 16 PC text colours, 0x00RRGGBB
palette:    dc.l    $000000,$0000AA,$00AA00,$00AAAA,$AA0000,$AA00AA,$AA5500,$AAAAAA
            dc.l    $555555,$5555FF,$55FF55,$55FFFF,$FF5555,$FF55FF,$FFFF55,$FFFFFF

s_banner:   dc.b    13,10,"retro68k boot ROM",13,10,0
s_sysid:    dc.b    "SYSID ",0
s_overlay:  dc.b    "overlay off",0
s_ram:      dc.b    "RAM ",0
s_berr:     dc.b    "bus error",0
s_irq:      dc.b    "interrupt",0
s_vbl:      dc.b    "vertical blank",0
s_tmr:      dc.b    "timer",0
s_layer:    dc.b    "bitmap layer",0
s_spr:      dc.b    "sprites ",0
s_nmi:      dc.b    "NMI",13,10,0
s_ok:       dc.b    " ok",13,10,0
s_bad:      dc.b    " FAIL",13,10,0
s_at:       dc.b    "  at ",0
s_read:     dc.b    " read ",0
s_pass:     dc.b    "PASS",13,10,0
s_fail:     dc.b    "FAIL",13,10,0
            even
