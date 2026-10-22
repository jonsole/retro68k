; Copper instruction macros (spec 10, section 4), for vasm (Motorola syntax).
; Include hw.inc first. Register names are offsets in the custom block,
; as in hw.inc (for example L1+L_BPL0PT, BGCOLOR, PALETTE+4*n).
;
;   CMOVE   reg,value       write 16 bits to a register half
;   CMOVEL  reg,value       write a 32-bit register: two MOVEs, high half first
;   CWAIT   line,pixel      wait until the beam reaches line, pixel (frame order)
;   CWAITP  pixel           wait for a pixel position on the current or next line
;   CWAITB  line,pixel      as CWAIT, and until the DMA engine is idle
;   CSKIP   line,pixel      skip the next instruction if the beam has reached it
;   CSKIPP  pixel           as CSKIP, pixel position only
;   CJUMP   address         continue at address (4-byte aligned)
;   CSTOP                   stop until the next frame

CMOVE       macro
            dc.w    (\1)&$7FFE,(\2)&$FFFF
            endm

CMOVEL      macro
            dc.w    (\1)&$7FFE,((\2)>>16)&$FFFF
            dc.w    ((\1)+2)&$7FFE,(\2)&$FFFF
            endm

CWAIT       macro
            dc.l    COP_EXT|(COP_OP_WAIT<<COP_OP_SHIFT)|(((\1)&$7FF)<<COP_V_SHIFT)|((\2)&$7FF)
            endm

CWAITP      macro
            dc.l    COP_EXT|(COP_OP_WAIT<<COP_OP_SHIFT)|COP_PIXONLY|((\1)&$7FF)
            endm

CWAITB      macro
            dc.l    COP_EXT|(COP_OP_WAIT<<COP_OP_SHIFT)|COP_BLT|(((\1)&$7FF)<<COP_V_SHIFT)|((\2)&$7FF)
            endm

CSKIP       macro
            dc.l    COP_EXT|(COP_OP_SKIP<<COP_OP_SHIFT)|(((\1)&$7FF)<<COP_V_SHIFT)|((\2)&$7FF)
            endm

CSKIPP      macro
            dc.l    COP_EXT|(COP_OP_SKIP<<COP_OP_SHIFT)|COP_PIXONLY|((\1)&$7FF)
            endm

CJUMP       macro
            dc.l    COP_EXT|(COP_OP_JUMP<<COP_OP_SHIFT)|((\1)&$7FFFFC)
            endm

CSTOP       macro
            dc.l    COP_EXT|(COP_OP_STOP<<COP_OP_SHIFT)
            endm
