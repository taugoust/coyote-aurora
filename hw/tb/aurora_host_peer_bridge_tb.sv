`timescale 1ns / 1ps

module aurora_host_peer_bridge_tb;
    logic clk;
    logic resetn;
    logic link_up;

    logic [31:0] host_in_data;
    logic [3:0] host_in_keep;
    logic host_in_last;
    logic host_in_valid;
    logic host_in_ready;
    logic [31:0] host_out_data;
    logic [3:0] host_out_keep;
    logic host_out_last;
    logic host_out_valid;
    logic host_out_ready;

    logic [31:0] peer_in_data;
    logic [3:0] peer_in_keep;
    logic peer_in_last;
    logic peer_in_valid;
    logic peer_in_ready;
    logic [31:0] peer_out_data;
    logic [3:0] peer_out_keep;
    logic peer_out_last;
    logic peer_out_valid;
    logic peer_out_ready;

    aurora_host_peer_bridge #(.DATA_W(32)) dut (
        .aclk(clk),
        .aresetn(resetn),
        .link_up(link_up),
        .s_host_tdata(host_in_data),
        .s_host_tkeep(host_in_keep),
        .s_host_tlast(host_in_last),
        .s_host_tvalid(host_in_valid),
        .s_host_tready(host_in_ready),
        .m_host_tdata(host_out_data),
        .m_host_tkeep(host_out_keep),
        .m_host_tlast(host_out_last),
        .m_host_tvalid(host_out_valid),
        .m_host_tready(host_out_ready),
        .s_peer_tdata(peer_in_data),
        .s_peer_tkeep(peer_in_keep),
        .s_peer_tlast(peer_in_last),
        .s_peer_tvalid(peer_in_valid),
        .s_peer_tready(peer_in_ready),
        .m_peer_tdata(peer_out_data),
        .m_peer_tkeep(peer_out_keep),
        .m_peer_tlast(peer_out_last),
        .m_peer_tvalid(peer_out_valid),
        .m_peer_tready(peer_out_ready)
    );

    task automatic fail(input string message);
        $error("FAIL: %s", message);
        $fatal(1);
    endtask

    initial begin
        clk = 1'b0;
        forever #5 clk = !clk;
    end

    initial begin
        resetn = 1'b0;
        link_up = 1'b0;
        host_in_data = '0;
        host_in_keep = '0;
        host_in_last = 1'b0;
        host_in_valid = 1'b0;
        host_out_ready = 1'b0;
        peer_in_data = '0;
        peer_in_keep = '0;
        peer_in_last = 1'b0;
        peer_in_valid = 1'b0;
        peer_out_ready = 1'b0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        resetn = 1'b1;

        // No transport boundary may accept or publish traffic while Aurora is
        // down, even if both producers are presenting records.
        host_in_valid = 1'b1;
        peer_in_valid = 1'b1;
        repeat (3) begin
            @(posedge clk);
            if (host_in_ready || peer_in_ready || host_out_valid || peer_out_valid)
                fail("bridge exposed traffic while the peer link was down");
        end

        @(negedge clk);
        link_up = 1'b1;
        host_in_data = 32'h5153_4832;
        host_in_keep = 4'b1111;
        host_in_last = 1'b1;
        peer_in_data = 32'hdead_beef;
        peer_in_keep = 4'b0011;
        peer_in_last = 1'b1;

        // Accept both directions into independent registered queues while both
        // destinations are stalled.
        do @(posedge clk); while (!host_in_ready || !peer_in_ready);
        @(negedge clk);
        host_in_valid = 1'b0;
        peer_in_valid = 1'b0;
        repeat (3) begin
            @(posedge clk);
            if (!peer_out_valid || peer_out_data != 32'h5153_4832 ||
                peer_out_keep != 4'b1111 || !peer_out_last)
                fail("host-to-peer record changed under backpressure");
            if (!host_out_valid || host_out_data != 32'hdead_beef ||
                host_out_keep != 4'b0011 || !host_out_last)
                fail("peer-to-host record changed under backpressure");
        end

        @(negedge clk);
        host_out_ready = 1'b1;
        peer_out_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        if (host_out_valid || peer_out_valid)
            fail("completed records remained visible");

        // A complete peer record that crossed the Aurora boundary remains a
        // valid host transfer across link loss; retracting TVALID while the
        // host is stalled would violate AXI-stream.
        host_out_ready = 1'b0;
        peer_in_data = 32'habad_1dea;
        peer_in_keep = 4'b1111;
        peer_in_last = 1'b1;
        peer_in_valid = 1'b1;
        do @(posedge clk); while (!peer_in_ready);
        @(negedge clk);
        peer_in_valid = 1'b0;
        link_up = 1'b0;
        repeat (3) begin
            @(posedge clk);
            if (!host_out_valid || host_out_data != 32'habad_1dea ||
                host_out_keep != 4'b1111 || !host_out_last)
                fail("completed peer record was retracted after link loss");
        end
        @(negedge clk);
        host_out_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        if (host_out_valid)
            fail("completed peer record remained after host acceptance");

        $display("PASS: Aurora host/peer bridge preserves both directions, backpressure, and link epochs");
        $finish;
    end

    initial begin
        #100000;
        fail("testbench timeout");
    end
endmodule
