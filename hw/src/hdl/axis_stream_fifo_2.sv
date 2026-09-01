`timescale 1ns / 1ps

// Two-entry AXI-stream queue with no combinational ready path between its
// source and destination. Payload storage is intentionally not reset: zero
// occupancy makes stale contents unreachable.
module axis_stream_fifo_2 #(
    parameter int DATA_W = 512,
    parameter int KEEP_W = DATA_W / 8
) (
    input  logic              aclk,
    input  logic              aresetn,
    input  logic              flush,
    input  logic [DATA_W-1:0] s_tdata,
    input  logic [KEEP_W-1:0] s_tkeep,
    input  logic              s_tlast,
    input  logic              s_tvalid,
    output logic              s_tready,
    output logic [DATA_W-1:0] m_tdata,
    output logic [KEEP_W-1:0] m_tkeep,
    output logic              m_tlast,
    output logic              m_tvalid,
    input  logic              m_tready
);
    logic [1:0] count;
    logic read_pointer;
    logic write_pointer;
    logic [DATA_W-1:0] data_slot0;
    logic [DATA_W-1:0] data_slot1;
    logic [KEEP_W-1:0] keep_slot0;
    logic [KEEP_W-1:0] keep_slot1;
    logic last_slot0;
    logic last_slot1;
    logic push;
    logic pop;

    always_comb begin
        if (read_pointer) begin
            m_tdata = data_slot1;
            m_tkeep = keep_slot1;
            m_tlast = last_slot1;
        end else begin
            m_tdata = data_slot0;
            m_tkeep = keep_slot0;
            m_tlast = last_slot0;
        end

        s_tready = !flush && count != 2;
        m_tvalid = !flush && count != 0;
        push = s_tvalid && s_tready;
        pop = m_tvalid && m_tready;
    end

    always_ff @(posedge aclk) begin
        if (!aresetn || flush) begin
            count <= '0;
            read_pointer <= 1'b0;
            write_pointer <= 1'b0;
        end else begin
            if (push) begin
                if (write_pointer) begin
                    data_slot1 <= s_tdata;
                    keep_slot1 <= s_tkeep;
                    last_slot1 <= s_tlast;
                end else begin
                    data_slot0 <= s_tdata;
                    keep_slot0 <= s_tkeep;
                    last_slot0 <= s_tlast;
                end
                write_pointer <= !write_pointer;
            end
            if (pop)
                read_pointer <= !read_pointer;

            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end

`ifndef SYNTHESIS
    logic stalled_previous;
    always_ff @(posedge aclk) begin
        if (!aresetn || flush) begin
            stalled_previous <= 1'b0;
        end else begin
            if (stalled_previous) begin
                assert (m_tvalid);
                assert ($stable(m_tdata));
                assert ($stable(m_tkeep));
                assert ($stable(m_tlast));
            end
            stalled_previous <= m_tvalid && !m_tready;
        end
    end
`endif

    initial begin
        if (DATA_W <= 0 || KEEP_W <= 0 || KEEP_W * 8 != DATA_W)
            $fatal(1, "axis_stream_fifo_2 requires byte-aligned data");
    end
endmodule
