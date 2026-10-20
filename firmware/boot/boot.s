; retro68k boot ROM - minimal start-up
; Assemble: vasmm68k_mot -Fbin -I ../include -o boot.bin boot.s

            include "hw.inc"

STACK_TOP   equ $00004000       ; top of the first 16 KB of Chip RAM (temporary RAM in phase 3)

            org ROM             ; $F80000; also seen at 0 while the reset overlay is on
            dc.l STACK_TOP      ; initial supervisor stack pointer
            dc.l start          ; initial program counter
            dcb.l 254,unhandled ; remaining exception vectors

start:      move.w  #$2700,sr                   ; supervisor mode, interrupts off
            lea     SYSTEM,a5
            move.l  #SERCON_EN_M|SERCON_CTLEN_M,SERCON(a5)  ; USB serial on, PC control commands on
            lea     hello(pc),a0
            bsr     puts
.loop:      bra.s   .loop

; print zero-terminated string at a0
puts:       move.b  (a0)+,d0
            beq.s   .done
            bsr     putc
            bra.s   puts
.done:      rts

; send d0 over the USB serial link (spec 14); a5 = SYSTEM
putc:       move.w  SERSTAT+2(a5),d1            ; low half: TXSPACE
            and.w   #SERSTAT_TXSPACE_M,d1
            beq.s   putc                        ; no room yet
            move.b  d0,SERDATA+3(a5)            ; low byte of SERDATA sends one byte
            rts

unhandled:  bra.s   unhandled

hello:      dc.b    "retro68k boot ROM",13,10,0
            even
