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
 *   reg[2]  TX_BURST_BEATS: number of AXI_DATA_BITS-wide beats to send
 *   reg[3]  RX_BEAT_CNT   : observed RX beat count
 *   reg[4]  RX_MISMATCHES : count of beats where expected pattern != received
 *   reg[5]  TX_BEAT_CNT   : transmitted peer-send beat count (read-only debug)
 *   reg[6]  TX_RUNNING    : TX FSM running flag (read-only debug)
 */

// =========================================================================
// Control / status registers parsed off axi_ctrl
// =========================================================================
logic [63:0] ctrl_reg;
logic [63:0] tx_burst_beats;
logic [63:0] tx_beat_idx;
logic [63:0] rx_beat_cnt;
logic [63:0] rx_mismatches;
logic        tx_running;
logic        tx_done;
logic        rx_done;

wire tx_start = ctrl_reg[0];
wire rx_arm = ctrl_reg[1];
wire peer_up = peer_link_up[0];
wire [3:0] peer_lanes = peer_lane_up[3:0];
wire [63:0] status_reg = {57'b0, peer_lanes, peer_up, rx_done, tx_done};

aurora_loopback_csrs inst_csrs (
    .aclk(aclk),
    .aresetn(aresetn[0]),
    .s_axi_awindex(axi_ctrl.awaddr[5:3]),
    .s_axi_awvalid(axi_ctrl.awvalid),
    .s_axi_awready(axi_ctrl.awready),
    .s_axi_wdata(axi_ctrl.wdata),
    .s_axi_wstrb(axi_ctrl.wstrb),
    .s_axi_wvalid(axi_ctrl.wvalid),
    .s_axi_wready(axi_ctrl.wready),
    .s_axi_bresp(axi_ctrl.bresp),
    .s_axi_bvalid(axi_ctrl.bvalid),
    .s_axi_bready(axi_ctrl.bready),
    .s_axi_arindex(axi_ctrl.araddr[5:3]),
    .s_axi_arvalid(axi_ctrl.arvalid),
    .s_axi_arready(axi_ctrl.arready),
    .s_axi_rdata(axi_ctrl.rdata),
    .s_axi_rresp(axi_ctrl.rresp),
    .s_axi_rvalid(axi_ctrl.rvalid),
    .s_axi_rready(axi_ctrl.rready),
    .ctrl(ctrl_reg),
    .tx_burst_beats(tx_burst_beats),
    .status(status_reg),
    .rx_beat_count(rx_beat_cnt),
    .rx_mismatch_count(rx_mismatches),
    .tx_beat_count(tx_beat_idx),
    .tx_running(tx_running)
);

// =========================================================================
// TX path: send `tx_burst_beats` counter-pattern beats over peer_send[0]
// =========================================================================
wire tx_fire = axis_peer_send[0].tvalid && axis_peer_send[0].tready;
wire tx_last_beat = tx_running && (tx_burst_beats != 0) && (tx_beat_idx == tx_burst_beats - 1);

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        tx_beat_idx <= '0;
        tx_running  <= 1'b0;
        tx_done     <= 1'b0;
    end else begin
        if (!tx_start) begin
            tx_beat_idx <= '0;
            tx_running  <= 1'b0;
            tx_done     <= 1'b0;
        end else begin
            if (!tx_running && !tx_done) begin
                tx_beat_idx <= '0;
                if (tx_burst_beats == 0) begin
                    tx_done <= 1'b1;
                end else begin
                    tx_running <= 1'b1;
                end
            end else if (tx_fire) begin
                if (tx_last_beat) begin
                    tx_beat_idx <= tx_beat_idx + 1;
                    tx_running  <= 1'b0;
                    tx_done     <= 1'b1;
                end else begin
                    tx_beat_idx <= tx_beat_idx + 1;
                end
            end
        end
    end
end

assign axis_peer_send[0].tvalid = tx_running && peer_up;
assign axis_peer_send[0].tdata  = {AXI_DATA_BITS/64{tx_beat_idx}};
assign axis_peer_send[0].tkeep  = '1;
assign axis_peer_send[0].tlast  = tx_last_beat;
assign axis_peer_send[0].tid    = '0;

// =========================================================================
// RX path: count beats from peer_recv[0], check pattern, count mismatches
// =========================================================================
always_ff @(posedge aclk) begin
    if (!aresetn || !rx_arm) begin
        rx_beat_cnt   <= '0;
        rx_mismatches <= '0;
        rx_done       <= 1'b0;
    end else if (axis_peer_recv[0].tvalid && axis_peer_recv[0].tready) begin
        rx_beat_cnt <= rx_beat_cnt + 1;
        // Each beat should repeat the expected 64-bit beat index across tdata.
        if (axis_peer_recv[0].tdata != {AXI_DATA_BITS/64{rx_beat_cnt}}) begin
            rx_mismatches <= rx_mismatches + 1;
        end
        if (axis_peer_recv[0].tlast) rx_done <= 1'b1;
    end
end

assign axis_peer_recv[0].tready = rx_arm;

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
