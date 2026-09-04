`timescale 1ns / 1ps

// Bidirectional bridge between one Coyote host stream and one physical peer
// stream. Each direction buffers two complete records, preserving opaque whole
// vectors and record order while isolating both downstream ready paths. Partial
// records are never exposed across a transport epoch.
module aurora_host_peer_bridge #(
    parameter int DATA_W = 512,
    parameter int KEEP_W = DATA_W / 8,
    parameter int MAX_PAYLOAD_BYTES = 4096
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
    logic host_queue_ready;
    logic host_to_peer_valid;
    logic host_to_peer_ready;
    logic peer_queue_ready;
    logic host_record_active;
    logic host_discard_remainder;
    logic host_drop;
    logic host_input_fire;

    // If an epoch ends after a host record has started, consume its remainder
    // without forwarding it. This lets the host DMA finish while ensuring that
    // a continuation from the old epoch can never become a new record prefix.
    assign host_drop = host_discard_remainder ||
                       (!link_up && host_record_active);
    assign s_host_tready = host_drop ? 1'b1 :
                           (link_up && host_queue_ready);
    assign host_input_fire = s_host_tvalid && s_host_tready;

    axis_record_fifo_2 #(
        .DATA_W(DATA_W),
        .KEEP_W(KEEP_W),
        .MAX_PAYLOAD_BYTES(MAX_PAYLOAD_BYTES)
    ) inst_host_to_peer_queue (
        .aclk(aclk),
        .aresetn(aresetn),
        // No request accepted before or during a failed transport epoch may
        // escape after reconnect, including a complete locally queued record.
        .flush(!link_up),
        .abort_partial(1'b0),
        .s_tdata(s_host_tdata),
        .s_tkeep(s_host_tkeep),
        .s_tlast(s_host_tlast),
        .s_tvalid(s_host_tvalid && link_up && !host_drop),
        .s_tready(host_queue_ready),
        .m_tdata(m_peer_tdata),
        .m_tkeep(m_peer_tkeep),
        .m_tlast(m_peer_tlast),
        .m_tvalid(host_to_peer_valid),
        .m_tready(host_to_peer_ready)
    );

    assign m_peer_tvalid = link_up && host_to_peer_valid;
    assign host_to_peer_ready = link_up && m_peer_tready;

    axis_record_fifo_2 #(
        .DATA_W(DATA_W),
        .KEEP_W(KEEP_W),
        .MAX_PAYLOAD_BYTES(MAX_PAYLOAD_BYTES)
    ) inst_peer_to_host_queue (
        .aclk(aclk),
        .aresetn(aresetn),
        .flush(1'b0),
        // A complete peer record that crossed the transport boundary remains
        // valid even if the host is stalled when the link drops. Only an
        // incomplete capture is private and safe to discard at the boundary.
        .abort_partial(!link_up),
        .s_tdata(s_peer_tdata),
        .s_tkeep(s_peer_tkeep),
        .s_tlast(s_peer_tlast),
        .s_tvalid(link_up && s_peer_tvalid),
        .s_tready(peer_queue_ready),
        .m_tdata(m_host_tdata),
        .m_tkeep(m_host_tkeep),
        .m_tlast(m_host_tlast),
        .m_tvalid(m_host_tvalid),
        .m_tready(m_host_tready)
    );

    assign s_peer_tready = link_up && peer_queue_ready;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            host_record_active <= 1'b0;
            host_discard_remainder <= 1'b0;
        end else if (host_drop) begin
            host_record_active <= 1'b1;
            host_discard_remainder <= 1'b1;
            if (host_input_fire && s_host_tlast) begin
                host_record_active <= 1'b0;
                host_discard_remainder <= 1'b0;
            end
        end else if (host_input_fire) begin
            host_record_active <= !s_host_tlast;
        end
    end
endmodule
