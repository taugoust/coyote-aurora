`timescale 1ns / 1ps

// Two-record QSH2 AXI-stream queue. A record becomes visible only after every
// beat has passed the generated ABI header/framing checks and the exact TLAST
// beat has been accepted. Invalid records are discarded through TLAST without
// exposing a prefix. The two banks allow one complete record to drain while
// the next is captured; every beat remains one opaque, whole vector.
module axis_record_fifo_2 #(
    parameter int DATA_W = 512,
    parameter int KEEP_W = DATA_W / 8,
    parameter int MAX_PAYLOAD_BYTES = 4096
) (
    input  logic              aclk,
    input  logic              aresetn,
    input  logic              flush,
    input  logic              abort_partial,

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
    `include "qshell_abi_generated.svh"

    localparam int FIRST_PAYLOAD_BYTES =
        QSHELL_BEAT_BYTES - QSHELL_HEADER_BYTES;
    localparam int MAX_RECORD_BEATS =
        1 + (MAX_PAYLOAD_BYTES <= FIRST_PAYLOAD_BYTES ? 0 :
             (MAX_PAYLOAD_BYTES - FIRST_PAYLOAD_BYTES +
              QSHELL_BEAT_BYTES - 1) / QSHELL_BEAT_BYTES);
    localparam int BEAT_INDEX_W =
        MAX_RECORD_BEATS <= 1 ? 1 : $clog2(MAX_RECORD_BEATS);

    logic [DATA_W-1:0] data_bank [2][MAX_RECORD_BEATS];
    logic [KEEP_W-1:0] keep_bank [2][MAX_RECORD_BEATS];
    logic last_bank [2][MAX_RECORD_BEATS];
    logic [1:0] bank_reserved;
    logic [1:0] bank_complete;
    logic read_bank;
    logic write_bank;
    logic [BEAT_INDEX_W-1:0] capture_index;
    logic [BEAT_INDEX_W-1:0] output_index;
    logic [31:0] remaining_payload;
    logic capture_active;
    logic discarding;
    logic input_fire;
    logic output_fire;

    logic first_valid;
    logic first_record_complete;
    logic [31:0] first_remaining_payload;
    logic [31:0] first_payload_bytes;
    logic [KEEP_W-1:0] expected_continuation_keep;
    logic expected_continuation_last;
    logic continuation_valid;

    qshell_record_first_beat inst_first_beat_checker (
        .data(s_tdata),
        .keep(s_tkeep),
        .last(s_tlast),
        .valid(first_valid),
        .error_code(),
        .record_complete(first_record_complete),
        .remaining_payload(first_remaining_payload),
        .payload_bytes(first_payload_bytes),
        .record_class(),
        .flags(),
        .context_id(),
        .round_id(),
        .schema_id(),
        .source_endpoint_id(),
        .destination_endpoint_id(),
        .route_capability_id(),
        .route_version(),
        .record_sequence()
    );

    function automatic logic [KEEP_W-1:0] low_keep(input int valid_bytes);
        logic [KEEP_W-1:0] value;
        value = '0;
        for (int lane = 0; lane < KEEP_W; lane++) begin
            if (lane < valid_bytes)
                value[lane] = 1'b1;
        end
        return value;
    endfunction

    always_comb begin : stream_control
        int expected_valid_bytes;

        m_tdata = data_bank[read_bank][output_index];
        m_tkeep = keep_bank[read_bank][output_index];
        m_tlast = last_bank[read_bank][output_index];
        m_tvalid = !flush && bank_complete[read_bank];

        // Once a record starts, its bank is private through exact framing
        // validation. A rejected record remains ready in discard mode so a
        // malformed producer cannot occupy a bank or splice its remainder into
        // the next record.
        s_tready = !flush && !abort_partial &&
                   (discarding || capture_active || !bank_reserved[write_bank]);
        input_fire = s_tvalid && s_tready;
        output_fire = m_tvalid && m_tready;

        expected_valid_bytes = remaining_payload > QSHELL_BEAT_BYTES ?
                               QSHELL_BEAT_BYTES : int'(remaining_payload);
        expected_continuation_keep = low_keep(expected_valid_bytes);
        expected_continuation_last =
            remaining_payload > 0 && remaining_payload <= QSHELL_BEAT_BYTES;
        continuation_valid = capture_active && remaining_payload > 0 &&
                             s_tkeep == expected_continuation_keep &&
                             s_tlast == expected_continuation_last;
    end

    always_ff @(posedge aclk) begin
        if (!aresetn || flush) begin
            bank_reserved <= '0;
            bank_complete <= '0;
            read_bank <= 1'b0;
            write_bank <= 1'b0;
            capture_index <= '0;
            output_index <= '0;
            remaining_payload <= '0;
            capture_active <= 1'b0;
            discarding <= 1'b0;
        end else begin
            if (output_fire) begin
                if (m_tlast) begin
                    bank_reserved[read_bank] <= 1'b0;
                    bank_complete[read_bank] <= 1'b0;
                    read_bank <= !read_bank;
                    output_index <= '0;
                end else begin
                    output_index <= output_index + 1'b1;
                end
            end

            if (abort_partial) begin
                if (capture_active) begin
                    bank_reserved[write_bank] <= 1'b0;
                    bank_complete[write_bank] <= 1'b0;
                end
                capture_index <= '0;
                remaining_payload <= '0;
                capture_active <= 1'b0;
                discarding <= 1'b0;
            end else if (discarding) begin
                if (input_fire && s_tlast)
                    discarding <= 1'b0;
            end else if (input_fire) begin
                if (!capture_active) begin
                    if (!first_valid ||
                        first_payload_bytes > MAX_PAYLOAD_BYTES) begin
                        // A malformed first beat that already carries TLAST is
                        // fully consumed. Otherwise drain its private remainder
                        // before treating another beat as a fresh header.
                        discarding <= !s_tlast;
                    end else begin
                        data_bank[write_bank][0] <= s_tdata;
                        keep_bank[write_bank][0] <= s_tkeep;
                        last_bank[write_bank][0] <= s_tlast;
                        bank_reserved[write_bank] <= 1'b1;
                        if (first_record_complete) begin
                            bank_complete[write_bank] <= 1'b1;
                            write_bank <= !write_bank;
                        end else begin
                            capture_active <= 1'b1;
                            capture_index <= BEAT_INDEX_W'(1);
                            remaining_payload <= first_remaining_payload;
                        end
                    end
                end else if (int'(capture_index) >= MAX_RECORD_BEATS ||
                             !continuation_valid) begin
                    // Early/late TLAST, sparse or incorrectly sized TKEEP, or
                    // any defensive capacity overflow rejects the entire
                    // private record. TLAST itself determines whether draining
                    // is already complete.
                    bank_reserved[write_bank] <= 1'b0;
                    bank_complete[write_bank] <= 1'b0;
                    capture_index <= '0;
                    remaining_payload <= '0;
                    capture_active <= 1'b0;
                    discarding <= !s_tlast;
                end else begin
                    data_bank[write_bank][capture_index] <= s_tdata;
                    keep_bank[write_bank][capture_index] <= s_tkeep;
                    last_bank[write_bank][capture_index] <= s_tlast;
                    if (s_tlast) begin
                        bank_complete[write_bank] <= 1'b1;
                        write_bank <= !write_bank;
                        capture_index <= '0;
                        remaining_payload <= '0;
                        capture_active <= 1'b0;
                    end else begin
                        capture_index <= capture_index + 1'b1;
                        remaining_payload <=
                            remaining_payload - QSHELL_BEAT_BYTES;
                    end
                end
            end
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
            assert ((bank_complete & ~bank_reserved) == 2'b00);
            assert (!(capture_active && discarding));
            if (capture_active) begin
                assert (bank_reserved[write_bank] &&
                        !bank_complete[write_bank]);
                assert (remaining_payload > 0);
                assert (int'(capture_index) < MAX_RECORD_BEATS);
            end
            stalled_previous <= m_tvalid && !m_tready;
        end
    end
`endif

    initial begin
        if (DATA_W != QSHELL_BEAT_BYTES * 8 ||
            KEEP_W != QSHELL_BEAT_BYTES || KEEP_W * 8 != DATA_W)
            $fatal(1, "QSH2 record FIFO requires the generated ABI stream width");
        if (MAX_PAYLOAD_BYTES < 0 || MAX_RECORD_BEATS < 1)
            $fatal(1, "QSH2 record FIFO requires a valid payload bound");
    end
endmodule
