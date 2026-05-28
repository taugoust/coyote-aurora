/**
 * Coyote Example 14: Aurora 64B/66B FPGA-to-FPGA Loopback
 *
 * User logic for the Aurora-loopback example. The vFPGA has access to:
 *   - axis_aurora_rx  : 256-bit AXI4-Stream from the Aurora RX path (aclk domain)
 *   - axis_aurora_tx  : 256-bit AXI4-Stream into Aurora TX path
 *   - aurora_channel_up, aurora_lane_up[3:0] : link status from Aurora IP
 *
 * Host control flow (via axi_ctrl, 64-bit register slots):
 *   reg[0]  CTRL          : bit0=TX start, bit1=RX arm
 *   reg[1]  STATUS        : bit0=tx_done, bit1=rx_done, bit2=channel_up, bits[6:3]=lane_up
 *   reg[2]  TX_BURST_BEATS: number of 256-bit beats to send (host-supplied)
 *   reg[3]  RX_BEAT_CNT   : observed RX beat count (read-only)
 *   reg[4]  RX_MISMATCHES : count of beats where expected pattern != received (read-only)
 *
 * On the rose side, set CTRL bit 0 to fire a burst of N beats with payload {beat_idx, beat_idx, ...}
 * On the clara side, set CTRL bit 1 to arm RX. Then check RX_BEAT_CNT and RX_MISMATCHES.
 */

// =========================================================================
// Control / status registers parsed off axi_ctrl
// =========================================================================
localparam int N_REGS         = 8;
localparam int ADDR_LSB       = 3;             // 64-bit data -> 3 LSBs ignored
localparam int ADDR_MSB       = $clog2(N_REGS);
localparam int REG_ADDR_BITS  = ADDR_LSB + ADDR_MSB;

logic [63:0] csr [N_REGS-1:0];

// Convenience aliases
wire        tx_start   = csr[0][0];
wire        rx_arm     = csr[0][1];
wire [63:0] tx_burst_beats = csr[2];

// Tiny AXI4-Lite slave (read/write only, no error/burst handling)
logic [REG_ADDR_BITS-1:0] aw_addr_q, ar_addr_q;
logic                     aw_seen, w_seen, ar_seen;

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        aw_seen <= 1'b0; w_seen <= 1'b0; ar_seen <= 1'b0;
        for (int i = 0; i < N_REGS; i++) csr[i] <= '0;
    end else begin
        // Write address
        if (axi_ctrl.awvalid && !aw_seen) begin
            aw_addr_q <= axi_ctrl.awaddr[REG_ADDR_BITS-1:0];
            aw_seen   <= 1'b1;
        end
        // Write data
        if (axi_ctrl.wvalid && !w_seen) w_seen <= 1'b1;
        // Commit write
        if (aw_seen && w_seen && axi_ctrl.bready) begin
            csr[aw_addr_q[REG_ADDR_BITS-1:ADDR_LSB]] <= axi_ctrl.wdata;
            aw_seen <= 1'b0; w_seen <= 1'b0;
        end
        // Read address
        if (axi_ctrl.arvalid && !ar_seen) begin
            ar_addr_q <= axi_ctrl.araddr[REG_ADDR_BITS-1:0];
            ar_seen   <= 1'b1;
        end
        // Drop read-handshake once rready
        if (ar_seen && axi_ctrl.rready) ar_seen <= 1'b0;
    end
end

assign axi_ctrl.awready = !aw_seen;
assign axi_ctrl.wready  = !w_seen;
assign axi_ctrl.bvalid  = aw_seen && w_seen;
assign axi_ctrl.bresp   = 2'b00;
assign axi_ctrl.arready = !ar_seen;
assign axi_ctrl.rvalid  = ar_seen;
assign axi_ctrl.rdata   = csr[ar_addr_q[REG_ADDR_BITS-1:ADDR_LSB]];
assign axi_ctrl.rresp   = 2'b00;

// =========================================================================
// TX path: send `tx_burst_beats` counter-pattern beats over Aurora
// =========================================================================
logic [63:0] tx_beat_idx;
logic        tx_running;
logic        tx_done;

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        tx_beat_idx <= '0;
        tx_running  <= 1'b0;
        tx_done     <= 1'b0;
    end else begin
        if (tx_start && !tx_running && !tx_done) begin
            tx_running  <= 1'b1;
            tx_beat_idx <= '0;
        end
        if (tx_running && axis_aurora_tx.tready) begin
            tx_beat_idx <= tx_beat_idx + 1;
            if (tx_beat_idx + 1 == tx_burst_beats) begin
                tx_running <= 1'b0;
                tx_done    <= 1'b1;
            end
        end
        if (!tx_start) tx_done <= 1'b0;  // edge-triggered restart
    end
end

assign axis_aurora_tx.tvalid = tx_running && aurora_channel_up;
assign axis_aurora_tx.tdata  = {4{tx_beat_idx}};  // 256 bits = 4 copies of beat idx
assign axis_aurora_tx.tkeep  = '1;
assign axis_aurora_tx.tlast  = tx_running && (tx_beat_idx + 1 == tx_burst_beats);

// =========================================================================
// RX path: count beats, check pattern, count mismatches
// =========================================================================
logic [63:0] rx_beat_cnt;
logic [63:0] rx_mismatches;
logic        rx_done;

always_ff @(posedge aclk) begin
    if (!aresetn || !rx_arm) begin
        rx_beat_cnt   <= '0;
        rx_mismatches <= '0;
        rx_done       <= 1'b0;
    end else if (axis_aurora_rx.tvalid && axis_aurora_rx.tready) begin
        rx_beat_cnt <= rx_beat_cnt + 1;
        // Each beat should be {4{rx_beat_cnt}}; mismatch increments counter
        if (axis_aurora_rx.tdata != {4{rx_beat_cnt}}) begin
            rx_mismatches <= rx_mismatches + 1;
        end
        if (axis_aurora_rx.tlast) rx_done <= 1'b1;
    end
end

assign axis_aurora_rx.tready = rx_arm;

// Live status registers (read-only side)
always_comb begin
    // bit0=tx_done, bit1=rx_done, bit2=channel_up, bits[6:3]=lane_up
    csr[1] = {57'b0, aurora_lane_up, aurora_channel_up, rx_done, tx_done};
    csr[3] = rx_beat_cnt;
    csr[4] = rx_mismatches;
end

// =========================================================================
// Tie off all the Coyote interfaces we don't use
// =========================================================================
always_comb axis_host_recv[0].tie_off_s();
always_comb axis_host_send[0].tie_off_m();
always_comb notify.tie_off_m();
always_comb sq_rd.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb cq_wr.tie_off_s();
