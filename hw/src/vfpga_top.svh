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
logic [REG_ADDR_BITS-1:0] aw_addr_q;
logic [63:0]              w_data_q;
logic                     aw_seen, w_seen;
logic                     bvalid_q, rvalid_q;
logic [63:0]              rdata_q;

function automatic logic [63:0] csr_read_value(input logic [ADDR_MSB-1:0] idx);
    unique case (idx)
        1: csr_read_value = status_reg;
        3: csr_read_value = rx_beat_cnt;
        4: csr_read_value = rx_mismatches;
        default: csr_read_value = csr[idx];
    endcase
endfunction

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        aw_seen  <= 1'b0;
        w_seen   <= 1'b0;
        bvalid_q <= 1'b0;
        rvalid_q <= 1'b0;
        rdata_q  <= '0;
        for (int i = 0; i < N_REGS; i++) csr[i] <= '0;
    end else begin
        if (axi_ctrl.awvalid && axi_ctrl.awready) begin
            aw_addr_q <= axi_ctrl.awaddr[REG_ADDR_BITS-1:0];
            aw_seen   <= 1'b1;
        end

        if (axi_ctrl.wvalid && axi_ctrl.wready) begin
            w_data_q <= axi_ctrl.wdata;
            w_seen   <= 1'b1;
        end

        if (aw_seen && w_seen && !bvalid_q) begin
            if (aw_addr_q[REG_ADDR_BITS-1:ADDR_LSB] != 1
                && aw_addr_q[REG_ADDR_BITS-1:ADDR_LSB] != 3
                && aw_addr_q[REG_ADDR_BITS-1:ADDR_LSB] != 4) begin
                csr[aw_addr_q[REG_ADDR_BITS-1:ADDR_LSB]] <= w_data_q;
            end
            aw_seen  <= 1'b0;
            w_seen   <= 1'b0;
            bvalid_q <= 1'b1;
        end else if (bvalid_q && axi_ctrl.bready) begin
            bvalid_q <= 1'b0;
        end

        if (axi_ctrl.arvalid && axi_ctrl.arready) begin
            rdata_q  <= csr_read_value(axi_ctrl.araddr[REG_ADDR_BITS-1:ADDR_LSB]);
            rvalid_q <= 1'b1;
        end else if (rvalid_q && axi_ctrl.rready) begin
            rvalid_q <= 1'b0;
        end
    end
end

assign axi_ctrl.awready = !aw_seen && !bvalid_q;
assign axi_ctrl.wready  = !w_seen && !bvalid_q;
assign axi_ctrl.bvalid  = bvalid_q;
assign axi_ctrl.bresp   = 2'b00;
assign axi_ctrl.arready = !rvalid_q;
assign axi_ctrl.rvalid  = rvalid_q;
assign axi_ctrl.rdata   = rdata_q;
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
assign axis_peer_send[0].tdata  = {AXI_DATA_BITS/64{tx_beat_idx}};
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
        // Each beat should repeat the expected 64-bit beat index across tdata.
        if (axis_peer_recv[0].tdata != {AXI_DATA_BITS/64{rx_beat_cnt}}) begin
            rx_mismatches <= rx_mismatches + 1;
        end
        if (axis_peer_recv[0].tlast) rx_done <= 1'b1;
    end
end

assign axis_peer_recv[0].tready = rx_arm;

always_comb begin
    status_reg = {57'b0, peer_lanes, peer_up, rx_done, tx_done};
    read_data = '0;
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
