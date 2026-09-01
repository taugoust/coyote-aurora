`timescale 1ns / 1ps

// Bidirectional bridge between one Coyote host stream and one physical peer
// stream. Each direction crosses a two-entry queue, so neither downstream
// ready signal reaches the opposite transport boundary combinationally. This
// initial bridge accepts only complete one-beat records, matching QSH2 d3.
module aurora_host_peer_bridge #(
    parameter int DATA_W = 512,
    parameter int KEEP_W = DATA_W / 8
) (
    input  logic              aclk,
    input  logic              aresetn,
    input  logic              link_up,

    input  logic [DATA_W-1:0] s_host_tdata,
    input  logic [KEEP_W-1:0] s_host_tkeep,
    input  logic              s_host_tlast,
    input  logic              s_host_tvalid,
    output logic              s_host_tready,

    output logic [DATA_W-1:0] m_host_tdata,
    output logic [KEEP_W-1:0] m_host_tkeep,
    output logic              m_host_tlast,
    output logic              m_host_tvalid,
    input  logic              m_host_tready,

    input  logic [DATA_W-1:0] s_peer_tdata,
    input  logic [KEEP_W-1:0] s_peer_tkeep,
    input  logic              s_peer_tlast,
    input  logic              s_peer_tvalid,
    output logic              s_peer_tready,

    output logic [DATA_W-1:0] m_peer_tdata,
    output logic [KEEP_W-1:0] m_peer_tkeep,
    output logic              m_peer_tlast,
    output logic              m_peer_tvalid,
    input  logic              m_peer_tready
);
    logic host_source_ready;
    logic host_to_peer_valid;
    logic host_to_peer_ready;
    logic peer_to_host_ready;

    axis_stream_fifo_2 #(
        .DATA_W(DATA_W),
        .KEEP_W(KEEP_W)
    ) inst_host_to_peer_queue (
        .aclk(aclk),
        .aresetn(aresetn),
        .flush(!link_up),
        .s_tdata(s_host_tdata),
        .s_tkeep(s_host_tkeep),
        .s_tlast(s_host_tlast),
        .s_tvalid(s_host_tvalid && s_host_tlast),
        .s_tready(host_source_ready),
        .m_tdata(m_peer_tdata),
        .m_tkeep(m_peer_tkeep),
        .m_tlast(m_peer_tlast),
        .m_tvalid(host_to_peer_valid),
        .m_tready(host_to_peer_ready)
    );

    assign m_peer_tvalid = link_up && host_to_peer_valid;
    assign host_to_peer_ready = link_up && m_peer_tready;

    axis_stream_fifo_2 #(
        .DATA_W(DATA_W),
        .KEEP_W(KEEP_W)
    ) inst_peer_to_host_queue (
        .aclk(aclk),
        .aresetn(aresetn),
        // A complete peer beat that crossed the transport boundary remains a
        // valid host-side transfer even if the link drops while the host is
        // stalled. Never retract it without an AXI handshake.
        .flush(1'b0),
        .s_tdata(s_peer_tdata),
        .s_tkeep(s_peer_tkeep),
        .s_tlast(s_peer_tlast),
        .s_tvalid(link_up && s_peer_tvalid && s_peer_tlast),
        .s_tready(peer_to_host_ready),
        .m_tdata(m_host_tdata),
        .m_tkeep(m_host_tkeep),
        .m_tlast(m_host_tlast),
        .m_tvalid(m_host_tvalid),
        .m_tready(m_host_tready)
    );

    assign s_host_tready = link_up && s_host_tlast && host_source_ready;
    assign s_peer_tready = link_up && s_peer_tlast && peer_to_host_ready;

`ifndef SYNTHESIS
    always_ff @(posedge aclk) begin
        if (aresetn && link_up) begin
            if (s_host_tvalid)
                assert (s_host_tlast);
            if (s_peer_tvalid)
                assert (s_peer_tlast);
        end
    end
`endif
endmodule
