// retro68k: the computer, without board-specific parts (clocks, pads).
//
// Version 1 (phase 2): fx68k, bus interface, SRAM controller, boot ROM,
// system registers and USB serial. One DMA port stands in for the DMA users
// still to come, so tests can load the memory while the CPU runs.
module retro68k #(
    parameter ROM_INIT = "boot.hex",
    parameter [5:0] CHIPMB = 6'd4
) (
    input  wire        clk100,
    input  wire        clk40,
    input  wire        clk_pix,       // 27 MHz pixel clock (576p), asynchronous to clk100
    input  wire        clk_pix5,      // 135 MHz, 5 x clk_pix with edges lined up (same MMCM)
    input  wire        por100,        // power-on reset; last seen high on a slot boundary
    input  wire        por40,         // the same, in the 40 MHz domain
    input  wire        btn_reset_n,   // debounced
    input  wire [1:0]  buttons,       // MULTIFACE (0), DIVMMC (1), 1 = pressed

    // SRAM (before the DDR output registers)
    output wire [20:0] sram_a,
    output wire        sram_ce_n, sram_ub_n, sram_lb_n,
    output wire        sram_oe_n_r, sram_oe_n_f,
    output wire        sram_we_n_r, sram_we_n_f,
    output wire [15:0] sram_dq_o,
    output wire        sram_dq_t_r, sram_dq_t_f,
    input  wire [15:0] sram_dq_i,

    // FT232H
    input  wire        ft_rxf_n, ft_txe_n,
    input  wire [7:0]  ft_d_i,
    output wire [7:0]  ft_d_o,
    output wire        ft_d_oe, ft_rd_n, ft_wr_n, ft_siwu_n,

    // DMA port (tests; later the DMA users)
    input  wire        dma_req, dma_we,
    input  wire [21:1] dma_addr,
    input  wire [15:0] dma_wdata,
    input  wire [1:0]  dma_be,
    output wire        dma_ack, dma_rvalid,
    output wire [15:0] dma_rdata,

    // Video out (pixel clock domain)
    output wire [23:0] vid_rgb,
    output wire        vid_hsync, vid_vsync, vid_de,

    // Audio: sigma-delta streams (the jack's left and right, the speaker)
    output wire        aud_l, aud_r, aud_m,

    // Debug
    output wire [3:0]  dbg_sc,
    output wire        dbg_halted
);
    // ---------------------------------------------------------------- timebase
    wire [2:0] ph;
    wire [3:0] sc;
    timebase tb0 (.clk(clk100), .rst(por100), .ph(ph), .sc(sc));
    assign dbg_sc = sc;

    reg [6:0] us_div;
    wire      us_tick = (us_div == 7'd99);
    always @(posedge clk100) us_div <= (por100 || us_tick) ? 7'd0 : us_div + 1'b1;

    // ---------------------------------------------------------------- reset (spec 7, section 2)
    wire soft_reset, cmd_break, cmd_reset, cmd_upload, haltreset;
    wire c_halted_n;
    reg  [1:0] btn_s;
    always @(posedge clk100) btn_s <= {btn_s[0], btn_reset_n};

    wire halted   = !c_halted_n;
    wire wd_reset;
    wire rst_req  = !btn_s[1] || soft_reset || cmd_reset || cmd_upload || (halted && haltreset) || wd_reset;
    reg  [8:0] rst_cnt;
    // It resets nearly everything: Vivado copies it, so each copy drives
    // few enough loads to meet timing
    (* max_fanout = 50 *) reg sys_rst;
    reg        cold;                // power-on: fx68k's pwrUp
    reg  [7:0] resetwhy;

    always @(posedge clk100) begin
        if (por100) begin
            rst_cnt  <= 9'd0;
            sys_rst  <= 1'b1;
            cold     <= 1'b1;
            resetwhy <= 8'h01;       // POWER
        end else if (rst_req && !sys_rst) begin
            rst_cnt  <= 9'd0;
            sys_rst  <= 1'b1;
            resetwhy <= {halted && haltreset, 1'b0, cmd_upload, cmd_reset || cmd_upload,
                         soft_reset, !btn_s[1], wd_reset, 1'b0};
        end else if (sys_rst) begin
            // Hold reset for 5.12 us, and end it on a slot boundary
            if (rst_cnt != 9'd511) rst_cnt <= rst_cnt + 1'b1;
            else if (sc == 4'd9) begin
                sys_rst <= 1'b0;
                cold    <= 1'b0;
            end
        end
    end

    // fx68k's reset inputs cross like its other inputs (they change at 10 or 30 ns)
    // and so does IPL, from the interrupt controller
    reg cpu_rst = 1'b1, cpu_cold = 1'b1;
    reg [2:0] cpu_ipl_n = 3'b111;
    wire [2:0] int_level;
    always @(posedge clk100) if (ph == 3'd0 || ph == 3'd2) begin
        cpu_rst   <= sys_rst;
        cpu_cold  <= cold;
        cpu_ipl_n <= ~int_level;
    end

    // ---------------------------------------------------------------- CPU
    wire        c_as_n, c_uds_n, c_lds_n, c_rw, c_reset_n;
    wire [2:0]  c_fc;
    wire [23:1] c_addr;
    wire [15:0] c_dout;
    wire        dtack_n, berr_n;
    wire [15:0] din;

    cpu_fx68k cpu (
        .clk(clk40), .por(por40), .rst(cpu_rst), .pwrup(cpu_cold),
        .as_n(c_as_n), .uds_n(c_uds_n), .lds_n(c_lds_n), .rw(c_rw),
        .fc(c_fc), .addr(c_addr), .dout(c_dout),
        .reset_out_n(c_reset_n), .halted_n(c_halted_n),
        .dtack_n(dtack_n), .berr_n(berr_n), .ipl_n(cpu_ipl_n), .din(din)
    );
    assign dbg_halted = halted;

    // ---------------------------------------------------------------- bus
    wire        overlay, romwe, protect;
    wire        m_req, m_we, m_ack, m_rvalid;
    wire [21:1] m_addr;
    wire [15:0] m_wdata, mem_rdata;
    wire [1:0]  m_be;
    wire        rom_en;
    wire [1:0]  rom_we;
    wire [14:1] rom_addr;
    wire [15:0] rom_wdata, rom_rdata;
    // The register bus: the CPU's accesses (bus_if) and the copper's writes.
    // A CPU access on the bus goes first; the copper's write waits a clock.
    wire        c_rb_rd, c_rb_wr;
    wire [23:2] c_rb_addr;
    wire [31:0] c_rb_wdata;
    wire [3:0]  c_rb_be;
    wire        cw_req;
    wire [23:2] cw_addr;
    wire [31:0] cw_wdata;
    wire [3:0]  cw_be;
    wire        cw_go    = cw_req && !c_rb_rd && !c_rb_wr;
    wire        rb_rd    = c_rb_rd;
    wire        rb_wr    = c_rb_wr || cw_go;
    wire [23:2] rb_addr  = cw_go ? cw_addr  : c_rb_addr;
    wire [31:0] rb_wdata = cw_go ? cw_wdata : c_rb_wdata;
    wire [3:0]  rb_be    = cw_go ? cw_be    : c_rb_be;
    wire [31:0] rd_sys, rd_ser;
    wire        iack;
    wire [2:0]  iack_level;
    wire [7:0]  iack_vector;
    wire [31:0] rd_int, rd_vid, rd_tmr, rd_cop, rd_aud;
    wire        berr_ev;
    wire [23:0] berr_addr;
    wire [3:0]  berr_why;

    bus_if #(.CHIP_TOP({CHIPMB[3:0], 20'd0})) bus (
        .clk(clk100), .rst(sys_rst), .ph(ph),
        .c_as_n(c_as_n), .c_uds_n(c_uds_n), .c_lds_n(c_lds_n), .c_rw(c_rw),
        .c_fc(c_fc), .c_addr(c_addr), .c_dout(c_dout),
        .dtack_n(dtack_n), .berr_n(berr_n), .din(din),
        .overlay(overlay), .romwe(romwe), .protect(protect),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata), .m_be(m_be),
        .m_ack(m_ack), .m_rvalid(m_rvalid), .m_rdata(mem_rdata),
        .rom_en(rom_en), .rom_we(rom_we), .rom_addr(rom_addr), .rom_wdata(rom_wdata),
        .rom_rdata(rom_rdata),
        .rb_rd(c_rb_rd), .rb_wr(c_rb_wr), .rb_addr(c_rb_addr), .rb_wdata(c_rb_wdata), .rb_be(c_rb_be),
        .rb_rdata(rd_sys | rd_ser | rd_int | rd_vid | rd_tmr | rd_cop | rd_aud),
        .iack(iack), .iack_level(iack_level), .iack_vector(iack_vector),
        .berr_ev(berr_ev), .berr_addr(berr_addr), .berr_why(berr_why)
    );

    // ---------------------------------------------------------------- memory
    wire        disp_req, disp_urgent, disp_ack, disp_rvalid;
    wire        spr_req, spr_urgent, spr_ack, spr_rvalid;
    wire [21:1] spr_addr;
    wire [9:0]  spr_deadline;
    wire [21:1] disp_addr;
    wire [9:0]  disp_deadline;
    wire        aud_req, aud_ack, aud_rvalid;
    wire [21:1] aud_addr;
    wire        cop_req, cop_ack, cop_rvalid;
    wire [21:1] cop_addr;
    wire [1:0]  cop_pri;
    // The DMA scheduler (spec 5): who gets each memory cycle. The DMA engine
    // is still to come; its channel is tied off.
    wire        m_start, m_go, m_go_we, m_rvalid_any;
    wire [2:0]  m_cycle, m_go_tag, m_rtag;
    wire [21:1] m_go_addr;
    wire [15:0] m_go_wdata;
    wire [1:0]  m_go_be;
    dmac sched (
        .clk(clk100), .rst(sys_rst), .start_next(m_start), .next_cycle(m_cycle),
        .cpu_req(m_req), .cpu_we(m_we), .cpu_addr(m_addr), .cpu_wdata(m_wdata), .cpu_be(m_be),
        .cpu_ack(m_ack), .cpu_rvalid(m_rvalid),
        .bpl_req(disp_req), .bpl_addr(disp_addr), .bpl_deadline(disp_deadline), .bpl_urgent(disp_urgent),
        .bpl_ack(disp_ack), .bpl_rvalid(disp_rvalid),
        .spr_req(spr_req), .spr_addr(spr_addr), .spr_deadline(spr_deadline), .spr_urgent(spr_urgent), .spr_ack(spr_ack), .spr_rvalid(spr_rvalid),
        .aud_req(aud_req), .aud_addr(aud_addr), .aud_ack(aud_ack), .aud_rvalid(aud_rvalid),
        .cop_req(cop_req), .cop_addr(cop_addr), .cop_pri(cop_pri), .cop_ack(cop_ack), .cop_rvalid(cop_rvalid),
        .blt_req(1'b0), .blt_we(1'b0), .blt_addr(21'd0), .blt_wdata(16'd0), .blt_be(2'b00), .blt_ack(), .blt_rvalid(),
        .port_req(dma_req), .port_we(dma_we), .port_addr(dma_addr), .port_wdata(dma_wdata), .port_be(dma_be),
        .port_ack(dma_ack), .port_rvalid(dma_rvalid),
        .go(m_go), .go_we(m_go_we), .go_addr(m_go_addr), .go_wdata(m_go_wdata), .go_be(m_go_be), .go_tag(m_go_tag),
        .rvalid(m_rvalid_any), .rtag(m_rtag)
    );
    sram_ctl mem (
        .clk(clk100), .rst(sys_rst), .sc(sc),
        .go(m_go), .go_we(m_go_we), .go_addr(m_go_addr), .go_wdata(m_go_wdata), .go_be(m_go_be), .go_tag(m_go_tag),
        .start_next(m_start), .next_cycle(m_cycle), .rvalid(m_rvalid_any), .rtag(m_rtag),
        .rdata(mem_rdata),
        .sram_a(sram_a), .sram_ce_n(sram_ce_n), .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n),
        .sram_oe_n_r(sram_oe_n_r), .sram_oe_n_f(sram_oe_n_f),
        .sram_we_n_r(sram_we_n_r), .sram_we_n_f(sram_we_n_f),
        .sram_dq_o(sram_dq_o), .sram_dq_t_r(sram_dq_t_r), .sram_dq_t_f(sram_dq_t_f),
        .sram_dq_i(sram_dq_i)
    );
    assign dma_rdata = mem_rdata;

    bootrom #(.INIT(ROM_INIT)) rom (
        .clk(clk100), .en(rom_en), .we(rom_we), .addr(rom_addr), .wdata(rom_wdata),
        .rdata(rom_rdata)
    );

    // ---------------------------------------------------------------- system block
    sysregs #(.CHIPMB(CHIPMB)) sys (
        .clk(clk100), .rst(sys_rst), .por(por100),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be),
        .rb_rdata(rd_sys),
        .resetwhy(resetwhy), .buttons(buttons), .halted(halted),
        .berr_ev(berr_ev), .berr_addr(berr_addr), .berr_why(berr_why),
        .overlay(overlay), .romwe(romwe), .protect(protect), .haltreset(haltreset),
        .soft_reset(soft_reset)
    );

    // The USB link survives resets it causes itself (spec 14), so only power-on resets it
    wire ser_irq;
    serial ser (
        .clk(clk100), .rst(por100), .us_tick(us_tick),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be),
        .rb_rdata(rd_ser),
        .irq(ser_irq), .cmd_break(cmd_break), .cmd_reset(cmd_reset), .cmd_upload(cmd_upload),
        .ft_rxf_n(ft_rxf_n), .ft_txe_n(ft_txe_n), .ft_d_i(ft_d_i), .ft_d_o(ft_d_o),
        .ft_d_oe(ft_d_oe), .ft_rd_n(ft_rd_n), .ft_wr_n(ft_wr_n), .ft_siwu_n(ft_siwu_n)
    );

    // ---------------------------------------------------------------- video (spec 4)
    wire irq_vblank, irq_line, irq_viderr, line_tick, frame_tick;
    wire [15:0] dmacon;
    wire [10:0] beam_v, beam_h;
    video vid (
        .clk(clk100), .rst(sys_rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be),
        .rb_rdata(rd_vid),
        .irq_vblank(irq_vblank), .irq_line(irq_line), .irq_viderr(irq_viderr),
        .line_tick(line_tick), .frame_tick(frame_tick), .beam_v(beam_v), .beam_h(beam_h),
        .dmacon(dmacon), .disp_req(disp_req), .disp_urgent(disp_urgent), .disp_deadline(disp_deadline), .disp_addr(disp_addr),
        .disp_ack(disp_ack), .disp_rvalid(disp_rvalid), .disp_rdata(mem_rdata),
        .spr_req(spr_req), .spr_urgent(spr_urgent), .spr_deadline(spr_deadline), .spr_addr(spr_addr),
        .spr_ack(spr_ack), .spr_rvalid(spr_rvalid),
        .clk_pix(clk_pix), .clk_pix5(clk_pix5), .rgb(vid_rgb), .hsync(vid_hsync), .vsync(vid_vsync), .de(vid_de)
    );

    // ---------------------------------------------------------------- copper (spec 10)
    wire cop_irq;
    copper cop (
        .clk(clk100), .rst(sys_rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be),
        .rb_rdata(rd_cop),
        .cw_req(cw_req), .cw_addr(cw_addr), .cw_wdata(cw_wdata), .cw_be(cw_be), .cw_go(cw_go),
        .mem_req(cop_req), .mem_addr(cop_addr), .mem_pri(cop_pri), .mem_ack(cop_ack),
        .mem_rvalid(cop_rvalid), .mem_rdata(mem_rdata),
        .beam_v(beam_v), .beam_h(beam_h), .vblank(frame_tick), .dmacon(dmacon),
        .blt_idle(1'b1),   // no DMA engine yet
        .irq(cop_irq)
    );

    // ---------------------------------------------------------------- audio (spec 6)
    wire aud_irq;
    audio aud (
        .clk(clk100), .rst(sys_rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be),
        .rb_rdata(rd_aud), .dmacon(dmacon),
        .mem_req(aud_req), .mem_addr(aud_addr), .mem_ack(aud_ack),
        .mem_rvalid(aud_rvalid), .mem_rdata(mem_rdata),
        .irq(aud_irq), .out_l(), .out_r(), .tick_done(),
        .dac_l(aud_l), .dac_r(aud_r), .dac_m(aud_m)
    );

    // ---------------------------------------------------------------- timers (spec 12)
    wire [3:0] tmr_irq, tmr_dma_start;
    wire [7:0] tmr_dma_ch;
    timers tmr (
        .clk(clk100), .por(por100), .rst(sys_rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be),
        .rb_rdata(rd_tmr),
        .us_tick(us_tick), .line_tick(line_tick), .frame_tick(frame_tick),
        .irq(tmr_irq), .dma_start(tmr_dma_start), .dma_ch(tmr_dma_ch), .wd_reset(wd_reset)
    );

    // ---------------------------------------------------------------- interrupts (spec 13)
    reg [1:0] nmi_s;
    always @(posedge clk100) nmi_s <= {nmi_s[0], buttons[0]};

    intc ic (
        .clk(clk100), .rst(sys_rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be),
        .rb_rdata(rd_int),
        .req({8'd0, ser_irq, tmr_irq, 1'b0, aud_irq, 5'd0, irq_viderr, cop_irq, irq_line, irq_vblank}),
        .nmi_button(nmi_s[1]), .nmi_usb(cmd_break),
        .level(int_level), .iack(iack), .iack_level(iack_level), .iack_vector(iack_vector)
    );
endmodule
