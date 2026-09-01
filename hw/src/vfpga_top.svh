/**
 * Clara-side host/Aurora bridge for QShell peer-path validation.
 *
 *   axis_host_recv[0] -> registered queue -> axis_peer_send[0]
 *   axis_peer_recv[0] -> registered queue -> axis_host_send[0]
 *
 * The queues preserve data, keep, and record boundaries while preventing a
 * combinational ready path between PCIe host streams and the Aurora backend.
 * This initial bridge accepts complete one-beat records only. Link loss drops
 * queued host requests but never retracts a complete response already offered
 * to the host. The QSH2 d3 workload uses one beat per record.
 */

logic [63:0] ctrl_reg;
logic [63:0] tx_burst_beats;
logic [63:0] peer_tx_beat_count;
logic [63:0] peer_rx_beat_count;
logic [63:0] rx_mismatches;
logic        peer_tx_active;

wire peer_up = peer_link_up[0];
wire [3:0] peer_lanes = peer_lane_up[3:0];
wire [63:0] status_reg = {57'b0, peer_lanes, peer_up, 2'b00};
wire peer_tx_fire = axis_peer_send[0].tvalid && axis_peer_send[0].tready;
wire peer_rx_fire = axis_peer_recv[0].tvalid && axis_peer_recv[0].tready;

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
    .rx_beat_count(peer_rx_beat_count),
    .rx_mismatch_count(rx_mismatches),
    .tx_beat_count(peer_tx_beat_count),
    .tx_running(peer_tx_active)
);

aurora_host_peer_bridge #(.DATA_W(AXI_DATA_BITS)) inst_host_peer_bridge (
    .aclk(aclk),
    .aresetn(aresetn[0]),
    .link_up(peer_up),
    .s_host_tdata(axis_host_recv[0].tdata),
    .s_host_tkeep(axis_host_recv[0].tkeep),
    .s_host_tlast(axis_host_recv[0].tlast),
    .s_host_tvalid(axis_host_recv[0].tvalid),
    .s_host_tready(axis_host_recv[0].tready),
    .m_host_tdata(axis_host_send[0].tdata),
    .m_host_tkeep(axis_host_send[0].tkeep),
    .m_host_tlast(axis_host_send[0].tlast),
    .m_host_tvalid(axis_host_send[0].tvalid),
    .m_host_tready(axis_host_send[0].tready),
    .s_peer_tdata(axis_peer_recv[0].tdata),
    .s_peer_tkeep(axis_peer_recv[0].tkeep),
    .s_peer_tlast(axis_peer_recv[0].tlast),
    .s_peer_tvalid(axis_peer_recv[0].tvalid),
    .s_peer_tready(axis_peer_recv[0].tready),
    .m_peer_tdata(axis_peer_send[0].tdata),
    .m_peer_tkeep(axis_peer_send[0].tkeep),
    .m_peer_tlast(axis_peer_send[0].tlast),
    .m_peer_tvalid(axis_peer_send[0].tvalid),
    .m_peer_tready(axis_peer_send[0].tready)
);

assign axis_peer_send[0].tid = '0;
assign axis_host_send[0].tid = '0;
assign peer_tx_active = axis_peer_send[0].tvalid;

always_ff @(posedge aclk) begin
    if (!aresetn[0]) begin
        peer_tx_beat_count <= '0;
        peer_rx_beat_count <= '0;
        rx_mismatches <= '0;
    end else begin
        if (peer_tx_fire)
            peer_tx_beat_count <= peer_tx_beat_count + 1'b1;
        if (peer_rx_fire)
            peer_rx_beat_count <= peer_rx_beat_count + 1'b1;
    end
end

always_comb notify.tie_off_m();
always_comb sq_rd.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb cq_wr.tie_off_s();
