/** 
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
 */

package scaiev_types; //SCAIE-V
    import riscv_types::*;
    import csr_types::*;
    
    typedef struct packed{
        logic is_scaiev;
        logic decoupled;
        logic fromstage; //0: Issue; 1: Execute
    } scaiev_ls_meta_t;

    typedef struct packed{
        logic [XLEN-1:0] rs1;
        logic [XLEN-1:0] rs2;
        logic [XLEN-1:0] rd_as_rs;
        logic [31:0] instruction;
        logic [31:0] pc;
        logic uses_rd;
    } scaiev_inputs_t;

endpackage

interface scaiev_interface; //Stage valid signals refer to any instruction.
    import cva5_config::*;
    localparam LOG2_MAX_IDS_FETCH = $clog2(MAX_IDS_FETCH);
    localparam LOG2_MAX_IDS = $clog2(MAX_IDS);

    logic [31:0] pre_fetch_PC;
    logic pre_fetch_isStalling;

    logic [31:0] fetch_PC; //The PC that CVA5 would start a fetch from in the current clock cycle (unless stalled/flushed).
    //logic [31:0] fetch_nextPC; //The next PC that CVA5 would attempt to fetch from, can be overridden combinationally with fetch_wrPC.
    logic fetch_valid;
    logic [LOG2_MAX_IDS_FETCH-1:0] fetch_fetchID; //The assigned fetch ID
    logic fetch_isStalling;
    logic fetch_stall;
    logic fetch_isFlushing;
    logic fetch_isFlushing_internal; //Without comb. dependency on fetch_flush, decode_flush, issue_flush.
    logic fetch_flush;
    logic [LOG2_MAX_IDS_FETCH-1:0] fetch_fetchFlushID; //The oldest fetch ID to flush if flushing
    logic [$clog2(MAX_IDS_FETCH+1)-1:0] fetch_fetchFlushCount; //The number of fetch IDs being flushed, starting with fetch_fetchID.
    //fetch_wrPC overrides pre_fetch_PC combinationally and fetch_PC synchronously (i.e. starting with the next cycle).
    logic [31:0] fetch_wrPC; //Must be 4-byte aligned (i.e. fetch_wrPC[1:0] = 'b00). 
    logic fetch_wrPCValid; //Must not be set without fetch_flush or superset flushes.

    logic [31:0] decode_PC; //Shows original value; Not relevant for current cycle if decode_wrReg or decode_rdReg.
    logic [31:0] decode_Instr; //Shows original value; Not relevant for current cycle if decode_wrReg or decode_rdReg.
    logic decode_valid; //Set if an actual instruction would enter decode (not affected by decode_wrReg or decode_rdReg).
    logic [LOG2_MAX_IDS_FETCH-1:0] decode_fetchID; //The fetch ID corresponding to the current instruction
    logic decode_RS1_valid; //Is RS1 used? (only valid if decode_valid, affected by decode_isSCAIEV_usesRS1)
    logic [4:0] decode_RS1_id; //RS1 register number
    logic decode_RS2_valid;
    logic [4:0] decode_RS2_id;
    logic decode_RD_AS_RS_valid;
    logic [4:0] decode_RD_AS_RS_id;
    logic decode_RD_valid;
    logic [4:0] decode_RD_id;
    logic decode_isSCAIEV; //Written by SCAL/ISAX
    logic decode_isSCAIEV_stdencoding; //Written by SCAL/ISAX
    logic decode_isSCAIEV_usesRS1; //Written by SCAL/ISAX
    logic decode_isSCAIEV_usesRS2; //Written by SCAL/ISAX
    logic decode_isSCAIEV_usesRD_AS_RS; //Written by SCAL/ISAX
    logic decode_isSCAIEV_usesRD; //Written by SCAL/ISAX. Set only for ISAXes that (always!) use execute_wrRD.
    logic decode_isSCAIEV_usesRD_decoupled; //Written by SCAL/ISAX. Set only for decoupled ISAXes that (always!) use rf_wrReg.
    logic decode_isStalling; //Set if nothing from decode enters issue; Not set if an actual or pseudo instruction enters issue.
    logic decode_stall;
    logic decode_isFlushing;
    logic decode_isFlushing_internal; //Without comb. dependency on decode_flush, issue_flush.
    logic decode_flush;

    //Operations that internally inject a pseudo ALU instruction into decode stage.
    // Actual instructions about to enter Decode (decode_PC, decode_Instr, decode_valid) will be stalled.
    // To apply the operation, hold the signals until !decode_stall. Combinational dependency on decode_stall is NOT allowed.
    //These operations will cause a valid issue (unless flushed).
    //NOTE: During these operations, decode_valid is either false, or decode_PC and decode_Instr show the next 'actual instruction'.
    //NOTE: issue_PC will be invalid, and issue_Instr will have an AUIPC opcode with an invalid immediate.
    //      -> issue_injected is set in that case.
    logic decode_wrReg;
    logic [4:0] decode_wrReg_RD;
    logic [31:0] decode_wrReg_data; 
    //Initiates register read. If set, next valid issue will have requested values in issue_RS1, issue_RS2.
    logic decode_rdReg;
    logic [4:0] decode_rdReg_RS1;
    logic [4:0] decode_rdReg_RS2;
    logic [4:0] decode_rdReg_RD_AS_RS;
    //Repeats the instruction in the next decode cycle, if the current instance is about to be passed on to Issue. Ignored if decode_wrReg or decode_rdReg.
    logic decode_repeat_next; 
    logic decode_RS1_override; //Override RS1 of the current instruction with decode_rdReg_RS1.
    logic decode_RS2_override; //Override RS2 of the current instruction with decode_rdReg_RS2.
    logic decode_RD_AS_RS_override; //Override RD as read reg of the current instruction with decode_rdReg_RD.
    logic decode_skip_wb; //Treat instruction as not having a writeback field. Ignored for decode_wrReg.

    logic [5:0] decode_phys_RD_decoupled; //Physical register ID for the current decoupled ISAX  (actual CVA5 type: phys_addr_t).
    logic [6:0] decode_prev_phys_RD_decoupled; //Register allocation metadata: Old physical register ID that the current ISAX will override  (actual CVA5 type: {$type(renamer_metadata_t.previous_wb_group), phys_addr_t}).

    logic [5:0] issue_phys_RD_decoupled; //Physical register ID for the current decoupled ISAX  (actual CVA5 type: phys_addr_t).
    logic [6:0] issue_prev_phys_RD_decoupled; //Register allocation metadata: Old physical register ID that the current ISAX will override  (actual CVA5 type: {$type(renamer_metadata_t.previous_wb_group), phys_addr_t}).

    logic rf_wrReg; //Writes and unlocks a physical register.
    logic rf_wrReg_cancel; //Writeback is cancelled by the core; Frees the physical destination register instead of its predecessor.
    logic [5:0] rf_wrReg_phys_RD; //Physical register ID previously obtained from issue_phys_RD_decoupled
    logic [6:0] rf_wrReg_prev_phys_RD; //Physical register ID previously obtained from issue_prev_phys_RD_decoupled
    logic [31:0] rf_wrReg_data; //Data to write.
    logic rf_ready; //Whether the register file is ready for a decoupled write.
    logic rf_isDecoupledWB; //Indicates if a decoupled instruction has finished and writes back via ENABLE_DECOUPLED_WRITEBACK. Sampled on rf_wrReg && rf_ready.

    logic renamer_addtofree_valid;
    logic [5:0] renamer_addtofree_reg;
    logic renamer_addtofree_skip;

    //TODO: Interface to handle exceptions/interrupts for decoupled ISAX
    //- Need to kill exactly the ISAX issued at and after the execution 'cut off'.
    //- Need to wait for the other decoupled ISAX to complete, before entering the handler routine.

    logic [LOG2_MAX_IDS-1:0] issue_ID;
    logic [LOG2_MAX_IDS-1:0] issue_flushID;
    logic [31:0] issue_PC;
    logic [31:0] issue_Instr;
    //issue_RS1_valid is set whenever no conflict occurs.
    //If the instr. does not use RS1, the value will still be undefined regardless.
    logic issue_RS1_valid;
    logic [31:0] issue_RS1;
    //issue_RS2_valid is set whenever no conflict occurs.
    //If the instr. does not use RS2, the value will still be undefined regardless.
    logic issue_RS2_valid;
    logic [31:0] issue_RS2;
    logic issue_RD_AS_RS_valid;
    logic [31:0] issue_RD_AS_RS;
    logic issue_RD_valid;
    logic [4:0] issue_RD_id;
    logic issue_valid;
    logic issue_injected;
    logic issue_isSCAIEV; //Written by Core (1 only if decode_isSCAIEV was set for previous stage)
    logic issue_isLS; //Indicates if the current instruction would issue into the LSU (only meaningful if issue_valid).
    logic issue_isStalling;
    logic issue_stall;
    logic issue_isFlushing;
    logic issue_isFlushing_internal; //Without comb. dependency on issue_flush.
    logic issue_flush;

    //REQUIRES active issue_stall (from first cycle where ISAX entered execute).
    //Recommendation: Use only one of either issue_injectLS or execute_injectLS if possible, to save on LUTs&routes.
    logic issue_injectLS_potentiallyValid; //Must be set together with issue_stall. execute_injectLS takes precedence.
    logic issue_injectLS_valid; //Can use injectLS_ready combinationally.
    logic issue_injectLS_decoupled;
    logic issue_injectLS_rnw;
    logic issue_injectLS_relaxedOrdering; //If set, current load request will not be checked for conflicts against stores waiting to be submitted.
    logic [31:0] issue_injectLS_addr;
    logic [31:0] issue_injectLS_storeVal;
    logic issue_injectLS_done;

    //SCAIE-V only stage (custom execution unit, separate from CVA5's, only for 'coupled execution')
    //-> 'execute_valid' means that an ISAX is in execute stage.
    logic [31:0] execute_PC; //Costly (1 reg, or extra read port in instruction_metadata_and_id_management)
    logic [31:0] execute_Instr; //Costly (1 reg, or extra read port in instruction_metadata_and_id_management)
    logic [31:0] execute_RS1; //Costly (1 reg)
    logic [31:0] execute_RS2; //Costly (1 reg)
    logic [31:0] execute_RD_AS_RS; //Costly (1 reg)
    logic [LOG2_MAX_IDS-1:0] execute_ID; //The issue ID corresponding to the current instruction
    logic [LOG2_MAX_IDS-1:0] execute_ID_or_counter; //The issue ID corresponding to the current instruction, or a fake counter
    logic execute_expects_rd; //If set, execute_ID_or_counter is the actual issue ID; otherwise, it is a fake counter
    logic execute_valid;
    //REQUIRES active issue_stall from first cycle where ISAX entered execute.
    logic execute_flush; //On execute_isFlushing == execute_flush
    logic execute_stall;
    logic execute_isStalling;
    logic execute_isStalling_reason_isax;
    logic execute_isStalling_reason_core;
    //Must only be used if execute_wrRD was set when the instruction was in ISAX stage.
    //Once per instruction. Any additional wrRD after execute_stall overwrites the previous one.
    logic execute_wrRD; //If not set during activity in Execute, will implicitly stall the execute stage.
    logic [31:0] execute_wrRD_data;
    logic execute_deq; //Makes the execution unit forget about the current instruction (without committing it).
    logic execute_commitNow; //Requests a commit with overridden ID.
    logic [LOG2_MAX_IDS-1:0] execute_commitNow_ID; //Sets the ID to commit with.
    logic execute_commitNow_expects_rd; //If set, the ID is an actual issue ID; otherwise, it indicates that the fake counter value can be freed
    logic execute_commitNow_resp; //Response by the core, indicating whether a commit has been done (regardless of execute_commitNow).

    //Requires active SCAIE-V instruction in Execute. REQUIRES active execute_stall and issue_stall from first cycle where ISAX entered execute.
    logic execute_injectLS_potentiallyValid; //Must be set together with issue_stall, and no other instruction must have passed Issue since the SCAIE-V Execute started.
    logic execute_injectLS_valid; //Can use injectLS_ready combinationally.
    logic execute_injectLS_decoupled;
    logic execute_injectLS_rnw;
    logic execute_injectLS_relaxedOrdering; //If set, current load request will not be checked for conflicts against stores waiting to be submitted.
    logic [31:0] execute_injectLS_addr;
    logic [31:0] execute_injectLS_storeVal;
    logic execute_injectLS_done;
    logic injectLS_done_decoupled;

    //Shared between issue_injectLS and execute_injectLS.
    logic injectLS_ready;
    logic [31:0] injectLS_readData; //validity by *_injectLS_done

    logic no_writebacks_pending; //Set if the core should wait for pending decoupled writebacks -> gc_unit.sv

    logic [2:0] retire_ID; //First ID to retire
    logic [1:0] retire_count; //Number of retires (0,1,2)
    logic retire_suppress; //Set if the retire is a flush.
    
    modport core (input fetch_stall, fetch_flush, fetch_wrPC, fetch_wrPCValid,
            decode_isSCAIEV, decode_isSCAIEV_stdencoding, decode_isSCAIEV_usesRS1, decode_isSCAIEV_usesRS2, decode_isSCAIEV_usesRD_AS_RS, decode_isSCAIEV_usesRD, decode_isSCAIEV_usesRD_decoupled, decode_stall, decode_flush,
            decode_wrReg, decode_wrReg_RD, decode_wrReg_data, decode_rdReg, decode_rdReg_RS1, decode_rdReg_RS2, decode_rdReg_RD_AS_RS, decode_repeat_next, decode_RS1_override, decode_RS2_override, decode_RD_AS_RS_override, decode_skip_wb,
            issue_stall, issue_flush, issue_injectLS_potentiallyValid, issue_injectLS_valid, issue_injectLS_decoupled, issue_injectLS_rnw, issue_injectLS_relaxedOrdering, issue_injectLS_addr, issue_injectLS_storeVal,
            execute_flush, execute_stall, execute_wrRD, execute_wrRD_data, execute_deq, execute_commitNow, execute_commitNow_ID, execute_commitNow_expects_rd, execute_injectLS_potentiallyValid, execute_injectLS_valid, execute_injectLS_decoupled, execute_injectLS_rnw, execute_injectLS_relaxedOrdering, execute_injectLS_addr, execute_injectLS_storeVal,
            rf_wrReg, rf_wrReg_cancel, rf_wrReg_phys_RD, rf_wrReg_prev_phys_RD, rf_wrReg_data, rf_isDecoupledWB, renamer_addtofree_skip,
            output pre_fetch_PC, pre_fetch_isStalling, fetch_PC, fetch_valid, fetch_fetchID, fetch_isStalling, fetch_isFlushing, fetch_isFlushing_internal, fetch_fetchFlushID, fetch_fetchFlushCount,
            decode_PC, decode_Instr, decode_valid, decode_fetchID, decode_isStalling, decode_isFlushing, decode_isFlushing_internal,
            decode_RS1_valid, decode_RS1_id, decode_RS2_valid, decode_RS2_id, decode_RD_AS_RS_valid, decode_RD_AS_RS_id, decode_RD_valid, decode_RD_id, decode_phys_RD_decoupled, decode_prev_phys_RD_decoupled,
            issue_ID, issue_flushID, issue_PC, issue_Instr, issue_RS1_valid, issue_RS1, issue_RS2_valid, issue_RS2, issue_RD_AS_RS_valid, issue_RD_AS_RS, issue_RD_valid, issue_RD_id, issue_phys_RD_decoupled, issue_prev_phys_RD_decoupled,
            issue_valid, issue_isSCAIEV, issue_isLS, issue_injected, issue_isStalling, issue_isFlushing, issue_isFlushing_internal, issue_injectLS_done,
            execute_PC, execute_Instr, execute_RS1, execute_RS2, execute_RD_AS_RS, execute_ID, execute_ID_or_counter, execute_expects_rd, execute_valid, execute_isStalling, execute_isStalling_reason_isax, execute_isStalling_reason_core, execute_commitNow_resp, execute_injectLS_done, injectLS_done_decoupled,
            injectLS_ready, injectLS_readData,
            rf_ready, renamer_addtofree_valid, renamer_addtofree_reg, no_writebacks_pending,
            retire_ID, retire_count, retire_suppress);

    modport scal (output fetch_stall, fetch_flush, fetch_wrPC, fetch_wrPCValid,
            decode_isSCAIEV, decode_isSCAIEV_stdencoding, decode_isSCAIEV_usesRS1, decode_isSCAIEV_usesRS2, decode_isSCAIEV_usesRD_AS_RS, decode_isSCAIEV_usesRD, decode_isSCAIEV_usesRD_decoupled, decode_stall, decode_flush,
            decode_wrReg, decode_wrReg_RD, decode_wrReg_data, decode_rdReg, decode_rdReg_RS1, decode_rdReg_RS2, decode_rdReg_RD_AS_RS, decode_repeat_next, decode_RS1_override, decode_RS2_override, decode_RD_AS_RS_override, decode_skip_wb,
            issue_stall, issue_flush, issue_injectLS_potentiallyValid, issue_injectLS_valid, issue_injectLS_decoupled, issue_injectLS_rnw, issue_injectLS_relaxedOrdering, issue_injectLS_addr, issue_injectLS_storeVal,
            execute_flush, execute_stall, execute_wrRD, execute_wrRD_data, execute_deq, execute_commitNow, execute_commitNow_ID, execute_commitNow_expects_rd, execute_injectLS_potentiallyValid, execute_injectLS_valid, execute_injectLS_decoupled, execute_injectLS_rnw, execute_injectLS_relaxedOrdering, execute_injectLS_addr, execute_injectLS_storeVal,
            rf_wrReg, rf_wrReg_cancel, rf_wrReg_phys_RD, rf_wrReg_prev_phys_RD, rf_wrReg_data, rf_isDecoupledWB, renamer_addtofree_skip,
            input pre_fetch_PC, pre_fetch_isStalling, fetch_PC, fetch_valid, fetch_fetchID, fetch_isStalling, fetch_isFlushing, fetch_isFlushing_internal, fetch_fetchFlushID, fetch_fetchFlushCount,
            decode_PC, decode_Instr, decode_valid, decode_fetchID, decode_isStalling, decode_isFlushing, decode_isFlushing_internal,
            decode_RS1_valid, decode_RS1_id, decode_RS2_valid, decode_RS2_id, decode_RD_AS_RS_valid, decode_RD_AS_RS_id, decode_RD_valid, decode_RD_id, decode_phys_RD_decoupled, decode_prev_phys_RD_decoupled,
            issue_ID, issue_flushID, issue_PC, issue_Instr, issue_RS1_valid, issue_RS1, issue_RS2_valid, issue_RS2, issue_RD_AS_RS_valid, issue_RD_AS_RS, issue_RD_valid, issue_RD_id, issue_phys_RD_decoupled, issue_prev_phys_RD_decoupled,
            issue_valid, issue_isSCAIEV, issue_isLS, issue_injected, issue_isStalling, issue_isFlushing, issue_isFlushing_internal, issue_injectLS_done,
            execute_PC, execute_Instr, execute_RS1, execute_RS2, execute_RD_AS_RS, execute_ID, execute_ID_or_counter, execute_expects_rd, execute_valid, execute_isStalling, execute_isStalling_reason_isax, execute_isStalling_reason_core, execute_commitNow_resp, execute_injectLS_done, injectLS_done_decoupled,
            injectLS_ready, injectLS_readData,
            rf_ready, renamer_addtofree_valid, renamer_addtofree_reg, no_writebacks_pending,
            retire_ID, retire_count, retire_suppress);

    modport trace_out (output fetch_stall, fetch_flush, fetch_wrPC, fetch_wrPCValid,
            decode_isSCAIEV, decode_isSCAIEV_stdencoding, decode_isSCAIEV_usesRS1, decode_isSCAIEV_usesRS2, decode_isSCAIEV_usesRD_AS_RS, decode_isSCAIEV_usesRD, decode_isSCAIEV_usesRD_decoupled, decode_stall, decode_flush,
            decode_wrReg, decode_wrReg_RD, decode_wrReg_data, decode_rdReg, decode_rdReg_RS1, decode_rdReg_RS2, decode_rdReg_RD_AS_RS, decode_repeat_next, decode_RS1_override, decode_RS2_override, decode_RD_AS_RS_override, decode_skip_wb,
            issue_stall, issue_flush, issue_injectLS_potentiallyValid, issue_injectLS_valid, issue_injectLS_decoupled, issue_injectLS_rnw, issue_injectLS_relaxedOrdering, issue_injectLS_addr, issue_injectLS_storeVal,
            execute_flush, execute_stall, execute_wrRD, execute_wrRD_data, execute_deq, execute_commitNow, execute_commitNow_ID, execute_commitNow_expects_rd, execute_injectLS_potentiallyValid, execute_injectLS_valid, execute_injectLS_decoupled, execute_injectLS_rnw, execute_injectLS_relaxedOrdering, execute_injectLS_addr, execute_injectLS_storeVal,
            rf_wrReg, rf_wrReg_cancel, rf_wrReg_phys_RD, rf_wrReg_prev_phys_RD, rf_wrReg_data, rf_isDecoupledWB, renamer_addtofree_skip,
            pre_fetch_PC, pre_fetch_isStalling, fetch_PC, fetch_valid, fetch_fetchID, fetch_isStalling, fetch_isFlushing, fetch_isFlushing_internal, fetch_fetchFlushID, fetch_fetchFlushCount,
            decode_PC, decode_Instr, decode_valid, decode_fetchID, decode_isStalling, decode_isFlushing, decode_isFlushing_internal,
            decode_RS1_valid, decode_RS1_id, decode_RS2_valid, decode_RS2_id, decode_RD_AS_RS_valid, decode_RD_AS_RS_id, decode_RD_valid, decode_RD_id, decode_phys_RD_decoupled, decode_prev_phys_RD_decoupled,
            issue_ID, issue_flushID, issue_PC, issue_Instr, issue_RS1_valid, issue_RS1, issue_RS2_valid, issue_RS2, issue_RD_AS_RS_valid, issue_RD_AS_RS, issue_RD_valid, issue_RD_id, issue_phys_RD_decoupled, issue_prev_phys_RD_decoupled,
            issue_valid, issue_isSCAIEV, issue_isLS, issue_injected, issue_isStalling, issue_isFlushing, issue_isFlushing_internal, issue_injectLS_done,
            execute_PC, execute_Instr, execute_RS1, execute_RS2, execute_RD_AS_RS, execute_ID, execute_ID_or_counter, execute_expects_rd, execute_valid, execute_isStalling, execute_isStalling_reason_isax, execute_isStalling_reason_core, execute_commitNow_resp, execute_injectLS_done, injectLS_done_decoupled,
            injectLS_ready, injectLS_readData,
            rf_ready, renamer_addtofree_valid, renamer_addtofree_reg, no_writebacks_pending,
            retire_ID, retire_count, retire_suppress);
endinterface
