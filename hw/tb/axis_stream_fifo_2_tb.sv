`timescale 1ns / 1ps

module axis_stream_fifo_2_tb;
    logic clk = 1'b0;
    logic resetn = 1'b0;
    logic flush = 1'b0;
    logic [31:0] s_data;
    logic [3:0] s_keep;
    logic s_last;
    logic s_valid;
    logic s_ready;
    logic [31:0] m_data;
    logic [3:0] m_keep;
    logic m_last;
    logic m_valid;
    logic m_ready;

    typedef struct packed {
        logic [31:0] data;
        logic [3:0] keep;
        logic last;
    } beat_t;
    beat_t expected[$];
    int sent;
    int received;

    always #5 clk = !clk;

    axis_stream_fifo_2 #(.DATA_W(32)) dut (
        .aclk(clk),
        .aresetn(resetn),
        .flush(flush),
        .s_tdata(s_data),
        .s_tkeep(s_keep),
        .s_tlast(s_last),
        .s_tvalid(s_valid),
        .s_tready(s_ready),
        .m_tdata(m_data),
        .m_tkeep(m_keep),
        .m_tlast(m_last),
        .m_tvalid(m_valid),
        .m_tready(m_ready)
    );

    task automatic fail(input string message);
        $error("FAIL: %s", message);
        $fatal(1);
    endtask

    task automatic send_beat(input beat_t beat);
        s_data = beat.data;
        s_keep = beat.keep;
        s_last = beat.last;
        s_valid = 1'b1;
        do @(posedge clk); while (!s_ready);
        expected.push_back(beat);
        sent++;
        @(negedge clk);
        s_valid = 1'b0;
    endtask

    always @(posedge clk) begin
        if (resetn && !flush && m_valid && m_ready) begin
            beat_t beat;
            if (expected.size() == 0)
                fail("output appeared without an expected input");
            beat = expected.pop_front();
            if (m_data != beat.data || m_keep != beat.keep || m_last != beat.last)
                fail("output payload, keep, or last did not preserve input ordering");
            received++;
        end
    end

    initial begin
        beat_t beat;
        logic [31:0] held_data;
        logic [3:0] held_keep;
        logic held_last;

        s_data = '0;
        s_keep = '0;
        s_last = 1'b0;
        s_valid = 1'b0;
        m_ready = 1'b0;
        sent = 0;
        received = 0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        resetn = 1'b1;

        // Fill both entries while the destination is blocked.
        beat = '{32'h1122_3344, 4'b1111, 1'b0};
        send_beat(beat);
        beat = '{32'h5566_7788, 4'b0011, 1'b1};
        send_beat(beat);
        if (s_ready)
            fail("source remained ready when both entries were occupied");

        held_data = m_data;
        held_keep = m_keep;
        held_last = m_last;
        repeat (5) begin
            @(posedge clk);
            if (!m_valid || m_data != held_data || m_keep != held_keep ||
                m_last != held_last)
                fail("blocked output did not remain stable");
        end

        m_ready = 1'b1;
        wait (received == 2);
        @(negedge clk);
        if (m_valid)
            fail("queue remained valid after both entries drained");

        // With an always-ready destination, a continuous source must sustain
        // one transfer every cycle after initial queue latency.
        for (int i = 0; i < 32; i++) begin
            @(negedge clk);
            s_data = 32'h8000_0000 + i;
            s_keep = 4'(i + 1);
            s_last = (i % 7) == 6;
            s_valid = 1'b1;
            @(posedge clk);
            if (!s_ready)
                fail("steady-state queue inserted a source bubble");
            expected.push_back('{s_data, s_keep, s_last});
            sent++;
        end
        @(negedge clk);
        s_valid = 1'b0;
        wait (received == sent);

        // Flushing occupied storage must make every stale payload unreachable.
        m_ready = 1'b0;
        beat = '{32'haaaa_0001, 4'b1111, 1'b0};
        send_beat(beat);
        beat = '{32'haaaa_0002, 4'b0001, 1'b1};
        send_beat(beat);
        @(negedge clk);
        flush = 1'b1;
        expected.delete();
        @(posedge clk);
        @(negedge clk);
        flush = 1'b0;
        if (m_valid)
            fail("flushed payload remained visible");

        beat = '{32'hcafe_babe, 4'b0111, 1'b1};
        send_beat(beat);
        m_ready = 1'b1;
        wait (expected.size() == 0);
        repeat (2) @(posedge clk);

        $display("PASS: registered two-entry stream queue preserves records, stalls, throughput, and flush");
        $finish;
    end

    initial begin
        #200000;
        fail("testbench timeout");
    end
endmodule
