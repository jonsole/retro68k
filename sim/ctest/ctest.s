; Copper test ROM (spec 10). Copies a copper list into Chip RAM, starts the
; copper and lets it run a few frames, then checks what the copper did and
; prints PASS or FAIL with the first wrong value.
;
; List 1 (every frame):
;   - in the vertical blank: MOVEs to its own storage registers, the ALU
;     (every function, carry and borrow), SKIPC (every condition), a counted
;     loop, CALL/RET two deep, MOVR through X with X+, a COPINT
;   - in the picture: colour 0 changes at beam positions, for ccheck.py to
;     check in the frame: (100,200) red, (100,500) green, lines 200-209 a
;     new colour at pixel 360 on each line, (300,0) blue (picture
;     coordinates: line, pixel; the WAITs add VID_Y0 and VID_X0)
;   - then it saves X, Y and the flags, and goes on with list 2
; List 2 (background, COPCON.RESUME): a long counting loop that runs across
;   vertical blanks; each time a pass of RUNS counts is done it adds 1 to R4.
;   Without RESUME it would start again every frame and never finish a pass.
;
; Layer 0 is on, chunky 1 bpp, fetching one line of zeros over and over
; (BPLSTRIDE = 0): the whole screen shows colour 0.

            include "hw.inc"
            include "copper.inc"

RAMLIST     equ     $020000
ZEROS       equ     $030000             ; 90 bytes of 0: one line of layer 0
RUNS        equ     24000               ; counts per background pass
FRAMES      equ     5

            org ROM
            dc.l    $010000             ; stack
            dc.l    start
            dcb.l   254,hang

start:      move.w  #$2700,sr
            lea     SYSTEM,a5
            lea     CUSTOM,a4
            move.l  #SERCON_EN_M|SERCON_TXDROP_M,SERCON(a5)

            ; the list into Chip RAM
            lea     clist(pc),a0
            lea     RAMLIST,a1
            move.w  #(clist_end-clist)/4-1,d0
.copy:      move.l  (a0)+,(a1)+
            dbra    d0,.copy

            ; layer 0: colour 0 everywhere
            lea     ZEROS,a0
            moveq   #90/2-1,d0
.zero:      clr.w   (a0)+
            dbra    d0,.zero
            move.l  #ZEROS,L0+L_BPL0PT(a4)
            move.l  #0,L0+L_BPLSTRIDE(a4)
            move.w  #L_BPLDMA_SETCLR_M|1,L0+L_BPLDMA+2(a4)
            move.l  #(VID_X0<<16)|(VID_X0+VID_W),L0+L_WINX(a4)
            move.l  #(VID_Y0<<16)|(VID_Y0+VID_H),L0+L_WINY(a4)
            move.l  #L_CTRL_EN_M,L0+L_CTRL(a4)

            ; the copper
            move.l  #RAMLIST,COP1LC(a4)
            move.l  #RAMLIST+(idle-clist),COP2LC(a4)
            move.l  #COPCON_EN_M|COPCON_RESUME_M|(1<<COPCON_PRI_B),COPCON(a4)
            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_COPEN_M|DMACON_BPLEN_M,DMACON+2(a4)
            move.l  #VIDCON_EN_M,VIDCON(a4)

            ; the background list starts at the next COPJMP2
            move.l  #RAMLIST+(bg-clist),COP2LC(a4)

            moveq   #0,d7
.frame:     move.l  VIDSTAT(a4),d0
            and.l   #VIDSTAT_VBLANK_M,d0
            beq.s   .frame
            move.l  #VIDSTAT_VBLANK_M,VIDSTAT(a4)
            addq.l  #1,d7
            cmp.l   #FRAMES,d7
            bne.s   .frame

            ; wait for the copper to be past its vertical blank work
.late:      move.l  BEAMPOS(a4),d0
            swap    d0
            and.w   #$7FF,d0
            cmp.w   #320,d0
            blo.s   .late

            ; check
            lea     expect(pc),a2
.chk:       move.l  (a2)+,d0            ; offset, or -1
            bmi.s   .extra
            move.l  (a2)+,d1            ; mask
            move.l  (a2)+,d2            ; value
            move.l  0(a4,d0.l),d3
            and.l   d1,d3
            cmp.l   d2,d3
            beq.s   .chk
            bra     failed
.extra:     move.l  COPR4(a4),d3        ; background passes: at least 1
            move.l  #COPR4,d0
            moveq   #0,d2
            tst.l   d3
            beq     failed
            lea     s_pass(pc),a0
            bsr     puts
.done:      bra.s   .done

; d0 = offset, d2 = expected, d3 = read
failed:     lea     s_fail(pc),a0
            bsr     puts
            bsr     hex
            move.l  d2,d0
            bsr     hex
            move.l  d3,d0
            bsr     hex
            lea     s_nl(pc),a0
            bsr     puts
.done:      bra.s   .done

hex:        moveq   #7,d4
.dig:       rol.l   #4,d0
            move.l  d0,d5
            and.w   #15,d5
            move.b  digits(pc,d5.w),d5
.wait:      move.w  SERSTAT+2(a5),d6
            and.w   #SERSTAT_TXSPACE_M,d6
            beq.s   .wait
            move.b  d5,SERDATA+3(a5)
            dbra    d4,.dig
            move.b  #' ',SERDATA+3(a5)
            rts
digits:     dc.b    "0123456789ABCDEF"

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
s_fail:     dc.b    "FAIL ",0
s_nl:       dc.b    13,10,0
            even

; offset, mask, value
expect:     dc.l    COPR0,$FFFF,$1234           ; MOVE to its own register
            dc.l    COPR1,$FFFF,$1000           ; $00F0 + $0F10
            dc.l    COPR6,$FFFF,$AAAA           ; CALL ... RET
            dc.l    COPR7,$FFFF,$5555           ; nested CALL
            dc.l    PALETTE0+1*4,$FFFFFF,$123456 ; MOVR through X, X+
            dc.l    PALETTE0+2*4,$FFFFFF,$117788 ; ... data from Y
            dc.l    PALETTE0+3*4,$FFFF,$3031     ; AND, OR
            dc.l    PALETTE0+4*4,$FFFF,$0296     ; the conditions
            dc.l    PALETTE0+5*4,$FFFF,$0006     ; flags after 5 - 6: N, C
            dc.l    PALETTE0+6*4,$FFFF,$0005     ; LD to the flags, read back
            dc.l    PALETTE0+7*4,$FFFF,$0004     ; flags after $FFFF + 2: C
            dc.l    PALETTE0+8*4,$FFFF,$FFFF     ; 5 - 6
            dc.l    PALETTE0+9*4,$FFFF,30        ; counted loop: 10 x 3
            dc.l    COPSTAT,$C,$8               ; IRQ set (COPINT), ERR clear
            dc.l    COPSP,$F,0                  ; the stack empty again
            dc.l    -1

; ---------------------------------------------------------------- the list
; Assembled here, run at RAMLIST: jump targets are RAMLIST+(label-clist).
; Storage registers: R0, R1, R6, R7 results; R2, R5, R3 list 2's X, Y and
; flags while list 1 runs; R4 list 2's pass counter.

            cnop    0,4
clist:      CST     CR2,CX                      ; save list 2's registers
            CST     CR5,CY
            CST     CR3,CF
            CMOVEL  PALETTE0,$000000             ; colour 0 black for the top

            CMOVE   COPR0+2,$1234

            CLDI    CX,$00F0
            CADDI   CX,$0F10
            CST     CR1,CX

            CLDI    CY,$FFFF
            CADDI   CY,2                        ; Y = 1, carry
            CST     CR7,CF
            CLD     CX,CR7
            CMOVR   PALETTE0+7*4+2,CX

            CLDI    CY,5
            CSUBI   CY,6                        ; Y = $FFFF, borrow, negative
            CST     CR7,CF
            CMOVR   PALETTE0+8*4+2,CY
            CLD     CX,CR7
            CMOVR   PALETTE0+5*4+2,CX

            ; counted loop: Y = 3 x 10
            CLDI    CY,0
            CLDI    CX,10
loop1:      CADDI   CY,3
            CSUBI   CX,1
            CSKIPEQ
            CJUMP   RAMLIST+(loop1-clist)
            CMOVR   PALETTE0+9*4+2,CY

            ; subroutines, two deep
            CCALL   RAMLIST+(sub1-clist)

            ; MOVR through X with X+
            CLDI    CX,PALETTE0+1*4
            CMOVXP  $0012
            CMOVXP  $3456
            CLDI    CY,$7788
            CMOVXP  $0011
            CMOVXRP CY

            ; AND, OR
            CLDI    CX,$F0F0
            CANDI   CX,$3C3C                    ; $3030
            CORI    CX,$0001                    ; $3031
            CMOVR   PALETTE0+3*4+2,CX

            ; conditions: each wrong skip shows as a missing bit, each
            ; wrong non-skip as an extra bit; expected $0296
            CLDI    CY,0
            CLDI    CX,5
            CCMPI   CX,5
            CSKIPEQ
            CORI    CY,$0001                    ; skipped
            CCMPI   CX,5
            CSKIPNE
            CORI    CY,$0002
            CCMPI   CX,5
            CSKIPLO
            CORI    CY,$0004
            CCMPI   CX,5
            CSKIPHS
            CORI    CY,$0008                    ; skipped
            CCMPI   CX,5
            CSKIPHI
            CORI    CY,$0010
            CCMPI   CX,5
            CSKIPLS
            CORI    CY,$0020                    ; skipped
            CCMPI   CX,6
            CSKIPLO
            CORI    CY,$0040                    ; skipped
            CCMPI   CX,6
            CSKIPHI
            CORI    CY,$0080
            CCMPI   CX,6
            CSKIPMI
            CORI    CY,$0100                    ; skipped
            CCMPI   CX,6
            CSKIPPL
            CORI    CY,$0200
            CMOVR   PALETTE0+4*4+2,CY

            ; LD to the flags, then read them back
            CLDI    CF,5
            CST     CR7,CF
            CLD     CX,CR7
            CMOVR   PALETTE0+6*4+2,CX
            CCALL   RAMLIST+(sub2-clist)        ; R7 = $5555 again

            CMOVE   COPINT+2,0

            ; ---- the picture
            ; each colour's high half before the WAIT (held), its low half
            ; after it: the whole colour changes exactly at the position
            CMOVE   PALETTE0,$00FF
            CWAIT   VID_Y0+100,VID_X0+200
            CMOVE   PALETTE0+2,$0000             ; red
            CMOVE   PALETTE0,$0000
            CWAIT   VID_Y0+100,VID_X0+500
            CMOVE   PALETTE0+2,$FF00             ; green
            CWAIT   VID_Y0+200,0                ; the blank before picture line 200
            CLDI    CY,$0010
loop2:      CWAITP  VID_X0+360
            CMOVR   PALETTE0+2,CY                ; green and blue = Y, red kept (0)
            CADDI   CY,$0808
            CSKIP   VID_Y0+209,VID_X0+400
            CJUMP   RAMLIST+(loop2-clist)
            CMOVE   PALETTE0,$0000
            CWAIT   VID_Y0+300,VID_X0+0
            CMOVE   PALETTE0+2,$00FF             ; blue

            ; ---- on to list 2, with its registers back
            CLD     CX,CR2
            CLD     CY,CR5
            CLD     CF,CR3
            CMOVE   COPJMP2+2,0

idle:       CSTOP

sub1:       CLDI    CX,$AAAA
            CMOVR   COPR6+2,CX
            CCALL   RAMLIST+(sub2-clist)
            CRET
sub2:       CLDI    CX,$5555
            CMOVR   COPR7+2,CX
            CRET

; list 2: count X to RUNS, then R4 = R4 + 1, and again
bg:         CLDI    CX,0
bgloop:     CADDI   CX,1
            CCMPI   CX,RUNS
            CSKIPHS
            CJUMP   RAMLIST+(bgloop-clist)
            CLD     CY,CR4
            CADDI   CY,1
            CST     CR4,CY
            CJUMP   RAMLIST+(bg-clist)
clist_end:
