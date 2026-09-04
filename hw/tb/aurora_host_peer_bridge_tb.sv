`timescale 1ns / 1ps

module aurora_host_peer_bridge_tb;
    `include "qshell_abi_generated.svh"

    localparam int DATA_W = QSHELL_BEAT_BYTES * 8;
    localparam int KEEP_W = QSHELL_BEAT_BYTES;
    localparam int MAX_PAYLOAD_BYTES = 4096;
    localparam int FIRST_PAYLOAD_BYTES =
        QSHELL_BEAT_BYTES - QSHELL_HEADER_BYTES;
    localparam int MAX_RECORD_BEATS =
        1 + (MAX_PAYLOAD_BYTES - FIRST_PAYLOAD_BYTES +
             QSHELL_BEAT_BYTES - 1) / QSHELL_BEAT_BYTES;
    localparam int D3_PAYLOAD_BYTES = 6;
    localparam int D9_REQUEST_PAYLOAD_BYTES = 760;
    localparam int D9_RESPONSE_PAYLOAD_BYTES = 3518;

    logic clk;
    logic resetn;
    logic link_up;

    logic [DATA_W-1:0] host_in_data;
    logic [KEEP_W-1:0] host_in_keep;
    logic host_in_last;
    logic host_in_valid;
    logic host_in_ready;
    logic [DATA_W-1:0] host_out_data;
    logic [KEEP_W-1:0] host_out_keep;
    logic host_out_last;
    logic host_out_valid;
    logic host_out_ready;

    logic [DATA_W-1:0] peer_in_data;
    logic [KEEP_W-1:0] peer_in_keep;
    logic peer_in_last;
    logic peer_in_valid;
    logic peer_in_ready;
    logic [DATA_W-1:0] peer_out_data;
    logic [KEEP_W-1:0] peer_out_keep;
    logic peer_out_last;
    logic peer_out_valid;
    logic peer_out_ready;

    typedef struct packed {
        logic [DATA_W-1:0] data;
        logic [KEEP_W-1:0] keep;
        logic last;
    } beat_t;

    beat_t expected_host[$];
    beat_t expected_peer[$];
    integer host_transfer_cycles[$];
    integer peer_transfer_cycles[$];
    integer cycle_count;
    integer host_received;
    integer peer_received;

    aurora_host_peer_bridge #(
        .DATA_W(DATA_W),
        .MAX_PAYLOAD_BYTES(MAX_PAYLOAD_BYTES)
    ) dut (
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

    function automatic int record_beats(input int payload_bytes);
        if (payload_bytes <= FIRST_PAYLOAD_BYTES)
            return 1;
        return 1 +
            (payload_bytes - FIRST_PAYLOAD_BYTES + QSHELL_BEAT_BYTES - 1) /
            QSHELL_BEAT_BYTES;
    endfunction

    function automatic int beat_valid_bytes(
        input int payload_bytes,
        input int beat_index
    );
        int remaining;
        if (beat_index == 0) begin
            return QSHELL_HEADER_BYTES +
                (payload_bytes < FIRST_PAYLOAD_BYTES ?
                 payload_bytes : FIRST_PAYLOAD_BYTES);
        end
        remaining = payload_bytes - FIRST_PAYLOAD_BYTES -
                    (beat_index - 1) * QSHELL_BEAT_BYTES;
        return remaining < QSHELL_BEAT_BYTES ?
               remaining : QSHELL_BEAT_BYTES;
    endfunction

    function automatic logic [KEEP_W-1:0] low_keep(input int valid_bytes);
        logic [KEEP_W-1:0] value;
        value = '0;
        for (int lane = 0; lane < KEEP_W; lane++) begin
            if (lane < valid_bytes)
                value[lane] = 1'b1;
        end
        return value;
    endfunction

    // Every lane, including lanes outside TKEEP, is distinctive. Exact
    // end-to-end comparison therefore detects byte, half-vector, and complete
    // 512-bit vector remapping as well as framing changes.
    function automatic logic [DATA_W-1:0] record_data(
        input int payload_bytes,
        input int beat_index,
        input logic [7:0] salt,
        input logic [7:0] record_class
    );
        logic [DATA_W-1:0] value;
        int absolute_byte;
        value = '0;
        for (int lane = 0; lane < KEEP_W; lane++) begin
            absolute_byte = beat_index * KEEP_W + lane;
            value[lane * 8 +: 8] =
                salt ^ 8'(absolute_byte * 29 + lane * 7 + beat_index);
        end
        if (beat_index == 0) begin
            value[QSHELL_MAGIC_LSB +: QSHELL_MAGIC_W] = QSHELL_MAGIC;
            value[QSHELL_ABI_VERSION_LSB +: QSHELL_ABI_VERSION_W] =
                QSHELL_ABI_VERSION[QSHELL_ABI_VERSION_W-1:0];
            value[QSHELL_RECORD_CLASS_LSB +: QSHELL_RECORD_CLASS_W] =
                record_class;
            value[QSHELL_FLAGS_LSB +: QSHELL_FLAGS_W] =
                QSHELL_FLAG_END_OF_ROUND;
            value[QSHELL_HEADER_BYTES_LSB +: QSHELL_HEADER_BYTES_W] =
                QSHELL_HEADER_BYTES[QSHELL_HEADER_BYTES_W-1:0];
            value[QSHELL_RESERVED_LSB +: QSHELL_RESERVED_W] = '0;
            value[QSHELL_PAYLOAD_BYTES_LSB +: QSHELL_PAYLOAD_BYTES_W] =
                QSHELL_PAYLOAD_BYTES_W'(payload_bytes);
            value[QSHELL_CONTEXT_ID_LSB +: QSHELL_CONTEXT_ID_W] =
                32'h1020_3040 ^ salt;
            value[QSHELL_ROUND_ID_LSB +: QSHELL_ROUND_ID_W] =
                32'h5060_7080 ^ salt;
            value[QSHELL_SCHEMA_ID_LSB +: QSHELL_SCHEMA_ID_W] =
                32'h0001_0001;
            value[QSHELL_SOURCE_ENDPOINT_ID_LSB +:
                  QSHELL_SOURCE_ENDPOINT_ID_W] = 32'h1234_5678;
            value[QSHELL_DESTINATION_ENDPOINT_ID_LSB +:
                  QSHELL_DESTINATION_ENDPOINT_ID_W] = 32'h8000_0001;
            value[QSHELL_ROUTE_CAPABILITY_ID_LSB +:
                  QSHELL_ROUTE_CAPABILITY_ID_W] = 32'h0000_0001;
            value[QSHELL_ROUTE_VERSION_LSB +: QSHELL_ROUTE_VERSION_W] =
                32'h0000_0001;
            value[QSHELL_RECORD_SEQUENCE_LSB +: QSHELL_RECORD_SEQUENCE_W] =
                32'h0000_0000;
        end
        return value;
    endfunction

    function automatic beat_t canonical_beat(
        input int payload_bytes,
        input int beat_index,
        input logic [7:0] salt,
        input logic [7:0] record_class
    );
        beat_t beat;
        beat.data = record_data(payload_bytes, beat_index, salt, record_class);
        beat.keep = low_keep(beat_valid_bytes(payload_bytes, beat_index));
        beat.last = beat_index + 1 == record_beats(payload_bytes);
        return beat;
    endfunction

    task automatic fail(input string message);
        $error("FAIL: %s", message);
        $fatal(1);
    endtask

    task automatic drive_host_beat(input beat_t beat, input logic forwarded);
        @(negedge clk);
        host_in_data = beat.data;
        host_in_keep = beat.keep;
        host_in_last = beat.last;
        host_in_valid = 1'b1;
        do @(posedge clk); while (!host_in_ready);
        if (forwarded)
            expected_peer.push_back(beat);
        @(negedge clk);
        host_in_valid = 1'b0;
    endtask

    task automatic drive_peer_beat(input beat_t beat, input logic forwarded);
        @(negedge clk);
        peer_in_data = beat.data;
        peer_in_keep = beat.keep;
        peer_in_last = beat.last;
        peer_in_valid = 1'b1;
        do @(posedge clk); while (!peer_in_ready);
        if (forwarded)
            expected_host.push_back(beat);
        @(negedge clk);
        peer_in_valid = 1'b0;
    endtask

    // These record drivers retain TVALID across beat boundaries, proving that
    // capture can accept one complete 512-bit beat per cycle.
    task automatic drive_host_record(
        input int payload_bytes,
        input logic [7:0] salt,
        input logic [7:0] record_class,
        input logic forwarded
    );
        beat_t beat;
        @(negedge clk);
        host_in_valid = 1'b1;
        for (int index = 0; index < record_beats(payload_bytes); index++) begin
            beat = canonical_beat(payload_bytes, index, salt, record_class);
            host_in_data = beat.data;
            host_in_keep = beat.keep;
            host_in_last = beat.last;
            do @(posedge clk); while (!host_in_ready);
            if (forwarded)
                expected_peer.push_back(beat);
            @(negedge clk);
        end
        host_in_valid = 1'b0;
    endtask

    task automatic drive_peer_record(
        input int payload_bytes,
        input logic [7:0] salt,
        input logic [7:0] record_class,
        input logic forwarded
    );
        beat_t beat;
        @(negedge clk);
        peer_in_valid = 1'b1;
        for (int index = 0; index < record_beats(payload_bytes); index++) begin
            beat = canonical_beat(payload_bytes, index, salt, record_class);
            peer_in_data = beat.data;
            peer_in_keep = beat.keep;
            peer_in_last = beat.last;
            do @(posedge clk); while (!peer_in_ready);
            if (forwarded)
                expected_host.push_back(beat);
            @(negedge clk);
        end
        peer_in_valid = 1'b0;
    endtask

    // Keep TVALID asserted across the record boundary and require every beat
    // to handshake on its first offered cycle. With continuous downstream
    // readiness, two maximum records exercise simultaneous capture and drain
    // without weakening the public one-beat-per-cycle contract.
    task automatic drive_two_host_records_without_stall(
        input int first_payload_bytes,
        input logic [7:0] first_salt,
        input int second_payload_bytes,
        input logic [7:0] second_salt
    );
        beat_t beat;
        int payload_bytes;
        logic [7:0] salt;

        @(negedge clk);
        host_in_valid = 1'b1;
        for (int record_index = 0; record_index < 2; record_index++) begin
            payload_bytes = record_index == 0 ?
                            first_payload_bytes : second_payload_bytes;
            salt = record_index == 0 ? first_salt : second_salt;
            for (int beat_index = 0;
                 beat_index < record_beats(payload_bytes);
                 beat_index++) begin
                beat = canonical_beat(
                    payload_bytes, beat_index, salt,
                    QSHELL_CLASS_SYNDROME);
                host_in_data = beat.data;
                host_in_keep = beat.keep;
                host_in_last = beat.last;
                @(posedge clk);
                if (!host_in_ready)
                    fail("continuous host records were backpressured");
                expected_peer.push_back(beat);
                @(negedge clk);
            end
        end
        host_in_valid = 1'b0;
    endtask

    task automatic drive_two_peer_records_without_stall(
        input int first_payload_bytes,
        input logic [7:0] first_salt,
        input int second_payload_bytes,
        input logic [7:0] second_salt
    );
        beat_t beat;
        int payload_bytes;
        logic [7:0] salt;

        @(negedge clk);
        peer_in_valid = 1'b1;
        for (int record_index = 0; record_index < 2; record_index++) begin
            payload_bytes = record_index == 0 ?
                            first_payload_bytes : second_payload_bytes;
            salt = record_index == 0 ? first_salt : second_salt;
            for (int beat_index = 0;
                 beat_index < record_beats(payload_bytes);
                 beat_index++) begin
                beat = canonical_beat(
                    payload_bytes, beat_index, salt,
                    QSHELL_CLASS_CORRECTION);
                peer_in_data = beat.data;
                peer_in_keep = beat.keep;
                peer_in_last = beat.last;
                @(posedge clk);
                if (!peer_in_ready)
                    fail("continuous peer records were backpressured");
                expected_host.push_back(beat);
                @(negedge clk);
            end
        end
        peer_in_valid = 1'b0;
    endtask

    task automatic wait_for_counts(input int host_count, input int peer_count);
        while (host_received != host_count || peer_received != peer_count)
            @(negedge clk);
    endtask

    task automatic require_quiet(input int cycles, input string message);
        repeat (cycles) begin
            @(posedge clk);
            if (host_out_valid || peer_out_valid)
                fail(message);
        end
        @(negedge clk);
    endtask

    task automatic drain_with_random_stalls(
        input int host_count,
        input int peer_count,
        input logic [31:0] initial_lfsr
    );
        logic [31:0] lfsr;
        int elapsed;
        lfsr = initial_lfsr;
        elapsed = 0;
        while (host_received != host_count || peer_received != peer_count) begin
            lfsr = {lfsr[30:0],
                    lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            host_out_ready = lfsr[0] || lfsr[7];
            peer_out_ready = lfsr[3] || lfsr[11];
            @(negedge clk);
            elapsed++;
            if (elapsed > 20000)
                fail("randomized output stalls did not make bounded progress");
        end
        host_out_ready = 1'b0;
        peer_out_ready = 1'b0;
    endtask

    initial begin
        clk = 1'b0;
        forever #5 clk = !clk;
    end

    /* verilator lint_off BLKSEQ */
    always @(posedge clk) begin
        beat_t expected;
        if (!resetn) begin
            cycle_count = 0;
            host_received = 0;
            peer_received = 0;
        end else begin
            cycle_count++;
            if (host_out_valid && host_out_ready) begin
                if (expected_host.size() == 0)
                    fail("unexpected peer-to-host beat");
                expected = expected_host.pop_front();
                if (host_out_data !== expected.data ||
                    host_out_keep !== expected.keep ||
                    host_out_last !== expected.last)
                    fail("peer-to-host whole vector, keep, last, or order changed");
                host_transfer_cycles.push_back(cycle_count);
                host_received++;
            end
            if (peer_out_valid && peer_out_ready) begin
                if (expected_peer.size() == 0)
                    fail("unexpected host-to-peer beat");
                expected = expected_peer.pop_front();
                if (peer_out_data !== expected.data ||
                    peer_out_keep !== expected.keep ||
                    peer_out_last !== expected.last)
                    fail("host-to-peer whole vector, keep, last, or order changed");
                peer_transfer_cycles.push_back(cycle_count);
                peer_received++;
            end
        end
    end
    /* verilator lint_on BLKSEQ */

    initial begin
        beat_t beat;
        beat_t held_host;
        beat_t held_peer;
        int host_before;
        int peer_before;
        int host_cycle_index;
        int peer_cycle_index;
        int host_target;
        int peer_target;

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

        if (MAX_RECORD_BEATS != 65 ||
            record_beats(D9_REQUEST_PAYLOAD_BYTES) != 13 ||
            record_beats(D9_RESPONSE_PAYLOAD_BYTES) != 56 ||
            record_beats(MAX_PAYLOAD_BYTES) != 65 ||
            QSHELL_HEADER_BYTES + D9_RESPONSE_PAYLOAD_BYTES != 3566)
            fail("generated ABI geometry or d9/max record fixture is incorrect");

        repeat (4) @(posedge clk);
        @(negedge clk);
        resetn = 1'b1;

        // A down transport starts no record in either direction.
        beat = canonical_beat(
            D3_PAYLOAD_BYTES, 0, 8'h11, QSHELL_CLASS_SYNDROME);
        host_in_data = beat.data;
        host_in_keep = beat.keep;
        host_in_last = beat.last;
        host_in_valid = 1'b1;
        peer_in_data = beat.data ^ DATA_W'(64'hfeed_face_dead_beef);
        peer_in_keep = beat.keep;
        peer_in_last = beat.last;
        peer_in_valid = 1'b1;
        repeat (3) begin
            @(posedge clk);
            if (host_in_ready || peer_in_ready ||
                host_out_valid || peer_out_valid)
                fail("bridge exposed traffic while the peer link was down");
        end
        @(negedge clk);
        host_in_valid = 1'b0;
        peer_in_valid = 1'b0;
        link_up = 1'b1;

        // Independent one-beat records become stable only after complete
        // validation, then survive arbitrary output backpressure.
        drive_host_beat(
            canonical_beat(D3_PAYLOAD_BYTES, 0, 8'h12,
                           QSHELL_CLASS_SYNDROME), 1'b1);
        drive_peer_beat(
            canonical_beat(D3_PAYLOAD_BYTES, 0, 8'h92,
                           QSHELL_CLASS_CORRECTION), 1'b1);
        wait (peer_out_valid && host_out_valid);
        held_peer = expected_peer[0];
        held_host = expected_host[0];
        repeat (3) begin
            @(posedge clk);
            if (peer_out_data !== held_peer.data ||
                peer_out_keep !== held_peer.keep ||
                peer_out_last !== held_peer.last ||
                host_out_data !== held_host.data ||
                host_out_keep !== held_host.keep ||
                host_out_last !== held_host.last)
                fail("committed one-beat record changed under backpressure");
        end
        host_before = host_received;
        peer_before = peer_received;
        @(negedge clk);
        host_out_ready = 1'b1;
        peer_out_ready = 1'b1;
        wait_for_counts(host_before + 1, peer_before + 1);
        host_out_ready = 1'b0;
        peer_out_ready = 1'b0;

        // The actual d9 request (760-byte payload, 13 beats) and result
        // (3,518-byte payload, 3,566 total bytes, 56 beats) remain invisible
        // until their exact final beat commits the complete record.
        for (int index = 0;
             index < record_beats(D9_REQUEST_PAYLOAD_BYTES) - 1;
             index++) begin
            drive_host_beat(
                canonical_beat(D9_REQUEST_PAYLOAD_BYTES, index, 8'h23,
                               QSHELL_CLASS_SYNDROME), 1'b1);
            if (peer_out_valid)
                fail("partial 13-beat d9 request became visible");
        end
        for (int index = 0;
             index < record_beats(D9_RESPONSE_PAYLOAD_BYTES) - 1;
             index++) begin
            drive_peer_beat(
                canonical_beat(D9_RESPONSE_PAYLOAD_BYTES, index, 8'ha3,
                               QSHELL_CLASS_CORRECTION), 1'b1);
            if (host_out_valid)
                fail("partial 56-beat d9 result became visible");
        end
        drive_host_beat(
            canonical_beat(D9_REQUEST_PAYLOAD_BYTES,
                           record_beats(D9_REQUEST_PAYLOAD_BYTES) - 1,
                           8'h23, QSHELL_CLASS_SYNDROME), 1'b1);
        drive_peer_beat(
            canonical_beat(D9_RESPONSE_PAYLOAD_BYTES,
                           record_beats(D9_RESPONSE_PAYLOAD_BYTES) - 1,
                           8'ha3, QSHELL_CLASS_CORRECTION), 1'b1);
        wait (peer_out_valid && host_out_valid);
        host_before = host_received;
        peer_before = peer_received;
        host_cycle_index = host_transfer_cycles.size();
        peer_cycle_index = peer_transfer_cycles.size();
        @(negedge clk);
        host_out_ready = 1'b1;
        peer_out_ready = 1'b1;
        wait_for_counts(
            host_before + record_beats(D9_RESPONSE_PAYLOAD_BYTES),
            peer_before + record_beats(D9_REQUEST_PAYLOAD_BYTES));
        for (int index = 1;
             index < record_beats(D9_RESPONSE_PAYLOAD_BYTES);
             index++) begin
            if (host_transfer_cycles[host_cycle_index + index] !=
                host_transfer_cycles[host_cycle_index] + index)
                fail("56-beat d9 result did not sustain one beat per cycle");
        end
        for (int index = 1;
             index < record_beats(D9_REQUEST_PAYLOAD_BYTES);
             index++) begin
            if (peer_transfer_cycles[peer_cycle_index + index] !=
                peer_transfer_cycles[peer_cycle_index] + index)
                fail("13-beat d9 request did not sustain one beat per cycle");
        end
        host_out_ready = 1'b0;
        peer_out_ready = 1'b0;

        // A maximum 4,096-byte payload occupies all 65 bounded banks. Its
        // final beat has 48 valid bytes because the first beat carries only 16
        // payload bytes after the generated 48-byte header.
        for (int index = 0; index < MAX_RECORD_BEATS - 1; index++) begin
            drive_host_beat(
                canonical_beat(MAX_PAYLOAD_BYTES, index, 8'h34,
                               QSHELL_CLASS_SYNDROME), 1'b1);
            if (peer_out_valid)
                fail("partial maximum-size record became visible");
        end
        beat = canonical_beat(
            MAX_PAYLOAD_BYTES, MAX_RECORD_BEATS - 1, 8'h34,
            QSHELL_CLASS_SYNDROME);
        if (beat.keep != low_keep(48) || !beat.last)
            fail("maximum-size final keep/last fixture is incorrect");
        drive_host_beat(beat, 1'b1);
        drive_host_record(
            D3_PAYLOAD_BYTES, 8'h35, QSHELL_CLASS_SYNDROME, 1'b1);
        peer_before = peer_received;
        drain_with_random_stalls(
            host_received, peer_before + MAX_RECORD_BEATS + 1,
            32'h1ace_b00c);

        // With both sinks continuously ready, two maximum records in each
        // direction handshake on every input cycle. The first record drains
        // while the second is captured, and output remains continuous across
        // the record boundary in both directions.
        host_before = host_received;
        peer_before = peer_received;
        peer_cycle_index = peer_transfer_cycles.size();
        host_out_ready = 1'b1;
        peer_out_ready = 1'b1;
        drive_two_host_records_without_stall(
            MAX_PAYLOAD_BYTES, 8'h3a,
            MAX_PAYLOAD_BYTES, 8'h3b);
        wait_for_counts(
            host_before, peer_before + 2 * MAX_RECORD_BEATS);
        for (int index = 1; index < 2 * MAX_RECORD_BEATS; index++) begin
            if (peer_transfer_cycles[peer_cycle_index + index] !=
                peer_transfer_cycles[peer_cycle_index] + index)
                fail("continuous host-to-peer records inserted a bubble");
        end

        host_cycle_index = host_transfer_cycles.size();
        drive_two_peer_records_without_stall(
            MAX_PAYLOAD_BYTES, 8'hba,
            MAX_PAYLOAD_BYTES, 8'hbb);
        wait_for_counts(
            host_before + 2 * MAX_RECORD_BEATS,
            peer_before + 2 * MAX_RECORD_BEATS);
        for (int index = 1; index < 2 * MAX_RECORD_BEATS; index++) begin
            if (host_transfer_cycles[host_cycle_index + index] !=
                host_transfer_cycles[host_cycle_index] + index)
                fail("continuous peer-to-host records inserted a bubble");
        end

        // One-beat records publish address zero on the same edge that writes
        // it. Keep both source and sink continuously active across that bank
        // boundary to protect the registered collision bypass in each
        // direction without weakening the general 65-beat throughput proof.
        host_before = host_received;
        peer_before = peer_received;
        peer_cycle_index = peer_transfer_cycles.size();
        drive_two_host_records_without_stall(
            D3_PAYLOAD_BYTES, 8'h3c,
            D3_PAYLOAD_BYTES, 8'h3d);
        wait_for_counts(host_before, peer_before + 2);
        if (peer_transfer_cycles[peer_cycle_index + 1] !=
            peer_transfer_cycles[peer_cycle_index] + 1)
            fail("continuous one-beat host records inserted a bubble");

        host_cycle_index = host_transfer_cycles.size();
        drive_two_peer_records_without_stall(
            D3_PAYLOAD_BYTES, 8'hbc,
            D3_PAYLOAD_BYTES, 8'hbd);
        wait_for_counts(host_before + 2, peer_before + 2);
        if (host_transfer_cycles[host_cycle_index + 1] !=
            host_transfer_cycles[host_cycle_index] + 1)
            fail("continuous one-beat peer records inserted a bubble");
        host_out_ready = 1'b0;
        peer_out_ready = 1'b0;

        // Two complete records can be queued back-to-back while stalled. Once
        // released, there is no beat or record-boundary bubble, and continuous
        // input capture accepts each multi-beat record on adjacent cycles.
        drive_host_record(
            D3_PAYLOAD_BYTES, 8'h45, QSHELL_CLASS_SYNDROME, 1'b1);
        drive_host_record(
            D9_REQUEST_PAYLOAD_BYTES, 8'h56,
            QSHELL_CLASS_SYNDROME, 1'b1);
        drive_peer_record(
            D3_PAYLOAD_BYTES, 8'hc5, QSHELL_CLASS_CORRECTION, 1'b1);
        drive_peer_record(
            D9_RESPONSE_PAYLOAD_BYTES, 8'hd6,
            QSHELL_CLASS_CORRECTION, 1'b1);
        if (host_in_ready || peer_in_ready)
            fail("two-record queues did not apply bounded source backpressure");
        host_before = host_received;
        peer_before = peer_received;
        host_cycle_index = host_transfer_cycles.size();
        peer_cycle_index = peer_transfer_cycles.size();
        host_target = host_before + 1 + record_beats(D9_RESPONSE_PAYLOAD_BYTES);
        peer_target = peer_before + 1 + record_beats(D9_REQUEST_PAYLOAD_BYTES);
        @(negedge clk);
        host_out_ready = 1'b1;
        peer_out_ready = 1'b1;
        wait_for_counts(host_target, peer_target);
        for (int index = 1;
             index < 1 + record_beats(D9_RESPONSE_PAYLOAD_BYTES);
             index++) begin
            if (host_transfer_cycles[host_cycle_index + index] !=
                host_transfer_cycles[host_cycle_index] + index)
                fail("peer-to-host back-to-back records inserted a bubble");
        end
        for (int index = 1;
             index < 1 + record_beats(D9_REQUEST_PAYLOAD_BYTES);
             index++) begin
            if (peer_transfer_cycles[peer_cycle_index + index] !=
                peer_transfer_cycles[peer_cycle_index] + index)
                fail("host-to-peer back-to-back records inserted a bubble");
        end

        // Header errors, noncontiguous first/final keep, partial intermediate
        // keep, early TLAST, late TLAST, and declared-size overflow all reject
        // atomically. No prefix of any malformed record may be forwarded.
        host_before = host_received;
        peer_before = peer_received;

        beat = canonical_beat(
            D3_PAYLOAD_BYTES, 0, 8'h61, QSHELL_CLASS_SYNDROME);
        beat.keep[7] = 1'b0;
        drive_host_beat(beat, 1'b0);

        beat = canonical_beat(
            D3_PAYLOAD_BYTES, 0, 8'he1, QSHELL_CLASS_CORRECTION);
        beat.data[QSHELL_MAGIC_LSB +: QSHELL_MAGIC_W] ^= 32'h0000_0100;
        drive_peer_beat(beat, 1'b0);

        // Invalid intermediate keep; the following TLAST is consumed only to
        // finish discard recovery.
        drive_host_beat(
            canonical_beat(200, 0, 8'h62, QSHELL_CLASS_SYNDROME), 1'b0);
        beat = canonical_beat(200, 1, 8'h62, QSHELL_CLASS_SYNDROME);
        beat.keep = low_keep(QSHELL_BEAT_BYTES - 1);
        drive_host_beat(beat, 1'b0);
        drive_host_beat(
            canonical_beat(200, record_beats(200) - 1, 8'h62,
                           QSHELL_CLASS_SYNDROME), 1'b0);

        // Early TLAST on a full continuation that is not the declared final
        // beat.
        drive_peer_beat(
            canonical_beat(200, 0, 8'he2, QSHELL_CLASS_CORRECTION), 1'b0);
        beat = canonical_beat(200, 1, 8'he2, QSHELL_CLASS_CORRECTION);
        beat.last = 1'b1;
        drive_peer_beat(beat, 1'b0);

        // Noncontiguous final keep.
        drive_host_beat(
            canonical_beat(20, 0, 8'h63, QSHELL_CLASS_SYNDROME), 1'b0);
        beat = canonical_beat(20, 1, 8'h63, QSHELL_CLASS_SYNDROME);
        beat.keep = 64'h0000_0000_0000_000b;
        drive_host_beat(beat, 1'b0);

        // Exact final keep but late TLAST; a later TLAST drains the rejected
        // record without becoming a fresh header.
        drive_peer_beat(
            canonical_beat(20, 0, 8'he3, QSHELL_CLASS_CORRECTION), 1'b0);
        beat = canonical_beat(20, 1, 8'he3, QSHELL_CLASS_CORRECTION);
        beat.last = 1'b0;
        drive_peer_beat(beat, 1'b0);
        beat = canonical_beat(
            D3_PAYLOAD_BYTES, 0, 8'he4, QSHELL_CLASS_CORRECTION);
        drive_peer_beat(beat, 1'b0);

        // The first beat declares one byte beyond the 4,096-byte ABI/service
        // bound. All 65 physical beats are drained and none are published.
        drive_peer_record(
            MAX_PAYLOAD_BYTES + 1, 8'he5,
            QSHELL_CLASS_CORRECTION, 1'b0);

        // A maximum declaration followed by a 66th physical beat exercises
        // defensive late-last/capacity recovery without indexing past bank 64.
        for (int index = 0; index < MAX_RECORD_BEATS; index++) begin
            beat = canonical_beat(
                MAX_PAYLOAD_BYTES, index, 8'h65, QSHELL_CLASS_SYNDROME);
            if (index == MAX_RECORD_BEATS - 1)
                beat.last = 1'b0;
            drive_host_beat(beat, 1'b0);
        end
        beat = canonical_beat(
            D3_PAYLOAD_BYTES, 0, 8'h66, QSHELL_CLASS_SYNDROME);
        drive_host_beat(beat, 1'b0);

        require_quiet(8, "malformed or overflowing record was forwarded");
        if (host_received != host_before || peer_received != peer_before)
            fail("rejected record changed output transfer counts");

        // Valid records immediately following the rejection/discard cases
        // prove bounded recovery in both directions.
        drive_host_record(
            D3_PAYLOAD_BYTES, 8'h67, QSHELL_CLASS_SYNDROME, 1'b1);
        drive_peer_record(
            D3_PAYLOAD_BYTES, 8'he7, QSHELL_CLASS_CORRECTION, 1'b1);
        wait_for_counts(host_before + 1, peer_before + 1);

        // Link loss discards a private peer prefix. The next epoch starts with
        // a fresh record; no old continuation can be spliced into it.
        host_out_ready = 1'b0;
        drive_peer_beat(
            canonical_beat(D9_RESPONSE_PAYLOAD_BYTES, 0, 8'hf1,
                           QSHELL_CLASS_CORRECTION), 1'b0);
        if (host_out_valid)
            fail("partial peer record escaped before epoch loss");
        @(negedge clk);
        link_up = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        link_up = 1'b1;
        drive_peer_record(
            D3_PAYLOAD_BYTES, 8'hf2, QSHELL_CLASS_CORRECTION, 1'b1);
        host_before = host_received;
        @(negedge clk);
        host_out_ready = 1'b1;
        wait_for_counts(host_before + 1, peer_received);

        // Host loss is asymmetric: finish the old DMA record while down, but
        // flush all of its captured data before reconnect.
        peer_out_ready = 1'b0;
        drive_host_beat(
            canonical_beat(D9_REQUEST_PAYLOAD_BYTES, 0, 8'h71,
                           QSHELL_CLASS_SYNDROME), 1'b0);
        if (peer_out_valid)
            fail("partial host record escaped before epoch loss");
        @(negedge clk);
        link_up = 1'b0;
        drive_host_beat(
            canonical_beat(D9_REQUEST_PAYLOAD_BYTES,
                           record_beats(D9_REQUEST_PAYLOAD_BYTES) - 1,
                           8'h71, QSHELL_CLASS_SYNDROME), 1'b0);
        if (peer_out_valid)
            fail("discarded host remainder escaped while link was down");
        @(negedge clk);
        link_up = 1'b1;
        drive_host_record(
            D3_PAYLOAD_BYTES, 8'h72, QSHELL_CLASS_SYNDROME, 1'b1);
        peer_before = peer_received;
        @(negedge clk);
        peer_out_ready = 1'b1;
        wait_for_counts(host_received, peer_before + 1);

        // A complete peer response remains durable after TLAST even if the
        // transport epoch ends while the host is stalled.
        host_out_ready = 1'b0;
        drive_peer_record(
            D3_PAYLOAD_BYTES, 8'hf3, QSHELL_CLASS_CORRECTION, 1'b1);
        wait (host_out_valid);
        held_host = expected_host[0];
        @(negedge clk);
        link_up = 1'b0;
        repeat (3) begin
            @(posedge clk);
            if (!host_out_valid || host_out_data !== held_host.data ||
                host_out_keep !== held_host.keep ||
                host_out_last !== held_host.last)
                fail("complete peer record was retracted at epoch loss");
        end
        host_before = host_received;
        @(negedge clk);
        host_out_ready = 1'b1;
        wait_for_counts(host_before + 1, peer_received);

        // Conversely, a complete request that has not crossed the peer output
        // is stale after link loss and must not resume on reconnect.
        @(negedge clk);
        link_up = 1'b1;
        peer_out_ready = 1'b0;
        drive_host_record(
            D3_PAYLOAD_BYTES, 8'h73, QSHELL_CLASS_SYNDROME, 1'b0);
        wait (peer_out_valid);
        @(negedge clk);
        link_up = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        link_up = 1'b1;
        peer_out_ready = 1'b1;
        repeat (4) @(posedge clk);
        if (peer_out_valid)
            fail("queued host request survived its transport epoch");

        if (expected_host.size() != 0 || expected_peer.size() != 0)
            fail("scoreboard retained an undelivered accepted record");

        $display("PASS: Aurora bridge validates atomic 13/56/65-beat QSH2 records, stalls, drops, and epochs");
        $finish;
    end

    initial begin
        #1000000;
        fail("testbench timeout");
    end
endmodule
