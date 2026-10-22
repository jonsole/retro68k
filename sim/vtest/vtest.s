; Video test ROM (spec 4): sets up the three layers over picture data that
; vgen.py put in Chip RAM, then keeps the plane pointers reset in every
; vertical blank. After a few frames it prints PASS; the testbench then
; dumps the frame and the video state, and vmodel.py checks every pixel.
;
;   default    palette screen: chunky and planar, scaling, fine scroll,
;              modulo, a vertically flipped layer, transparency, priority,
;              a plane with its DMA off (constant data from BPL4DAT), and
;              pointer wrap (L0's pointer runs past the end of a 64 KB block)
;   -DDIRECT   direct colour: L0 red (5 planes), L1 green (chunky 8 bpp),
;              L2 blue (4 planes, narrower window: blue is 0 outside it;
;              plane 0's DMA off, constant data from BPL0DAT)
;   -DSPRITES  the 8 sprites (spec 9) over two layers: every size, depth and
;              format, magnify, clipping at every edge, collisions
;
; Keep the layouts in step with vgen.py.

            include "hw.inc"

            org ROM
            dc.l    $010000             ; stack
            dc.l    start
            dcb.l   254,hang

start:      move.w  #$2700,sr
            lea     SYSTEM,a5
            lea     CUSTOM,a4
            move.l  #SERCON_EN_M|SERCON_TXDROP_M,SERCON(a5)

            ; palette: a spread of colours
            lea     PALETTE(a4),a0
            move.l  #$123456,d1
            move.w  #256-1,d0
.pal:       move.l  d1,(a0)+
            add.l   #$3A5F17,d1
            and.l   #$FFFFFF,d1
            dbra    d0,.pal
            move.l  #$102030,BGCOLOR(a4)

            lea     setup(pc),a0
            bsr     regs
            bsr     ptrs
            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BPLEN_M|DMACON_SPREN_M,DMACON+2(a4)
            move.l  #VIDCON_VALUE,VIDCON(a4)

            moveq   #0,d7
.frame:     move.l  VIDSTAT(a4),d0
            and.l   #VIDSTAT_VBLANK_M,d0
            beq.s   .frame
            move.l  #VIDSTAT_VBLANK_M,VIDSTAT(a4)
            bsr     ptrs
            addq.l  #1,d7
            cmp.l   #1,d7
            bne.s   .nocl
            move.l  #$FFFFFFFF,SPRCOLL(a4)  ; collisions from the second frame on
.nocl:      cmp.l   #3,d7
            bne.s   .frame
            lea     s_pass(pc),a0
            bsr     puts
            bra.s   .frame

ptrs:       lea     pointers(pc),a0
            ; fall through

; write a list of (offset in the custom block, value) pairs; -1 ends it
regs:       move.l  (a0)+,d0
            bmi.s   .done
            move.l  (a0)+,0(a4,d0.l)
            bra.s   regs
.done:      rts

puts:       move.b  (a0)+,d0
            beq.s   .done
.wait:      move.w  SERSTAT+2(a5),d1
            and.w   #SERSTAT_TXSPACE_M,d1
            beq.s   .wait
            move.b  d0,SERDATA+3(a5)
            bra.s   puts
.done:      rts

hang:       bra.s   hang

s_pass:     dc.b    "PASS",13,10,0
            even

    ifd SPRITES
; ---------------------------------------------------------------- sprites
VIDCON_VALUE equ VIDCON_EN_M

; L0: chunky 4 bpp, 2x by 2x, the whole screen (360 x 288 source), transparent
L0_DATA     equ $100000
; L1: 3 planes, separate, 1x, window 200-520 x 150-450, transparent; rows of 40 bytes
L1_DATA     equ $140000
L1_PLANE    equ 40*300
; sprite images (vgen.py fills $180000-$189000)
S_DATA      equ $180000

; n, x start, x stop, y start, y stop: picture coordinates, made beam coordinates
SPRH        macro
            dc.l    SPR\1+SPR_H, (VID_X0+(\2))|((VID_X0+(\3))<<16)
            dc.l    SPR\1+SPR_V, (VID_Y0+(\4))|((VID_Y0+(\5))<<16)
            endm
; n, bpp code (0 2, 1 4, 2 8), hmag, vmag, depth, pal
SPRC        macro
            dc.l    SPR\1+SPR_CTL, ((\2)<<SPR_CTL_BPP_B)|((\3)<<SPR_CTL_HMAG_B)|((\4)<<SPR_CTL_VMAG_B)|((\5)<<SPR_CTL_DEPTH_B)|((\6)<<SPR_CTL_PAL_B)
            endm

setup:      dc.l    L0+L_CTRL,   L_CTRL_EN_M|(2<<L_CTRL_BPP_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)|L_CTRL_TRANSP_M
            dc.l    L0+L_WINX,   ((VID_X0+0)<<16)|(VID_X0+720)
            dc.l    L0+L_WINY,   ((VID_Y0+0)<<16)|(VID_Y0+576)
            dc.l    L0+L_BPLSTRIDE, 180
            dc.l    L1+L_CTRL,   L_CTRL_EN_M|L_CTRL_PLANAR_M|(2<<L_CTRL_PLANES_B)|L_CTRL_TRANSP_M|(6<<L_CTRL_PALOFS_B)
            dc.l    L1+L_WINX,   ((VID_X0+200)<<16)|(VID_X0+520)
            dc.l    L1+L_WINY,   ((VID_Y0+150)<<16)|(VID_Y0+450)
            dc.l    L1+L_BPLSTRIDE, 40
            dc.l    PRIO,        (2<<4)|(0<<2)|1 ; L1 in front, then L0 (L2 off)
            ; sprites: window, then format
            SPRH    0,-20,12,-10,20             ; off the left edge and the top
            SPRC    0,1,0,0,0,3
            SPRH    1,100,148,50,90             ; 2x by 2x, behind sprite 4
            SPRC    1,2,1,1,1,0
            SPRH    2,690,730,100,140           ; off the right edge
            SPRC    2,0,0,0,2,5
            SPRH    3,300,364,300,340           ; 4x by 4x, at the back
            SPRC    3,1,2,2,3,7
            SPRH    4,90,154,40,100             ; 64 px of 8 bpp
            SPRC    4,2,0,0,0,0
            SPRH    5,400,418,200,230           ; 18 px: the last word part used
            SPRC    5,1,0,0,1,9
            SPRH    6,200,500,400,410           ; 300 px wide
            SPRC    6,0,0,0,0,2
            SPRH    7,500,516,560,590           ; off the bottom
            SPRC    7,1,0,0,0,4
            dc.l    -1

pointers:   dc.l    L0+L_BPL0PT, L0_DATA
            dc.l    L1+L_BPL0PT, L1_DATA+0*L1_PLANE
            dc.l    L1+L_BPL1PT, L1_DATA+1*L1_PLANE
            dc.l    L1+L_BPL2PT, L1_DATA+2*L1_PLANE
            dc.l    SPR0+SPR_PT, S_DATA+$0000
            dc.l    SPR1+SPR_PT, S_DATA+$1000
            dc.l    SPR2+SPR_PT, S_DATA+$2000
            dc.l    SPR3+SPR_PT, S_DATA+$3000
            dc.l    SPR4+SPR_PT, S_DATA+$4000
            dc.l    SPR5+SPR_PT, S_DATA+$6000
            dc.l    SPR6+SPR_PT, S_DATA+$7000
            dc.l    SPR7+SPR_PT, S_DATA+$8000
            dc.l    -1
    else
    ifnd DIRECT
; ---------------------------------------------------------------- palette screen
VIDCON_VALUE equ VIDCON_EN_M

; L0: chunky 4 bpp, 2x by 2x, window 0-640 x 16-464 (320 x 224 source),
; fine scroll 5, rows of 200 bytes
L0_DATA     equ $100000
L0_ROW      equ 200
; L1: 5 planes, separate, 1x, window 100-420 x 50-350, fine scroll 7,
; transparent; plane rows of 48 bytes, 300 rows
L1_DATA     equ $140000
L1_ROW      equ 48
L1_PLANE    equ L1_ROW*300
; L2: chunky 8 bpp, 4x by 8x, window 300-620 x 200-460 (80 x 33 source),
; fine scroll 1, transparent, shown upside down (negative stride); rows of 96 bytes
L2_DATA     equ $1A0000
L2_ROW      equ 96

setup:      dc.l    L0+L_CTRL,   L_CTRL_EN_M|(2<<L_CTRL_BPP_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)|(2<<L_CTRL_PALOFS_B)|(7<<L_CTRL_WRAP_B)
            dc.l    L0+L_WINX,   ((VID_X0+0)<<16)|(VID_X0+640)
            dc.l    L0+L_WINY,   ((VID_Y0+16)<<16)|(VID_Y0+464)
            dc.l    L0+L_SCROLLX, 5
            dc.l    L0+L_BPLSTRIDE, L0_ROW
            dc.l    L1+L_CTRL,   L_CTRL_EN_M|L_CTRL_PLANAR_M|(4<<L_CTRL_PLANES_B)|L_CTRL_TRANSP_M
            dc.l    L1+L_WINX,   ((VID_X0+100)<<16)|(VID_X0+420)
            dc.l    L1+L_WINY,   ((VID_Y0+50)<<16)|(VID_Y0+350)
            dc.l    L1+L_SCROLLX, 7
            dc.l    L1+L_BPLSTRIDE, L1_ROW
            dc.l    L1+L_BPLDMA, 1<<4           ; plane 4: DMA off (SET/CLR clear) ...
            dc.l    L1+L_BPL4DAT, $F0F0         ; ... it shows this word in every group
            dc.l    L2+L_CTRL,   L_CTRL_EN_M|(3<<L_CTRL_BPP_B)|(2<<L_CTRL_HSCALE_B)|(3<<L_CTRL_VSCALE_B)|L_CTRL_TRANSP_M
            dc.l    L2+L_WINX,   ((VID_X0+300)<<16)|(VID_X0+620)
            dc.l    L2+L_WINY,   ((VID_Y0+200)<<16)|(VID_Y0+460)
            dc.l    L2+L_SCROLLX, 1
            dc.l    L2+L_BPLSTRIDE, -L2_ROW    ; back one row
            dc.l    PRIO,        (0<<4)|(2<<2)|1 ; L1 in front, then L2, then L0
            dc.l    -1

pointers:   dc.l    L0+L_BPL0PT, L0_DATA+$C000     ; 48 KB into its 64 KB block: wraps to L0_DATA about row 82
            dc.l    L1+L_BPL0PT, L1_DATA+0*L1_PLANE
            dc.l    L1+L_BPL1PT, L1_DATA+1*L1_PLANE
            dc.l    L1+L_BPL2PT, L1_DATA+2*L1_PLANE
            dc.l    L1+L_BPL3PT, L1_DATA+3*L1_PLANE
            dc.l    L1+L_BPL4PT, L1_DATA+4*L1_PLANE
            dc.l    L2+L_BPL0PT, L2_DATA+32*L2_ROW
            dc.l    -1
    else
; ---------------------------------------------------------------- direct colour
VIDCON_VALUE equ VIDCON_EN_M|VIDCON_DIRECT_M

; all 2x by 2x; L0 and L1 window 64-576 x 40-440 (256 x 200 source)
; L0 red: 5 planes, separate, plane rows of 32 bytes
L0_DATA     equ $100000
L0_PLANE    equ 32*200
; L1 green: chunky 8 bpp, rows of 256 bytes
L1_DATA     equ $140000
; L2 blue: 4 planes, separate, window 64-400 x 40-440 (168 x 200 source),
; plane rows of 22 bytes
L2_DATA     equ $180000
L2_PLANE    equ 22*200

setup:      dc.l    L0+L_CTRL,   L_CTRL_EN_M|L_CTRL_PLANAR_M|(4<<L_CTRL_PLANES_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)
            dc.l    L0+L_WINX,   ((VID_X0+64)<<16)|(VID_X0+576)
            dc.l    L0+L_WINY,   ((VID_Y0+40)<<16)|(VID_Y0+440)
            dc.l    L1+L_CTRL,   L_CTRL_EN_M|(3<<L_CTRL_BPP_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)
            dc.l    L1+L_WINX,   ((VID_X0+64)<<16)|(VID_X0+576)
            dc.l    L1+L_WINY,   ((VID_Y0+40)<<16)|(VID_Y0+440)
            dc.l    L2+L_CTRL,   L_CTRL_EN_M|L_CTRL_PLANAR_M|(3<<L_CTRL_PLANES_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)
            dc.l    L2+L_WINX,   ((VID_X0+64)<<16)|(VID_X0+400)
            dc.l    L2+L_WINY,   ((VID_Y0+40)<<16)|(VID_Y0+440)
            dc.l    L2+L_BPLDMA, 1<<0           ; plane 0: DMA off; the group completes on plane 1
            dc.l    L2+L_BPL0DAT, $AAAA
            dc.l    -1

pointers:   dc.l    L0+L_BPL0PT, L0_DATA+0*L0_PLANE
            dc.l    L0+L_BPL1PT, L0_DATA+1*L0_PLANE
            dc.l    L0+L_BPL2PT, L0_DATA+2*L0_PLANE
            dc.l    L0+L_BPL3PT, L0_DATA+3*L0_PLANE
            dc.l    L0+L_BPL4PT, L0_DATA+4*L0_PLANE
            dc.l    L1+L_BPL0PT, L1_DATA
            dc.l    L2+L_BPL0PT, L2_DATA+0*L2_PLANE
            dc.l    L2+L_BPL1PT, L2_DATA+1*L2_PLANE
            dc.l    L2+L_BPL2PT, L2_DATA+2*L2_PLANE
            dc.l    L2+L_BPL3PT, L2_DATA+3*L2_PLANE
            dc.l    -1
    endif
    endif
