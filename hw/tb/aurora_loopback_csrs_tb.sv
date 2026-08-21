`timescale 1ns / 1ps

module aurora_loopback_csrs_tb;

logic clk;
logic resetn = 1'b0;

logic [2:0]  awindex;
logic        awvalid;
logic        awready;
logic [63:0] wdata;
logic [7:0]  wstrb;
logic        wvalid;
logic        wready;
logic [1:0]  bresp;
logic        bvalid;
logic        bready;
logic [2:0]  arindex;
logic        arvalid;
logic        arready;
logic [63:0] rdata;
logic [1:0]  rresp;
logic        rvalid;
logic        rready;

logic [63:0] ctrl;
logic [63:0] tx_burst_beats;
logic [63:0] status;
logic [63:0] rx_beat_count;
logic [63:0] rx_mismatch_count;
logic [63:0] tx_beat_count;
logic        tx_running;

initial begin
    clk = 1'b0;
    forever #5 clk = !clk;
end

aurora_loopback_csrs dut (
    .aclk(clk),
    .aresetn(resetn),
    .s_axi_awindex(awindex),
    .s_axi_awvalid(awvalid),
    .s_axi_awready(awready),
    .s_axi_wdata(wdata),
    .s_axi_wstrb(wstrb),
    .s_axi_wvalid(wvalid),
    .s_axi_wready(wready),
    .s_axi_bresp(bresp),
    .s_axi_bvalid(bvalid),
    .s_axi_bready(bready),
    .s_axi_arindex(arindex),
    .s_axi_arvalid(arvalid),
    .s_axi_arready(arready),
    .s_axi_rdata(rdata),
    .s_axi_rresp(rresp),
    .s_axi_rvalid(rvalid),
    .s_axi_rready(rready),
    .ctrl(ctrl),
    .tx_burst_beats(tx_burst_beats),
    .status(status),
    .rx_beat_count(rx_beat_count),
    .rx_mismatch_count(rx_mismatch_count),
    .tx_beat_count(tx_beat_count),
    .tx_running(tx_running)
);

function automatic logic [63:0] merged_value(
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

task automatic fail(input string message);
    $error("FAIL: %s", message);
    $fatal(1);
endtask

task automatic axi_write(
    input logic [63:0] address,
    input logic [63:0] data,
    input logic [7:0] byte_enable,
    input int aw_delay,
    input int w_delay,
    input int response_delay
);
    int cycle;
    logic aw_done;
    logic w_done;

    cycle = 0;
    aw_done = 1'b0;
    w_done = 1'b0;
    while (!aw_done || !w_done) begin
        @(negedge clk);
        if (aw_done) begin
            awvalid = 1'b0;
        end else if (cycle >= aw_delay) begin
            if (address[63:6] != 0 || address[2:0] != 0) begin
                fail("write address is outside or unaligned to the CSR window");
            end
            awindex = address[5:3];
            awvalid = 1'b1;
        end
        if (w_done) begin
            wvalid = 1'b0;
        end else if (cycle >= w_delay) begin
            wdata = data;
            wstrb = byte_enable;
            wvalid = 1'b1;
        end
        @(posedge clk);
        if (awvalid && awready) aw_done = 1'b1;
        if (wvalid && wready) w_done = 1'b1;
        cycle++;
    end
    @(negedge clk);
    awvalid = 1'b0;
    wvalid = 1'b0;

    while (!bvalid) @(posedge clk);
    if (bresp != 2'b00) fail("write returned a non-OKAY response");
    repeat (response_delay) begin
        @(posedge clk);
        if (!bvalid || bresp != 2'b00) begin
            fail("write response changed while BREADY was low");
        end
    end
    @(negedge clk);
    bready = 1'b1;
    do @(posedge clk); while (!bvalid);
    @(negedge clk);
    bready = 1'b0;
endtask

task automatic axi_read(
    input logic [63:0] address,
    input int response_delay,
    output logic [63:0] data
);
    logic [63:0] held_data;

    @(negedge clk);
    if (address[63:6] != 0 || address[2:0] != 0) begin
        fail("read address is outside or unaligned to the CSR window");
    end
    arindex = address[5:3];
    arvalid = 1'b1;
    do @(posedge clk); while (!arready);
    @(negedge clk);
    arvalid = 1'b0;

    while (!rvalid) @(posedge clk);
    held_data = rdata;
    if (rresp != 2'b00) fail("read returned a non-OKAY response");
    repeat (response_delay) begin
        @(posedge clk);
        if (!rvalid || rresp != 2'b00 || rdata != held_data) begin
            fail("read response changed while RREADY was low");
        end
    end
    data = held_data;
    @(negedge clk);
    rready = 1'b1;
    do @(posedge clk); while (!rvalid);
    @(negedge clk);
    rready = 1'b0;
endtask

task automatic expect_read(
    input logic [63:0] address,
    input logic [63:0] expected,
    input string name
);
    logic [63:0] observed;
    axi_read(address, 2, observed);
    if (observed != expected) begin
        $error("FAIL: %s read 0x%016x, expected 0x%016x", name, observed, expected);
        $fatal(1);
    end
endtask

initial begin
    logic [63:0] expected;
    logic [63:0] update;
    logic [7:0] enables;

    awindex = '0;
    awvalid = 1'b0;
    wdata = '0;
    wstrb = '0;
    wvalid = 1'b0;
    bready = 1'b0;
    arindex = '0;
    arvalid = 1'b0;
    rready = 1'b0;
    status = 64'h0000_0000_0000_007c;
    rx_beat_count = 64'h1234;
    rx_mismatch_count = 64'h5678;
    tx_beat_count = 64'h9abc;
    tx_running = 1'b1;

    repeat (4) @(posedge clk);
    @(negedge clk);
    resetn = 1'b1;

    // Program the burst count, then model the eight 64-bit AXI-Lite writes
    // produced when the 512-bit host path is narrowed. Only lane zero carries
    // byte enables; zero-strobe lanes must not alter adjacent CSRs.
    axi_write(64'h10, 64'd1024, 8'hff, 0, 2, 3);
    for (int lane = 0; lane < 8; lane++) begin
        axi_write(
            lane * 8,
            lane == 0 ? 64'h1 : 64'h0,
            lane == 0 ? 8'hff : 8'h00,
            lane % 3,
            (lane + 1) % 3,
            lane % 2
        );
    end
    expect_read(64'h00, 64'h1, "CTRL after narrowed host write");
    expect_read(64'h10, 64'd1024, "TX_BURST after narrowed host write");
    if (ctrl != 64'h1 || tx_burst_beats != 64'd1024) begin
        fail("register outputs do not match their AXI readback");
    end

    // Byte enables merge partial writes rather than exposing undefined data
    // from inactive lanes.
    expected = 64'h1122_3344_5566_7788;
    axi_write(64'h10, expected, 8'hff, 2, 0, 1);
    update = 64'hffee_ddcc_bbaa_0099;
    enables = 8'b0010_0101;
    expected = merged_value(expected, update, enables);
    axi_write(64'h10, update, enables, 0, 3, 4);
    expect_read(64'h10, expected, "partial TX_BURST write");

    // Exercise independent AW/W ordering repeatedly and prove that a
    // zero-strobe transaction never changes the programmed value. The varied
    // values and delays are deterministic so the Nix check is reproducible.
    for (int iteration = 0; iteration < 32; iteration++) begin
        expected = {
            32'h9e37_79b9 * (iteration + 1),
            32'h85eb_ca6b ^ (32'(iteration) * 32'hc2b2_ae35)
        };
        update = ~expected ^ 64'hd6e8_feb8_6659_fd93;
        axi_write(64'h10, expected, 8'hff, iteration % 5, (iteration * 3 + 1) % 5, 0);
        axi_write(64'h10, update, 8'h00,
                  (iteration * 2 + 3) % 5, (iteration * 4 + 2) % 5, iteration % 3);
        expect_read(64'h10, expected, "varied zero-strobe preservation");
    end

    // Writes to status/counter slots are acknowledged but ignored.
    axi_write(64'h08, 64'hffff_ffff_ffff_ffff, 8'hff, 0, 0, 0);
    axi_write(64'h18, 64'hffff_ffff_ffff_ffff, 8'hff, 1, 0, 0);
    axi_write(64'h20, 64'hffff_ffff_ffff_ffff, 8'hff, 0, 1, 0);
    axi_write(64'h28, 64'hffff_ffff_ffff_ffff, 8'hff, 1, 2, 0);
    axi_write(64'h30, 64'hffff_ffff_ffff_ffff, 8'hff, 2, 1, 0);
    expect_read(64'h08, status, "STATUS");
    expect_read(64'h18, rx_beat_count, "RX_BEAT_CNT");
    expect_read(64'h20, rx_mismatch_count, "RX_MISMATCHES");
    expect_read(64'h28, tx_beat_count, "TX_BEAT_CNT");
    expect_read(64'h30, 64'h1, "TX_RUNNING");

    $display("PASS: Aurora AXI-Lite CSR writes honor WSTRB and preserve adjacent registers");
    $finish;
end

initial begin
    #200000;
    fail("testbench timeout");
end

endmodule
