/*
 * Copyright © 2020 Eric Matthews,  Lesley Shannon
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Initial code developed under the supervision of Dr. Lesley Shannon,
 * Reconfigurable Computing Lab, Simon Fraser University.
 *
 * Author(s):
 *             Eric Matthews <ematthew@sfu.ca>
 */

module instruction_metadata_and_id_management

    import cva5_config::*;
    import riscv_types::*;
    import cva5_types::*;
    import scaiev_config::*;

    # (
        parameter cpu_config_t CONFIG = EXAMPLE_CONFIG
    )

    (
        input logic clk,
        input logic rst,
        input gc_outputs_t gc,
        scaiev_interface.core scaiev,

        //Fetch
        output fetch_id_t pc_id,
        output logic pc_id_available,
        input logic [31:0] if_pc,
        input logic pc_id_assigned,

        output fetch_id_t fetch_id,
        input logic early_branch_flush,
        input logic fetch_complete,
        input logic [31:0] fetch_instruction,
        input fetch_metadata_t fetch_metadata,

        //SCAIE-V Decode Inject
        //-> Allocate the decode.id as a new ID, shifting all successor IDs that enter decode in the future
        input logic scaiev_decode_inject,
        output logic pc_inject_id_available,
        input logic pc_inject_id_assigned,
        //If set, do not pop pre-decode ID (to be reissued).
        input logic pc_inject_keep_for_repeat, //SCAIE-V
        input logic pc_inject_is_repeat, //SCAIE-V

        //Decode ID
        output decode_packet_t decode,
        input logic decode_advance,
        input logic decode_uses_rd,
        input rs_addr_t decode_rd_addr,
        input exception_sources_t decode_exception_unit,
        //renamer
        input phys_addr_t decode_phys_rd_addr,

        //Issue stage
        input issue_packet_t issue,
        input logic instruction_issued,
        input logic instruction_issued_with_rd,

        //WB
        input wb_packet_t wb_packet [CONFIG.NUM_WB_GROUPS],
        input logic wb_is_stallable,
        output commit_packet_t commit_packet [CONFIG.NUM_WB_GROUPS],

        //Retirer
        output retire_packet_t retire,
        output id_t retire_ids [RETIRE_PORTS],
        output id_t retire_ids_next [RETIRE_PORTS],
        output logic retire_port_valid [RETIRE_PORTS],

        //CSR
        output logic [LOG2_MAX_IDS:0] post_issue_count,
        //Exception
        output logic [31:0] oldest_pc,
        output logic [$clog2(NUM_EXCEPTION_SOURCES)-1:0] current_exception_unit
    );

generate if (!ENABLE_DECODE_INJECT) begin : gen_vanilla
    decode_packet_t decode_vanilla;
    always_comb begin
        decode = decode_vanilla;
        decode.pc_id = decode_vanilla.id;
    end
    assign pc_inject_id_available = 0;
    instruction_metadata_and_id_management_vanilla #(.CONFIG(CONFIG))
        id_block_vanilla (
            .clk (clk),
            .rst (rst),
            .decode (decode_vanilla),
            .*
        );
end
else begin : gen_scaiev_injectable //ENABLE_DECODE_INJECT
    //////////////////////////////////////////
    (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] pc_table [MAX_IDS_FETCH];
    (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] instruction_table [MAX_IDS_FETCH];

    (* ramstyle = "MLAB, no_rw_check" *) phys_addr_t phys_addr_table [MAX_IDS];
    (* ramstyle = "MLAB, no_rw_check" *) logic [0:0] uses_rd_table [MAX_IDS];

    (* ramstyle = "MLAB, no_rw_check" *) logic [$bits(fetch_metadata_t)-1:0] fetch_metadata_table [MAX_IDS_FETCH];

    // TODO: Disable/Remove if SCAIE-V Decode Inject is unused.
    (* ramstyle = "MLAB, no_rw_check" *) fetch_id_t pc_fetch_id_translation [MAX_IDS]; //Added for SCAIE-V
    //Set if pc_fetch_id_translation is valid for a given post-decode ID.
    //Also not set for instructions that have further repeats (only the last repeat will have has_fetch_id).
    (* ramstyle = "MLAB, no_rw_check" *) logic pops_fetch_id [MAX_IDS]; //Added for SCAIE-V

    (* ramstyle = "MLAB, no_rw_check" *) logic [$bits(exception_sources_t)-1:0] exception_unit_table [MAX_IDS];

    fetch_id_t pre_decode_id;
    id_t post_decode_id; //Added for SCAIE-V Decode Inject - decoupling of decode..retire IDs from fetch..decode
    id_t oldest_pre_issue_id;
    fetch_id_t oldest_pre_issue_fetch_id; //Added for SCAIE-V Decode Inject

    id_t oldest_pre_decode_id; //Added for SCAIE-V decode_flush
    fetch_id_t oldest_pre_decode_fetch_id; //Added for SCAIE-V Decode Inject

    localparam ID_COUNTER_W = LOG2_MAX_IDS+1;
    localparam ID_COUNTER_FETCH_W = LOG2_MAX_IDS_FETCH+1;
    logic [LOG2_MAX_IDS_FETCH:0] fetched_count_neg;
    logic [LOG2_MAX_IDS_FETCH:0] pre_issue_count;
    logic [LOG2_MAX_IDS_FETCH:0] pre_issue_count_next;
    logic [LOG2_MAX_IDS:0] post_issue_count_next;
    logic [LOG2_MAX_IDS:0] post_decode_count; //Added for SCAIE-V Decode Inject
    logic [LOG2_MAX_IDS:0] post_decode_count_next; //Added for SCAIE-V Decode Inject
    logic [LOG2_MAX_IDS:0] post_issue_count_noninject;
    logic [LOG2_MAX_IDS:0] post_issue_count_noninject_next;
    //logic [LOG2_MAX_IDS:0] inflight_count; //Removed (not used due to SCAIE-V Decode Inject changes)
    logic [LOG2_MAX_IDS_FETCH:0] inflight_count_noninject;
    logic [LOG2_MAX_IDS_FETCH:0] inflight_count_noninject_next;

    retire_packet_t retire_next;
    logic [LOG2_RETIRE_PORTS : 0] retire_next_count_noninject; //Added for SCAIE-V Decode Inject
    logic retire_port_valid_next [RETIRE_PORTS];

    logic pop_pre_decode_instr; //SCAIE-V Decode Inject: Set if the next Decode should actually continue to the next fetched instruction.

    genvar i;
    ////////////////////////////////////////////////////
    //Implementation

    ////////////////////////////////////////////////////
    //Instruction Metadata
    //PC table
    //Number of read ports = 1 or 2 (decode stage + exception logic (if enabled))
    always_ff @ (posedge clk) begin
        if (pc_id_assigned)
            pc_table[pc_id] <= if_pc;
    end

    ////////////////////////////////////////////////////
    //Instruction table
    //Number of read ports = 1 (decode stage)
    always_ff @ (posedge clk) begin
        if (fetch_complete)
            instruction_table[fetch_id] <= fetch_instruction;
    end

    ////////////////////////////////////////////////////
    //Valid fetched address table
    //Number of read ports = 1 (decode stage)
    always_ff @ (posedge clk) begin
        if (fetch_complete)
            fetch_metadata_table[fetch_id] <= fetch_metadata;
    end

    ////////////////////////////////////////////////////
    // SCAIE-V offset translating IDs from post-decode to pre-decode IDs for pc_table, instruction_table, fetch_metadata_table
    always_ff @ (posedge clk) begin
        if (decode_advance)
            pc_fetch_id_translation[post_decode_id] <= pre_decode_id;
    end
    always_ff @ (posedge clk) begin
        if (decode_advance)
            pops_fetch_id[post_decode_id] <= pop_pre_decode_instr;
    end

    ////////////////////////////////////////////////////
    //Phys rd table
    //Number of read ports = (NUM_WB_GROUPS - 1)  (ALU WB group uses issue_phys_rd_addr)
    always_ff @ (posedge clk) begin
        if (decode_advance)
            phys_addr_table[post_decode_id] <= decode_phys_rd_addr;
    end

    ////////////////////////////////////////////////////
    //Uses rd table
    //Number of read ports = RETIRE_PORTS
    always_ff @ (posedge clk) begin
        if (decode_advance)
            uses_rd_table[post_decode_id] <= decode_uses_rd & |decode_rd_addr;
    end

    ////////////////////////////////////////////////////
    //Exception unit table
    always_ff @ (posedge clk) begin
        if (decode_advance)
            exception_unit_table[post_decode_id] <= decode_exception_unit;
    end

    ////////////////////////////////////////////////////
    //ID Management
    
    assign pop_pre_decode_instr = !pc_inject_keep_for_repeat && (pc_inject_is_repeat || !pc_inject_id_assigned);

    function fetch_id_t incr_fetch_id_t_wrap(input fetch_id_t op);
        return (op == LOG2_MAX_IDS_FETCH'(MAX_IDS_FETCH-1)) ? '0 : (op + 1);
    endfunction

    //Next ID always increases, except on a fetch buffer flush.
    //On a fetch buffer flush, the next ID is restored to the oldest non-issued ID (decode or issue stage)
    //This prevents a stall in the case where all  IDs are either in-flight or
    //in the fetch buffer at the point of a fetch flush.
    always_ff @ (posedge clk) begin
        if (rst) begin
            oldest_pre_issue_id <= 0;
            oldest_pre_issue_fetch_id <= 0;
        end
        else if (instruction_issued) begin
            oldest_pre_issue_id <= oldest_pre_issue_id + 1;
            if (~scaiev.issue_injected)
                oldest_pre_issue_fetch_id <= incr_fetch_id_t_wrap(oldest_pre_issue_fetch_id);
        end
    end
    always_ff @ (posedge clk) begin
        if (rst) begin
            oldest_pre_decode_id <= 0;
            oldest_pre_decode_fetch_id <= 0;
        end
        else if (scaiev.issue_flush | gc.fetch_flush) begin
            oldest_pre_decode_id <= oldest_pre_issue_id;
            oldest_pre_decode_fetch_id <= oldest_pre_issue_fetch_id;
        end
        else if (decode_advance && !scaiev.decode_flush) begin
            oldest_pre_decode_id <= oldest_pre_decode_id + 1;
            if (pop_pre_decode_instr)
                oldest_pre_decode_fetch_id <= incr_fetch_id_t_wrap(oldest_pre_decode_fetch_id);
        end
    end

    assign scaiev.fetch_fetchFlushID = (gc.fetch_flush | scaiev.issue_flush) ? oldest_pre_issue_fetch_id : oldest_pre_decode_fetch_id;
    assign scaiev.fetch_fetchFlushCount = (gc.fetch_flush | scaiev.issue_flush | scaiev.decode_flush) ? ({1'b0,pc_id} - {1'b0,scaiev.fetch_fetchFlushID}) : '0;
    assign scaiev.issue_flushID = (gc.fetch_flush | scaiev.issue_flush) ? oldest_pre_issue_id : oldest_pre_decode_id;

    fetch_id_t pc_id_incr_wrap;
    fetch_id_t fetch_id_incr_wrap;
    fetch_id_t pre_decode_id_incr_wrap;
    always_comb begin
        pc_id_incr_wrap = (early_branch_flush ? fetch_id : pc_id);
        if (pc_id_assigned) begin
            pc_id_incr_wrap = incr_fetch_id_t_wrap(pc_id_incr_wrap);
        end
        fetch_id_incr_wrap = fetch_id;
        if (fetch_complete) begin
            fetch_id_incr_wrap = incr_fetch_id_t_wrap(fetch_id_incr_wrap);
        end
        pre_decode_id_incr_wrap = pre_decode_id;
        if (decode_advance && pop_pre_decode_instr) begin
            pre_decode_id_incr_wrap = incr_fetch_id_t_wrap(pre_decode_id_incr_wrap);
        end
    end
    always_ff @ (posedge clk) begin
        if (rst) begin
            pc_id <= 0;
            fetch_id <= 0;
            pre_decode_id <= 0;
            post_decode_id <= 0;
        end
        else if (gc.fetch_flush | scaiev.issue_flush) begin //Flush all PC assignments, fetches, decodes, current issue
            pc_id <= oldest_pre_issue_fetch_id;
            fetch_id <= oldest_pre_issue_fetch_id;
            pre_decode_id <= oldest_pre_issue_fetch_id;
            post_decode_id <= oldest_pre_issue_id;
        end
        else if (scaiev.decode_flush) begin //Flush all PC assignments, fetches, current decode
            pc_id <= oldest_pre_decode_fetch_id;
            fetch_id <= oldest_pre_decode_fetch_id;
            pre_decode_id <= oldest_pre_decode_fetch_id;
            post_decode_id <= oldest_pre_decode_id;
        end
        else begin
            //scaiev.fetch_flush already factored in to pc_id_assigned
            //In contrast to early_branch_flush, scaiev.fetch_flush only affects uninitiated fetches (before any FIFOs).
            pc_id <= pc_id_incr_wrap;
            fetch_id <= fetch_id_incr_wrap;
            pre_decode_id <= pre_decode_id_incr_wrap;
            post_decode_id <= post_decode_id + LOG2_MAX_IDS'(decode_advance);
        end
    end
    //Retire IDs
    //Each retire port lags behind the previous one by one index (eg. [3, 2, 1, 0])
    //generate for (i = 0; i < RETIRE_PORTS; i++) begin :gen_retire_ids
    for (i = 0; i < RETIRE_PORTS; i++) begin :gen_retire_ids
        always_ff @ (posedge clk) begin
            if (rst)
                retire_ids_next[i] <= LOG2_MAX_IDS'(i);
            else
                retire_ids_next[i] <= retire_ids_next[i] + LOG2_MAX_IDS'(retire_next.count);
        end

        always_ff @ (posedge clk) begin
            if (~gc.retire_hold)
                retire_ids[i] <= retire_ids_next[i];
        end
    end
    //end endgenerate

    //Represented as a negative value so that the MSB indicates that the decode stage is valid
    always_ff @ (posedge clk) begin
        if (gc.fetch_flush | (scaiev.decode_flush | scaiev.issue_flush))
            fetched_count_neg <= 0;
        else
            fetched_count_neg <= fetched_count_neg + ID_COUNTER_FETCH_W'(decode_advance && pop_pre_decode_instr) - ID_COUNTER_FETCH_W'(fetch_complete);
    end

    //Full instruction count split into two: pre-issue and post-issue
    //pre-issue count can be cleared on a fetch flush
    //post-issue count decremented only on retire
    always_comb begin
        pre_issue_count_next = pre_issue_count + ID_COUNTER_FETCH_W'(pc_id_assigned) + ID_COUNTER_FETCH_W'(pc_inject_id_assigned) - ID_COUNTER_FETCH_W'(instruction_issued);
        if (scaiev.decode_flush & ~(gc.fetch_flush | scaiev.issue_flush)) begin
            //Decode flush -> Only what remains in issue stage (and doesn't leave it immediately) is "pre-issue".
            pre_issue_count_next = (issue.stage_valid & ~instruction_issued) ? 1 : 0;
        end
    end
    always_ff @ (posedge clk) begin
        if (gc.fetch_flush | scaiev.issue_flush)
            pre_issue_count <= 0;
        else
            pre_issue_count <= pre_issue_count_next;
    end

    assign post_issue_count_next = post_issue_count + ID_COUNTER_W'(instruction_issued) - ID_COUNTER_W'(retire_next.count);
    always_ff @ (posedge clk) begin
        if (rst)
            post_issue_count <= 0;
        else
            post_issue_count <= post_issue_count_next;
    end

    //Number of regular (i.e. non-injected) instructions that are before retirement and being/having been issued.
    assign post_issue_count_noninject_next = post_issue_count_noninject + ID_COUNTER_W'(instruction_issued && !scaiev.issue_injected) - ID_COUNTER_W'(retire_next_count_noninject);
    //(corresponding registered counter)
    always_ff @ (posedge clk) begin
        if (rst)
            post_issue_count_noninject <= 0;
        else
            post_issue_count_noninject <= post_issue_count_noninject_next;
    end

    //Number of regular (i.e. non-injected) instructions from fetch to before retirement.
    assign inflight_count_noninject_next = inflight_count_noninject + ID_COUNTER_FETCH_W'(pc_id_assigned) - ID_COUNTER_FETCH_W'(retire_next_count_noninject);
    //(corresponding registered counter)
    always_ff @ (posedge clk) begin
        if (gc.fetch_flush | scaiev.issue_flush)
            inflight_count_noninject <= ID_COUNTER_FETCH_W'(post_issue_count_noninject_next);
        else if (scaiev.decode_flush) //Special case: Instruction in Issue stage is not flushed but stalled, hence needs to be added.
            inflight_count_noninject <= post_issue_count_noninject_next + ID_COUNTER_FETCH_W'(issue.stage_valid && !scaiev.issue_injected && !instruction_issued);
        else
            inflight_count_noninject <= inflight_count_noninject_next;
    end

    //always_ff @ (posedge clk) begin
    //    if (gc.fetch_flush | scaiev.issue_flush)
    //        inflight_count <= post_issue_count_next;
    //    else
    //        inflight_count <= pre_issue_count_next + post_issue_count_next;
    //end

    always_comb begin
        post_decode_count_next = post_decode_count + ID_COUNTER_W'(decode_advance && !scaiev.decode_flush) - ID_COUNTER_W'(retire_next.count);
        if (gc.fetch_flush | scaiev.issue_flush) begin
            //Issue flush -> Count only what remains in post-issue stages (and doesn't leave it immediately).
            post_decode_count_next = post_issue_count_next;
        end
    end
    always_ff @ (posedge clk) begin
        if (rst)
            post_decode_count <= 0;
        else
            post_decode_count <= post_decode_count_next;
    end

    ////////////////////////////////////////////////////
    //ID in-use determination
    logic id_waiting_for_writeback [RETIRE_PORTS];
    //WB group zero is not included as it completes within a single cycle
    //Non-writeback instructions not included as current instruction set
    //complete in their first cycle of the execute stage, or do not cause an
    //exception after that point
    toggle_memory_set # (
        .DEPTH (MAX_IDS),
        .NUM_WRITE_PORTS (2),
        .NUM_READ_PORTS (RETIRE_PORTS),
        .WRITE_INDEX_FOR_RESET (0),
        .READ_INDEX_FOR_RESET (0)
    ) id_waiting_for_writeback_toggle_mem_set
    (
        .clk (clk),
        .rst (rst),
        .init_clear (gc.init_clear),
        .toggle ('{(instruction_issued_with_rd & issue.is_multicycle), wb_packet[1].valid}),
        .toggle_addr ('{issue.id, wb_packet[1].id}),
        .read_addr (retire_ids_next),
        .in_use (id_waiting_for_writeback)
    );

    ////////////////////////////////////////////////////
    //Retirer
    logic contiguous_retire;
    logic id_is_post_issue [RETIRE_PORTS];
    logic id_ready_to_retire [RETIRE_PORTS];
    logic [LOG2_RETIRE_PORTS-1:0] phys_id_sel;
    logic [RETIRE_PORTS-1:0] retire_id_uses_rd;
    logic [RETIRE_PORTS-1:0] retire_id_waiting_for_writeback;

    //generate
    for (i = 0; i < RETIRE_PORTS; i++) begin : gen_retire_writeback
        assign retire_id_uses_rd[i] = uses_rd_table[retire_ids_next[i]] || (i == 1 && scaiev.rf_wrReg);
        assign retire_id_waiting_for_writeback[i] = id_waiting_for_writeback[i] || (i == 1 && scaiev.rf_wrReg);
    end// endgenerate

    //Supports retiring up to RETIRE_PORTS instructions.  The retired block of instructions must be
    //contiguous and must start with the first retire port.  Additionally, only one register file writing 
    //instruction is supported per cycle.
    //If an exception is pending, only retire a single intrustuction per cycle.  As such, the pending
    //exception will have to become the oldest instruction retire_ids[0] before it can retire.
    logic retire_with_rd_found;
    logic retire_with_rd_is_scaiev_decoupled;
    always_comb begin
        contiguous_retire = ~gc.retire_hold;
        retire_with_rd_is_scaiev_decoupled = 0;
        retire_with_rd_found = 0;
        for (int i = 0; i < RETIRE_PORTS; i++) begin
            id_is_post_issue[i] = post_issue_count > ID_COUNTER_W'(i);

            id_ready_to_retire[i] = (i == 1 && scaiev.rf_wrReg) || (id_is_post_issue[i] & contiguous_retire & ~id_waiting_for_writeback[i]);
            retire_port_valid_next[i] = id_ready_to_retire[i] & ~(retire_id_uses_rd[i] & retire_with_rd_found);

            retire_with_rd_is_scaiev_decoupled |= (i == 1 && scaiev.rf_wrReg) && !retire_with_rd_found;
            retire_with_rd_found |= (retire_port_valid_next[i] & retire_id_uses_rd[i]) || (i == 1 && scaiev.rf_wrReg);
            contiguous_retire &= retire_port_valid_next[i] & ~gc.exception_pending;
        end
    end

    //retire_next packet
    priority_encoder #(.WIDTH(RETIRE_PORTS))
    phys_id_sel_encoder (
        .priority_vector (retire_id_uses_rd),
        .encoded_result (phys_id_sel)
    );
    assign retire_next.phys_id = retire_ids_next[phys_id_sel];
    assign retire_next.valid = retire_with_rd_found && !retire_with_rd_is_scaiev_decoupled;

    always_comb begin
        retire_next.count = 0;
        retire_next_count_noninject = 0;
        for (int i = 0; i < RETIRE_PORTS; i++) begin
            retire_next.count += retire_port_valid_next[i] && (i != 1 || !scaiev.rf_wrReg);
            retire_next_count_noninject += retire_port_valid_next[i] && pops_fetch_id[retire_ids_next[i]] && (i != 1 || !scaiev.rf_wrReg);
        end
    end

    always_ff @ (posedge clk) begin
        retire.valid <= retire_next.valid;
        retire.phys_id <= retire_next.phys_id;
        retire.count <= gc.writeback_supress ? '0 : retire_next.count;
        for (int i = 0; i < RETIRE_PORTS; i++)
            retire_port_valid[i] <= (retire_port_valid_next[i] & ~gc.writeback_supress) && (i != 1 || !scaiev.rf_wrReg);
    end
    assign scaiev.retire_ID = retire_ids_next[0];
    assign scaiev.retire_count = retire_next.count;
    assign scaiev.retire_suppress = gc.writeback_supress;

    ////////////////////////////////////////////////////
    //Outputs

    //SCAIE-V: Allow pre-decode ID space to be used up independently of post-decode IDs.
    assign pc_id_available = ((1<<LOG2_MAX_IDS_FETCH) == MAX_IDS_FETCH) ? (~inflight_count_noninject[LOG2_MAX_IDS_FETCH]) : (inflight_count_noninject <= MAX_IDS_FETCH);
    //assign pc_id_available = ~inflight_count[LOG2_MAX_IDS];
    assign pc_inject_id_available = ~post_decode_count[LOG2_MAX_IDS];

    //Decode
    assign decode.id = post_decode_id;
    //-> SCAIE-V: Stall decode if no post-decode ID is available - possible due to Decode Inject.
    assign decode.valid = fetched_count_neg[LOG2_MAX_IDS_FETCH]
        && ~post_decode_count[LOG2_MAX_IDS];// && (pc_inject_id_assigned ? (post_decode_count[LOG2_MAX_IDS-1:0] != {LOG2_MAX_IDS{1'b1}}) : 1);
    assign decode.pc = pc_table[pre_decode_id];
    assign decode.pc_id = pre_decode_id;
    assign decode.instruction = instruction_table[pre_decode_id];
    assign decode.fetch_metadata = CONFIG.INCLUDE_M_MODE ? fetch_metadata_table[pre_decode_id] : '{ok : 1, error_code : INST_ACCESS_FAULT};

    //Writeback/Commit support
    phys_addr_t commit_phys_addr [CONFIG.NUM_WB_GROUPS];
    assign commit_phys_addr[0] = issue.phys_rd_addr;
    //generate
    for (i = 1; i < CONFIG.NUM_WB_GROUPS; i++) begin : gen_commit_phys_addr
        assign commit_phys_addr[i] = phys_addr_table[wb_packet[i].id];
    end// endgenerate

    //generate
    for (i = 0; i < CONFIG.NUM_WB_GROUPS; i++) begin : gen_commit_packet
        assign commit_packet[i].id = wb_packet[i].id;
        assign commit_packet[i].phys_addr = (i == 1 && scaiev.rf_wrReg) ? scaiev.rf_wrReg_phys_RD : commit_phys_addr[i];
        assign commit_packet[i].valid = (i == 1 && scaiev.rf_wrReg) || (wb_packet[i].valid & |commit_phys_addr[i]);
        assign commit_packet[i].data = (i == 1 && scaiev.rf_wrReg) ? scaiev.rf_wrReg_data : wb_packet[i].data;
    end// endgenerate
    assign scaiev.rf_ready = wb_is_stallable && !retire.valid;

    //Exception Support
    //generate
    if (CONFIG.INCLUDE_M_MODE) begin : gen_id_exception_support
        assign oldest_pc = pc_table[pc_fetch_id_translation[retire_ids_next[0]]];
        assign current_exception_unit = exception_unit_table[retire_ids_next[0]];
    end// endgenerate

    ////////////////////////////////////////////////////
    //End of Implementation
    ////////////////////////////////////////////////////

    ////////////////////////////////////////////////////
    //Assertions
    pc_id_assigned_without_pc_id_available_assertion:
        assert property (@(posedge clk) disable iff (rst) !(~pc_id_available & pc_id_assigned))
        else $error("Pre-decode ID assigned without any ID available");

    inject_pc_id_assigned_without_pc_id_available_assertion:
        assert property (@(posedge clk) disable iff (rst) !(~pc_inject_id_available & decode_advance)) //SCAIE-V
        else $error("Post-decode ID assigned without any ID available");

    decode_advanced_without_id_assertion:
        assert property (@(posedge clk) disable iff (rst) !(~decode.valid & ~pc_inject_id_assigned & decode_advance))
        else $error("Decode advanced without ID");

    if ((1<<LOG2_MAX_IDS_FETCH) > MAX_IDS_FETCH) begin
        pc_id_out_of_range_assertion:
            assert property (@(posedge clk) disable iff (rst) !(pc_id >= MAX_IDS_FETCH))
            else $error("pc_id out of range");
        fetch_id_out_of_range_assertion:
            assert property (@(posedge clk) disable iff (rst) !(fetch_id >= MAX_IDS_FETCH))
            else $error("fetch_id out of range");
        decode_pc_id_out_of_range_assertion:
            assert property (@(posedge clk) disable iff (rst) !(decode.pc_id >= MAX_IDS_FETCH))
            else $error("decode.pc_id out of range");
    end

end endgenerate
endmodule
