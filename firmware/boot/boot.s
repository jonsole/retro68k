; retro68k boot ROM - minimal start-up
; Assemble: vasmm68k_mot -Fbin -o boot.bin boot.s

STACK_TOP   equ $00900000       ; top of main SRAM
UART_BASE   equ $00F00000       ; placeholder UART address
UART_DATA   equ UART_BASE+0
UART_STATUS equ UART_BASE+2
TX_READY    equ 0               ; status bit: transmitter empty

            org $000000
            dc.l STACK_TOP      ; initial supervisor stack pointer
            dc.l start          ; initial program counter
            dcb.l 254,unhandled ; remaining exception vectors

start:      move.w  #$2700,sr   ; supervisor mode, interrupts off
            lea     hello(pc),a0
            bsr     puts
.loop:      bra.s   .loop

; print zero-terminated string at a0
puts:       move.b  (a0)+,d0
            beq.s   .done
            bsr     putc
            bra.s   puts
.done:      rts

; send d0 over the UART
putc:       btst    #TX_READY,UART_STATUS
            beq.s   putc
            move.b  d0,UART_DATA
            rts

unhandled:  bra.s   unhandled

hello:      dc.b    "retro68k boot ROM",13,10,0
            even
