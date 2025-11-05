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

module store_queue

    import cva5_config::*;
    import riscv_types::*;
    import cva5_types::*;

    # (
        parameter cpu_config_t CONFIG = EXAMPLE_CONFIG
    )
    ( 
        input logic clk,
        input logic rst,
        input gc_outputs_t gc,

        input logic lq_push,
        input logic lq_pop,
        input logic lq_push_no_conflict, //SCAIE-V
        store_queue_interface.queue sq,

        //Address hash (shared by loads and stores)
        input addr_hash_t addr_hash,
        //hash check on adding a load to the queue
        output logic [CONFIG.SQ_DEPTH-1:0] potential_store_conflicts,
        //Load issue collision check
        input logic [CONFIG.SQ_DEPTH-1:0] prev_store_conflicts,
        output logic store_conflict,

        //Writeback snooping
        input wb_forward_packet_t wb_snoop,

        //Retire
        input id_t retire_ids [RETIRE_PORTS],
        input logic retire_port_valid [RETIRE_PORTS]
    );

    localparam LOG2_SQ_DEPTH = $clog2(CONFIG.SQ_DEPTH);
    typedef logic [LOG2_MAX_IDS:0] load_check_count_t;


    wb_forward_packet_t wb_snoop_r;

    //Register-based memory blocks
    logic [CONFIG.SQ_DEPTH-1:0] valid;
    logic [CONFIG.SQ_DEPTH-1:0] valid_next;
    addr_hash_t [CONFIG.SQ_DEPTH-1:0] hashes;
    logic [CONFIG.SQ_DEPTH-1:0] released;
    forward_id_t [CONFIG.SQ_DEPTH-1:0] id_needed;
    logic [CONFIG.SQ_DEPTH-1:0] forward_complete;
    load_check_count_t [CONFIG.SQ_DEPTH-1:0] load_check_count;
    logic [31:0] store_data_from_wb [CONFIG.SQ_DEPTH];

    //LUTRAM-based memory blocks
    sq_entry_t sq_entry_in;
    (* ramstyle = "MLAB, no_rw_check" *) logic [$bits(sq_entry_t)-1:0] sq_entry [CONFIG.SQ_DEPTH];
    (* ramstyle = "MLAB, no_rw_check" *) id_t [CONFIG.SQ_DEPTH-1:0] ids;
    (* ramstyle = "MLAB, no_rw_check" *) logic [LOG2_SQ_DEPTH-1:0] sq_ids [MAX_IDS];

    load_check_count_t [CONFIG.SQ_DEPTH-1:0] load_check_count_next;

    logic [LOG2_SQ_DEPTH-1:0] sq_index;
    logic [LOG2_SQ_DEPTH-1:0] sq_index_next;
    logic [LOG2_SQ_DEPTH-1:0] sq_oldest;

    logic [CONFIG.SQ_DEPTH-1:0] new_request_one_hot;
    logic [CONFIG.SQ_DEPTH-1:0] new_request_released_one_hot; //SCAIE-V
    logic [CONFIG.SQ_DEPTH-1:0] issued_one_hot;


    logic [CONFIG.SQ_DEPTH-1:0] wb_id_match;

    ////////////////////////////////////////////////////
    //Implementation     
    assign sq_index_next = sq_index +LOG2_SQ_DEPTH'(sq.push);
    always_ff @ (posedge clk) begin
        if (rst)
            sq_index <= 0;
        else
            sq_index <= sq_index_next;
    end

    always_ff @ (posedge clk) begin
        if (rst)
            sq_oldest <= 0;
        else
            sq_oldest <= sq_oldest +LOG2_SQ_DEPTH'(sq.pop);
    end

    assign new_request_one_hot = CONFIG.SQ_DEPTH'(sq.push) << sq_index;
    //Immediately mark new requests from SCAIE-V injected LS as 'released':
    // The store data from a SCAIE-V instruction is known at this point and does not need to wait for forwarding.
    assign new_request_released_one_hot = new_request_one_hot & {CONFIG.SQ_DEPTH{sq.data_in.scaiev_meta.is_scaiev}}; //SCAIE-V
    assign issued_one_hot = CONFIG.SQ_DEPTH'(sq.pop) << sq_oldest;

    assign valid_next = (valid | new_request_one_hot) & ~issued_one_hot;
    always_ff @ (posedge clk) begin
        if (rst)
            valid <= '0;
        else
            valid <= valid_next;
    end

    assign sq.empty = ~|valid;

    always_ff @ (posedge clk) begin
        if (rst)
            sq.full <= 0;
        else
            sq.full <= valid_next[sq_index_next] | (|load_check_count_next[sq_index_next]);
    end

    //SQ attributes and issue data
    assign sq_entry_in = '{
        addr : sq.data_in.addr,
        be : sq.data_in.be,
        fn3 : sq.data_in.fn3,
        forwarded_store : sq.data_in.forwarded_store,
        data : sq.data_in.data
    };
    always_ff @ (posedge clk) begin
        if (sq.push)
            sq_entry[sq_index] <= sq_entry_in;
    end

    //Hash mem
    always_ff @ (posedge clk) begin
        if (sq.push)
            hashes[sq_index] <= addr_hash;
    end

    //Keep count of the number of pending loads that might need a store result
    //Mask out any store completing on this cycle
    logic [CONFIG.SQ_DEPTH-1:0] new_load_waiting;
    logic [CONFIG.SQ_DEPTH-1:0] waiting_load_completed;

    always_comb begin
        for (int i = 0; i < CONFIG.SQ_DEPTH; i++) begin
            potential_store_conflicts[i] = (valid[i] & ~issued_one_hot[i]) & (addr_hash == hashes[i]) & ~lq_push_no_conflict;
            new_load_waiting[i] = potential_store_conflicts[i] & lq_push;
            waiting_load_completed[i] = prev_store_conflicts[i] & lq_pop;

            load_check_count_next[i] =
                load_check_count[i]
                + LOG2_MAX_IDS'(new_load_waiting[i])
                - LOG2_MAX_IDS'(waiting_load_completed[i]);
        end
    end
    always_ff @ (posedge clk) begin
        if (rst)
            load_check_count <= '0;
        else
            load_check_count <= load_check_count_next;
    end

    //If a potential blocking store has not been issued yet, the load is blocked until the store(s) complete
    assign store_conflict = |(prev_store_conflicts & valid);

    ////////////////////////////////////////////////////
    //ID Handling

    //sq_id to global_id mem
    always_ff @ (posedge clk) begin
        if (sq.push)
            ids[sq_index] <= sq.data_in.id;
    end
    // global_id to sq_id mem
    always_ff @ (posedge clk) begin
        if (sq.push)
            sq_ids[sq.data_in.id] <= sq_index;
    end
    //waiting on ID mem
    always_ff @ (posedge clk) begin
        if (sq.push)
            id_needed[sq_index] <= sq.data_in.id_needed;
    end

    ////////////////////////////////////////////////////
    //Release Handling
    logic [CONFIG.SQ_DEPTH-1:0] newly_released;
    logic [LOG2_SQ_DEPTH-1:0] store_released_index [RETIRE_PORTS];
    logic store_released [RETIRE_PORTS];
    always_comb begin
        newly_released = '0;
        for (int i = 0; i < RETIRE_PORTS; i++) begin
            store_released_index[i] = sq_ids[retire_ids[i]];            
            store_released[i] = {1'b1, ids[store_released_index[i]]} == {retire_port_valid[i], retire_ids[i]};
            newly_released |= CONFIG.SQ_DEPTH'(store_released[i]) << store_released_index[i];
        end
    end
    always_ff @ (posedge clk) begin
        released <= ((released | newly_released) & ~new_request_one_hot) | new_request_released_one_hot;
    end

    assign sq.no_released_stores_pending = ~|(valid & released);

    ////////////////////////////////////////////////////
    //Forwarded Store Data

    //SCAIE-V: Wait for forward from decoupled (i.e. out-of-order) writeback.
    //Stock behaviour of CVA5 is to wait until the store instruction is retired,
    // which for *in-order* writebacks ensures that everything from before the store is done,
    // but not for SCAIE-V's decoupled writebacks.
    logic [CONFIG.SQ_DEPTH-1:0] store_snoop_pending;
    always_ff @(posedge clk) begin
        if (wb_snoop_r.valid && !wb_snoop_r.id.is_from_instruction) begin
            for (int i = 0; i < CONFIG.SQ_DEPTH; i++) begin
                if (wb_snoop_r.id.id.register_addr == id_needed[i].id.register_addr) begin
                    store_snoop_pending[i] <= 0;
                end
            end
        end
        if (sq.push)
            store_snoop_pending[sq_index] <= sq.data_in.forwarded_store && !sq.data_in.id_needed.is_from_instruction;
    end

    always_ff @ (posedge clk) begin
        wb_snoop_r <= wb_snoop;
    end

    logic [CONFIG.SQ_DEPTH-1:0] applying_wb_snoop;
    always_comb begin
        for (int i = 0; i < CONFIG.SQ_DEPTH; i++) begin
            applying_wb_snoop[i] = 1'b0;
            if (!(released[i] && id_needed[i].is_from_instruction)
                && !forward_complete[i]
                && wb_snoop_r.valid
                && (wb_snoop_r.id.is_from_instruction == id_needed[i].is_from_instruction)
                && (wb_snoop_r.id.is_from_instruction
                   ? wb_snoop_r.id.id.instruction.id == id_needed[i].id.instruction.id
                   : wb_snoop_r.id.id.register_addr == id_needed[i].id.register_addr
                )) begin
                applying_wb_snoop[i] = 1'b1;
            end
        end
    end
    always_ff @ (posedge clk) begin
        for (int i = 0; i < CONFIG.SQ_DEPTH; i++) begin
            if (gc.init_clear)
                forward_complete[i] <= 1'b1;
            else if (sq.push && i==sq_index)
                forward_complete[i] <= 1'b0;
            else if (applying_wb_snoop[i])
                forward_complete[i] <= 1'b1;
        end
    end

    always_ff @ (posedge clk) begin
        for (int i = 0; i < CONFIG.SQ_DEPTH; i++) begin
            if (gc.init_clear)
                store_data_from_wb[i] <= '0;
            else if (applying_wb_snoop[i])
                store_data_from_wb[i] <= wb_snoop_r.data;
        end
    end
    
    ////////////////////////////////////////////////////
    //Store Transaction Outputs
    logic [31:0] data_for_alignment;
    logic [31:0] sq_data;
    sq_entry_t output_entry;    
    assign output_entry = sq_entry[sq_oldest];

    always_comb begin
        //Input: ABCD
        //Assuming aligned requests,
        //Possible byte selections: (A/C/D, B/D, C/D, D)
        data_for_alignment = output_entry.forwarded_store ? store_data_from_wb[sq_oldest] : output_entry.data;

        sq_data[7:0] = data_for_alignment[7:0];
        sq_data[15:8] = (output_entry.addr[1:0] == 2'b01) ? data_for_alignment[7:0] : data_for_alignment[15:8];
        sq_data[23:16] = (output_entry.addr[1:0] == 2'b10) ? data_for_alignment[7:0] : data_for_alignment[23:16];
        case(output_entry.addr[1:0])
            2'b10 : sq_data[31:24] = data_for_alignment[15:8];
            2'b11 : sq_data[31:24] = data_for_alignment[7:0];
            default : sq_data[31:24] = data_for_alignment[31:24];
        endcase
    end

    assign sq.valid = valid[sq_oldest] & released[sq_oldest] & ~store_snoop_pending[sq_oldest];
    assign sq.data_out = '{
        addr : output_entry.addr,
        be : output_entry.be,
        fn3 : output_entry.fn3,
        forwarded_store : output_entry.forwarded_store,
        data : sq_data
    };

    ////////////////////////////////////////////////////
    //End of Implementation
    ////////////////////////////////////////////////////

    ////////////////////////////////////////////////////
    //Assertions
`ifndef DISABLE_ASSERT_PROPERTY
    sq_overflow_assertion:
        assert property (@(posedge clk) disable iff (rst) sq.push |-> (~sq.full | sq.pop)) else $error("sq overflow");
    fifo_underflow_assertion:
        assert property (@(posedge clk) disable iff (rst) sq.pop |-> sq.valid) else $error("sq underflow");
`endif

endmodule
