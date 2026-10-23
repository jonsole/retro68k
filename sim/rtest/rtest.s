; RESET instruction test (spec 7, section 2.4). Sets up the custom
; hardware, the interrupt controller, a timer, the SD card and keyboard
; controllers and the watchdog, turns the overlay off and leaves markers in
; memory and the CPU's registers; then executes RESET and checks that the
; devices are back to their reset values while the CPU, the overlay, memory,
; the watchdog, RESETWHY and the time counter are not. Prints PASS, or FAIL
; and the number of the first check that went wrong.

            include "hw.inc"

            org ROM
            dc.l    $010000             ; stack
            dc.l    start
            dcb.l   254,hang

; check: (source & mask) = expected, else FAIL with the number
EXPECT         macro
            moveq   #\4,d0
            move.l  \1,d1
            and.l   #\2,d1
            cmp.l   #\3,d1
            bne     failed
            endm

start:      move.w  #$2700,sr
            lea     SYSTEM,a5
            lea     CUSTOM,a4
            move.l  #SERCON_EN_M|SERCON_TXDROP_M,SERCON(a5)
            move.l  RESETWHY(a5),d7

            ; overlay off, and a marker at address 0 (Chip RAM now)
            move.l  #0,SYSCON(a5)
            move.l  #$11223344,$0.w

            ; the devices: something to reset in each
            move.l  #VIDCON_EN_M,VIDCON(a4)
            move.l  #COPCON_EN_M,COPCON(a4)
            move.l  #1000,TMR0_RELOAD(a5)
            move.l  #TMR_CTRL_EN_M|TMR_CTRL_REPEAT_M,TMR0_CTRL(a5)
            move.l  #INTENA_SETCLRL_M|1,INTENA(a5)
            move.l  #SDCON_EN_M,SDCON(a5)
            move.l  #KBCON_EN_M,KBCON(a5)
            ; ... and the watchdog, which RESET must leave running
            move.l  #60000,WDTIME(a5)
            move.l  #WDCTRL_EN_M,WDCTRL(a5)

            ; they took
            EXPECT     VIDCON(a4),1,1,1
            EXPECT     COPCON(a4),1,1,2
            EXPECT     TMR0_CTRL(a5),3,3,3
            EXPECT     INTENA(a5),1,1,4
            EXPECT     SDCON(a5),1,1,5
            EXPECT     KBCON(a5),1,1,6
            EXPECT     WDCTRL(a5),3,1,7

            move.l  TIMEHI(a5),d2       ; the time before (TIMEHI captures both halves)
            move.l  TIMELO(a5),d3
            move.l  #$CAFEBABE,d6
            move.l  a7,d5

            reset

            ; the devices are reset
            EXPECT     VIDCON(a4),$FFFFFFFF,0,16
            EXPECT     COPCON(a4),1,0,17
            EXPECT     TMR0_CTRL(a5),$FF,0,18
            EXPECT     INTENA(a5),$FFFFFF,0,19
            EXPECT     SDCON(a5),1,0,20
            EXPECT     KBCON(a5),1,0,21
            ; the rest is not
            EXPECT     WDCTRL(a5),3,1,24
            EXPECT     WDTIME(a5),$FFFF,60000,25
            EXPECT     SYSCON(a5),SYSCON_OVERLAY_M,0,26
            EXPECT     $0.w,$FFFFFFFF,$11223344,27
            moveq   #28,d0
            cmp.l   RESETWHY(a5),d7
            bne     failed
            moveq   #29,d0
            cmp.l   #$CAFEBABE,d6
            bne     failed
            cmp.l   a7,d5
            bne     failed
            ; the time counter went on
            moveq   #30,d0
            move.l  TIMEHI(a5),d1
            move.l  TIMELO(a5),d4
            cmp.l   d2,d1
            bne.s   .later
            cmp.l   d3,d4
            bls     failed
.later:
            move.l  #0,WDCTRL(a5)       ; watchdog off
            lea     s_pass(pc),a0
            bsr     puts
hang:       bra.s   hang

failed:       move.l  d0,d6
            lea     s_fail(pc),a0
            bsr     puts
            move.b  d6,d2
            lsr.b   #4,d2
            bsr     hexd
            move.b  d6,d2
            bsr     hexd
            lea     s_nl(pc),a0
            bsr     puts
            bra.s   hang

hexd:       and.w   #15,d2
            move.b  hexs(pc,d2.w),d4
            bra.s   putc

puts:       move.b  (a0)+,d4
            beq.s   .done
            bsr.s   putc
            bra.s   puts
.done:      rts

putc:       move.w  SERSTAT+2(a5),d1
            and.w   #SERSTAT_TXSPACE_M,d1
            beq.s   putc
            move.b  d4,SERDATA+3(a5)
            rts

hexs:       dc.b    "0123456789ABCDEF"
s_pass:     dc.b    "PASS",13,10,0
s_fail:     dc.b    "FAIL ",0
s_nl:       dc.b    13,10,0
            even
