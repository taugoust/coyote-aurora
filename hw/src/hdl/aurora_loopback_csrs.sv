`timescale 1ns / 1ps

module aurora_loopback_csrs (
    input  logic                  aclk,
    input  logic                  aresetn,

    input  logic [2:0]            s_axi_awindex,
    input  logic                  s_axi_awvalid,
    output logic                  s_axi_awready,
    input  logic [63:0]           s_axi_wdata,
    input  logic [7:0]            s_axi_wstrb,
    input  logic                  s_axi_wvalid,
    output logic                  s_axi_wready,
    output logic [1:0]            s_axi_bresp,
    output logic                  s_axi_bvalid,
    input  logic                  s_axi_bready,

    input  logic [2:0]            s_axi_arindex,
    input  logic                  s_axi_arvalid,
    output logic                  s_axi_arready,
    output logic [63:0]           s_axi_rdata,
    output logic [1:0]            s_axi_rresp,
    output logic                  s_axi_rvalid,
    input  logic                  s_axi_rready,

    output logic [63:0]           ctrl,
    output logic [63:0]           tx_burst_beats,
    input  logic [63:0]           status,
    input  logic [63:0]           rx_beat_count,
    input  logic [63:0]           rx_mismatch_count,
    input  logic [63:0]           tx_beat_count,
    input  logic                  tx_running
);

localparam int REG_INDEX_WIDTH = 3;

localparam logic [REG_INDEX_WIDTH-1:0] REG_CTRL = 0;
localparam logic [REG_INDEX_WIDTH-1:0] REG_STATUS = 1;
localparam logic [REG_INDEX_WIDTH-1:0] REG_TX_BURST = 2;
localparam logic [REG_INDEX_WIDTH-1:0] REG_RX_BEATS = 3;
localparam logic [REG_INDEX_WIDTH-1:0] REG_RX_MISMATCH = 4;
localparam logic [REG_INDEX_WIDTH-1:0] REG_TX_BEATS = 5;
localparam logic [REG_INDEX_WIDTH-1:0] REG_TX_RUNNING = 6;

logic [REG_INDEX_WIDTH-1:0] awindex_q;
logic [63:0]                  wdata_q;
logic [7:0]                   wstrb_q;
logic                         aw_pending;
logic                         w_pending;
logic                         bvalid_q;
logic [63:0]                  rdata_q;
logic                         rvalid_q;

wire aw_fire = s_axi_awvalid && s_axi_awready;
wire w_fire = s_axi_wvalid && s_axi_wready;
wire [REG_INDEX_WIDTH-1:0] write_index = awindex_q;
wire [REG_INDEX_WIDTH-1:0] read_index = s_axi_arindex;

function automatic logic [63:0] merge_write(
    input logic [63:0] previous,
    input logic [63:0] next,
    input logic [7:0] byte_enable
);
    logic [63:0] result;
    result = previous;
    for (int i = 0; i < 8; i++) begin
        if (byte_enable[i]) begin
            result[i * 8 +: 8] = next[i * 8 +: 8];
        end
    end
    return result;
endfunction

function automatic logic [63:0] read_value(
    input logic [REG_INDEX_WIDTH-1:0] index
);
    unique case (index)
        REG_CTRL:        read_value = ctrl;
        REG_STATUS:      read_value = status;
        REG_TX_BURST:    read_value = tx_burst_beats;
        REG_RX_BEATS:    read_value = rx_beat_count;
        REG_RX_MISMATCH: read_value = rx_mismatch_count;
        REG_TX_BEATS:    read_value = tx_beat_count;
        REG_TX_RUNNING:  read_value = {63'b0, tx_running};
        default:         read_value = 64'b0;
    endcase
endfunction

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        awindex_q     <= '0;
        wdata_q       <= '0;
        wstrb_q       <= '0;
        aw_pending    <= 1'b0;
        w_pending     <= 1'b0;
        bvalid_q      <= 1'b0;
        rdata_q       <= '0;
        rvalid_q      <= 1'b0;
        ctrl           <= '0;
        tx_burst_beats <= '0;
    end else begin
        if (aw_fire) begin
            awindex_q  <= s_axi_awindex;
            aw_pending <= 1'b1;
        end

        if (w_fire) begin
            wdata_q   <= s_axi_wdata;
            wstrb_q   <= s_axi_wstrb;
            w_pending <= 1'b1;
        end

        if (aw_pending && w_pending && !bvalid_q) begin
            // The 512-to-64-bit host width converter can emit transactions for
            // inactive lanes with WSTRB=0. They are acknowledged, but merging
            // by byte enable ensures they cannot corrupt adjacent registers.
            unique case (write_index)
                REG_CTRL: begin
                    ctrl <= merge_write(ctrl, wdata_q, wstrb_q);
                end
                REG_TX_BURST: begin
                    tx_burst_beats <= merge_write(tx_burst_beats, wdata_q, wstrb_q);
                end
                default: begin
                    // Read-only and reserved registers ignore writes.
                end
            endcase
            aw_pending <= 1'b0;
            w_pending  <= 1'b0;
            bvalid_q   <= 1'b1;
        end else if (bvalid_q && s_axi_bready) begin
            bvalid_q <= 1'b0;
        end

        if (s_axi_arvalid && s_axi_arready) begin
            rdata_q  <= read_value(read_index);
            rvalid_q <= 1'b1;
        end else if (rvalid_q && s_axi_rready) begin
            rvalid_q <= 1'b0;
        end
    end
end

assign s_axi_awready = !aw_pending && !bvalid_q;
assign s_axi_wready = !w_pending && !bvalid_q;
assign s_axi_bresp = 2'b00;
assign s_axi_bvalid = bvalid_q;
assign s_axi_arready = !rvalid_q;
assign s_axi_rdata = rdata_q;
assign s_axi_rresp = 2'b00;
assign s_axi_rvalid = rvalid_q;

endmodule
