; Audio test ROM (spec 6). Plays the four channels from sample data that
; agen.py put in Chip RAM, keeps their queues fed, and after a while prints
; PASS. The testbench (+audio) records every output sample; amodel.py
; must work out exactly the same ones. Keep the channel set-ups in step
; with amodel.py.

            include "hw.inc"

S8          equ     $040000             ; 8-bit samples
S16         equ     $041000             ; 16-bit samples
RATE        equ     250                 ; an output sample every 2.5 us
LOOPS       equ     400

            org ROM
            dc.l    $010000             ; stack
            dc.l    start
            dcb.l   254,hang

start:      move.w  #$2700,sr
            lea     SYSTEM,a5
            lea     CUSTOM,a4
            move.l  #SERCON_EN_M|SERCON_TXDROP_M,SERCON(a5)

            move.l  #RATE,AUDRATE(a4)
            lea     setup(pc),a0
.set:       move.l  (a0)+,d0            ; offset, or -1
            bmi.s   .go
            move.l  (a0)+,0(a4,d0.l)
            bra.s   .set
.go:        lea     qpos,a1             ; each channel's next queue entry: the second
            moveq   #3,d0
.qp:        move.l  #1,(a1)+
            dbra    d0,.qp
            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|$F,DMACON+2(a4)    ; all four on

            ; keep the queues fed: when a channel takes its registers,
            ; write its next block (the last one then loops)
            move.l  #LOOPS,d7
.loop:      move.l  AUDSTAT(a4),d1
            and.l   #$F,d1
            beq.s   .next
            moveq   #0,d2               ; channel
.ch:        btst    d2,d1
            beq.s   .chn
            moveq   #1,d0
            lsl.l   d2,d0
            move.l  d0,AUDSTAT(a4)      ; clear its bit
            bsr     feed
.chn:       addq.l  #1,d2
            cmp.l   #4,d2
            bne.s   .ch
.next:      subq.l  #1,d7
            bne.s   .loop

            lea     s_pass(pc),a0
            bsr     puts
.done:      bra.s   .done

; d2 = channel: write its next queued block, if there is one
feed:       movem.l d0-d4/a0-a2,-(sp)
            lea     qpos,a1
            move.l  d2,d3
            lsl.l   #2,d3
            move.l  0(a1,d3.l),d4       ; entry number
            lea     queues(pc),a2
            move.l  0(a2,d3.l),d0       ; this channel's queue (offset from queues)
            lea     queues(pc),a0
            add.l   d0,a0
            cmp.l   (a0)+,d4            ; number of entries
            bhs.s   .none
            lsl.l   #3,d4
            move.l  d2,d0
            lsl.l   #5,d0               ; channel registers at AUD0 + 32n
            lea     AUD0(a4),a2
            add.l   d0,a2
            move.l  0(a0,d4.l),AUD_LC(a2)
            move.l  4(a0,d4.l),AUD_LEN(a2)
            addq.l  #1,0(a1,d3.l)
.none:      movem.l (sp)+,d0-d4/a0-a2
            rts

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

qpos        equ     $008000             ; 4 longs: next queue entry per channel

; offset, value; -1 ends
setup:      dc.l    AUD0+AUD_CTRL, 0                        ; 8-bit, interpolated
            dc.l    AUD0+AUD_LC,   S8+1                     ; odd address
            dc.l    AUD0+AUD_LEN,  300
            dc.l    AUD0+AUD_STEP, $0B400                   ; 0.703
            dc.l    AUD0+AUD_VOL,  (64<<16)|10
            dc.l    AUD1+AUD_CTRL, AUD_CTRL_BITS16_M        ; 16-bit, interpolated
            dc.l    AUD1+AUD_LC,   S16
            dc.l    AUD1+AUD_LEN,  700
            dc.l    AUD1+AUD_STEP, $2C000                   ; 2.75
            dc.l    AUD1+AUD_VOL,  (20<<16)|64
            dc.l    AUD2+AUD_CTRL, AUD_CTRL_NEAREST_M       ; 8-bit, nearest
            dc.l    AUD2+AUD_LC,   S8+$100
            dc.l    AUD2+AUD_LEN,  300
            dc.l    AUD2+AUD_STEP, $10000
            dc.l    AUD2+AUD_VOL,  (64<<16)|64
            dc.l    AUD3+AUD_CTRL, AUD_CTRL_BITS16_M|AUD_CTRL_NEAREST_M
            dc.l    AUD3+AUD_LC,   S16+2
            dc.l    AUD3+AUD_LEN,  1900
            dc.l    AUD3+AUD_STEP, $FE666                   ; 15.9
            dc.l    AUD3+AUD_VOL,  (33<<16)|90              ; 90 acts as 64
            dc.l    -1

; per channel: offset of its queue; a queue: entries, then (LC, LEN) each.
; Entry 0 is the set-up above; the last entry loops. Every block before the
; last lasts over 100 output samples (250 us), so the CPU has written the
; next one long before the channel takes it.
queues:     dc.l    q0-queues, q1-queues, q2-queues, q3-queues
q0:         dc.l    2, S8+1,300, S8+$203,61
q1:         dc.l    3, S16,700, S16+40,600, S16+200,7
q2:         dc.l    1, S8+$100,300
q3:         dc.l    2, S16+2,1900, S16+$800,900
