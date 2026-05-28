/**
 * Coyote peer-stream loopback test.
 *
 * User logic for exercising the optional Coyote peer abstraction. With the
 * prototype host_stream backend, host stream 1 is hidden by Coyote and exposed
 * here as:
 *   - axis_peer_recv[0] : fake peer -> vFPGA
 *   - axis_peer_send[0] : vFPGA -> fake peer
 *   - peer_link_up[0], peer_lane_up[3:0] : backend status
 *
 * Host control flow (via axi_ctrl, 64-bit register slots):
 *   reg[0]  CTRL          : bit0=TX start, bit1=RX arm
 *   reg[1]  STATUS        : bit0=tx_done, bit1=rx_done, bit2=peer_link_up, bits[6:3]=peer_lane_up
 *   reg[2]  TX_BURST_BEATS: number of 256-bit beats to send
 *   reg[3]  RX_BEAT_CNT   : observed RX beat count
 *   reg[4]  RX_MISMATCHES : count of beats where expected pattern != received
 */

// =========================================================================
// Control / status registers parsed off axi_ctrl
// =========================================================================
localparam int N_REGS         = 8;
localparam int ADDR_LSB       = 3;             // 64-bit data -> 3 LSBs ignored
localparam int ADDR_MSB       = $clog2(N_REGS);
localparam int REG_ADDR_BITS  = ADDR_LSB + ADDR_MSB;

logic [63:0] csr [N_REGS-1:0];

wire        tx_start       = csr[0][0];
wire        rx_arm         = csr[0][1];
wire [63:0] tx_burst_beats = csr[2];
wire        peer_up        = peer_link_up[0];
wire [3:0]  peer_lanes     = peer_lane_up[3:0];

logic [63:0] status_reg;
logic [63:0] read_data;

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
        // Commit write. Status registers are read-only from the host's point of view.
        if (aw_seen && w_seen && axi_ctrl.bready) begin
            if (aw_addr_q[REG_ADDR_BITS-1:ADDR_LSB] != 1
                && aw_addr_q[REG_ADDR_BITS-1:ADDR_LSB] != 3
                && aw_addr_q[REG_ADDR_BITS-1:ADDR_LSB] != 4) begin
                csr[aw_addr_q[REG_ADDR_BITS-1:ADDR_LSB]] <= axi_ctrl.wdata;
            end
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
assign axi_ctrl.rdata   = read_data;
assign axi_ctrl.rresp   = 2'b00;

// =========================================================================
// TX path: send `tx_burst_beats` counter-pattern beats over peer_send[0]
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
        if (tx_running && axis_peer_send[0].tready) begin
            tx_beat_idx <= tx_beat_idx + 1;
            if (tx_beat_idx + 1 == tx_burst_beats) begin
                tx_running <= 1'b0;
                tx_done    <= 1'b1;
            end
        end
        if (!tx_start) tx_done <= 1'b0;  // edge-triggered restart
    end
end

assign axis_peer_send[0].tvalid = tx_running && peer_up;
assign axis_peer_send[0].tdata  = {4{tx_beat_idx}};  // 256 bits = 4 copies of beat idx
assign axis_peer_send[0].tkeep  = '1;
assign axis_peer_send[0].tlast  = tx_running && (tx_beat_idx + 1 == tx_burst_beats);
assign axis_peer_send[0].tid    = '0;

// =========================================================================
// RX path: count beats from peer_recv[0], check pattern, count mismatches
// =========================================================================
logic [63:0] rx_beat_cnt;
logic [63:0] rx_mismatches;
logic        rx_done;

always_ff @(posedge aclk) begin
    if (!aresetn || !rx_arm) begin
        rx_beat_cnt   <= '0;
        rx_mismatches <= '0;
        rx_done       <= 1'b0;
    end else if (axis_peer_recv[0].tvalid && axis_peer_recv[0].tready) begin
        rx_beat_cnt <= rx_beat_cnt + 1;
        // Each beat should be {4{rx_beat_cnt}}; mismatch increments counter.
        if (axis_peer_recv[0].tdata != {4{rx_beat_cnt}}) begin
            rx_mismatches <= rx_mismatches + 1;
        end
        if (axis_peer_recv[0].tlast) rx_done <= 1'b1;
    end
end

assign axis_peer_recv[0].tready = rx_arm;

always_comb begin
    status_reg = {57'b0, peer_lanes, peer_up, rx_done, tx_done};
    unique case (ar_addr_q[REG_ADDR_BITS-1:ADDR_LSB])
        1: read_data = status_reg;
        3: read_data = rx_beat_cnt;
        4: read_data = rx_mismatches;
        default: read_data = csr[ar_addr_q[REG_ADDR_BITS-1:ADDR_LSB]];
    endcase
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
