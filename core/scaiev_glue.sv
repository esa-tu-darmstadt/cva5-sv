//SCAIE-V: Hazard Unit for decoupled instructions.
//Prevents multi-cycle ISAX instructions 

module scaiev_glue
    import cva5_config::*;
    import riscv_types::*;
    import cva5_types::*;
    import scaiev_types::*;
    import scaiev_config::*;

    # (
        parameter cpu_config_t CONFIG = EXAMPLE_CONFIG
    )

    (
        input logic clk,
        input logic rst,

        scaiev_interface.scal scaiev,
        output logic [12:0] WrRD_spawn_issue_addr_o
    );

    logic hazard_unit_scaiev_decode_stall_set;

    //Indicates if an ISAX instruction has entered decode and is not overridden.
    wire decode_valid_regular = scaiev.decode_valid && !(scaiev.decode_wrReg || scaiev.decode_rdReg);

    //Condition 'is ISAX that will use scaiev.decode_wrReg', to be set correctly by SCAIE-V.
    wire decode_is_isax_decoupled_wb = 0;
    //Condition 'is ISAX that will use scaiev.rf_wrReg in Issue and not flushed/stalled', to be set correctly by SCAIE-V.
    wire issue_is_isax_decoupled_wb = 0;
    //Condition 'unlock all registers' (e.g. 'all WrRD_spawn ISAXes killed').
    wire unlock_all_registers = 0;
    //Condition 'inject-based writeback cancelled' (only unlock, don't write)
    logic decode_wrReg_cancel;

    generate if (ENABLE_SCAIEV_REGHAZARD) begin
        
        logic [4:0] rd_last_locked;
        logic rd_inuse_bitmap [32];
        always_ff @(posedge clk) begin
            if (scaiev.issue_isFlushing && rd_last_locked != '0) begin
                //Unlock register that was locked speculatively.
                rd_inuse_bitmap[rd_last_locked] <= 0;
            end
            if (scaiev.issue_isFlushing || scaiev.issue_valid && !scaiev.issue_stall && !scaiev.issue_isStalling) begin
                //Reset speculative lock register ID, as the corresponding decoupled instruction can no longer be flushed.
                rd_last_locked <= '0;
            end
            if (rst || unlock_all_registers) begin
                //Unlock all registers.
                for (int i = 0; i < 32; i=i+1)
                    rd_inuse_bitmap[i] <= 0;
            end
            else if (decode_valid_regular && decode_is_isax_decoupled_wb && scaiev.decode_RD_id != '0
                && !scaiev.decode_stall && !scaiev.decode_flush && !scaiev.decode_isStalling && !scaiev.decode_isFlushing) begin
                //Lock register (speculatively).
                //-> The check for !scaiev.decode_stall ensures that !rd_conflict, i.e. RD is not locked already.
                rd_inuse_bitmap[scaiev.decode_RD_id] <= '1;
                rd_last_locked <= scaiev.decode_RD_id;
            end
            else if ((scaiev.decode_wrReg && !scaiev.decode_stall || decode_wrReg_cancel) && scaiev.decode_wrReg_RD != '0 ) begin
                //Unlock register.
                rd_inuse_bitmap[scaiev.decode_wrReg_RD] <= 0;
            end
        end

        logic rs1_conflict;
        logic rs2_conflict;
        logic rd_as_rs_conflict;
        logic rd_conflict;

        always_comb begin
            rs1_conflict = scaiev.decode_RS1_valid && rd_inuse_bitmap[scaiev.decode_RS1_id]; //Read-after-Write
            rs2_conflict = scaiev.decode_RS2_valid && rd_inuse_bitmap[scaiev.decode_RS2_id]; //Read-after-Write
            rd_as_rs_conflict = scaiev.decode_RD_AS_RS_valid && rd_inuse_bitmap[scaiev.decode_RD_AS_RS_id]; //Read-after-Write
            rd_conflict  = scaiev.decode_RD_valid  && rd_inuse_bitmap[scaiev.decode_RD_id];  //Write-after-Write
            hazard_unit_scaiev_decode_stall_set = decode_valid_regular && (rs1_conflict || rs2_conflict || rd_as_rs_conflict || rd_conflict);
        end
    end
    else begin //!ENABLE_SCAIEV_REGHAZARD
        assign hazard_unit_scaiev_decode_stall_set = 0;
    end endgenerate

    logic explicit_free_reg;
    logic [5:0] explicit_free_reg_addr;

    generate if (ENABLE_DECOUPLED_WRITEBACK && ENABLE_DECOUPLED_WRITEBACK_WAW) begin
        //TODO: isaxkill support (free registers in CVA5)

        //Logic to prevent certain kind of WaW hazard: premature deallocation of decoupled instruction's destination register.
        //-> Later instruction that overrides physical register could finish sooner and free a register that still is to be written to.

        //Indicates whether some ISAX will write the respective physical register.
        //While set, prevent retiring instructions from adding the register to the free FIFO.
        logic [63:0] phys_inuse_by_isax;
        //Indicates whether a logical destination register was prevented from being freed,
        // and still has to be freed by the ISAX on retirement (in addition to the previous register).
        logic [63:0] phys_should_be_freed_by_isax;

        assign scaiev.renamer_addtofree_skip = !unlock_all_registers && phys_inuse_by_isax[scaiev.renamer_addtofree_reg] == 1'b1;

        always_ff @(posedge clk) begin
            scaiev.renamer_addtofree_skip = 0;
            if (rst || unlock_all_registers) begin
                explicit_free_reg <= 0;
                explicit_free_reg_addr <= 'X;
                phys_inuse_by_isax <= '0;
                phys_should_be_freed_by_isax <= '0;
            end
            else begin : waw_logic_scope
                logic [63:0] next_phys_inuse_by_isax;
                logic [63:0] next_phys_should_be_freed_by_isax;
                next_phys_inuse_by_isax = phys_inuse_by_isax;
                next_phys_should_be_freed_by_isax = phys_should_be_freed_by_isax;

                explicit_free_reg <= explicit_free_reg && !scaiev.rf_ready;
                if (scaiev.rf_wrReg) begin
                    next_phys_inuse_by_isax[scaiev.rf_wrReg_phys_RD] = 1'b0; //Write port A2
                    next_phys_should_be_freed_by_isax[scaiev.rf_wrReg_phys_RD] = 1'b0; //Write port B2
                    if (!scaiev.rf_wrReg_cancel && phys_should_be_freed_by_isax[scaiev.rf_wrReg_phys_RD]) begin //Read port B1
                        // -> Inject register free for scaiev.rf_wrReg_phys_RD (e.g. repeat identical writeback next cycle)
                        explicit_free_reg <= 1;
                        explicit_free_reg_addr <= scaiev.rf_wrReg_phys_RD;
                    end
                end

                if (issue_is_isax_decoupled_wb) begin
                    next_phys_inuse_by_isax[scaiev.issue_phys_RD_decoupled] = 1'b1; //Write port A1
                end
                if (scaiev.renamer_addtofree_valid && phys_inuse_by_isax[scaiev.renamer_addtofree_reg] == 1'b1) begin //Read port A1
                    next_phys_should_be_freed_by_isax[scaiev.renamer_addtofree_reg] = 1'b1; //Write port B1
                end
                phys_inuse_by_isax <= next_phys_inuse_by_isax;
                phys_should_be_freed_by_isax <= next_phys_should_be_freed_by_isax;
            end
        end

    end
    else begin // !(ENABLE_DECOUPLED_WRITEBACK && ENABLE_DECOUPLED_WRITEBACK_WAW)
        assign explicit_free_reg = 0;
        assign explicit_free_reg_addr = '0;
    end endgenerate
    assign WrRD_spawn_issue_addr_o = {scaiev.issue_prev_phys_RD_decoupled, scaiev.issue_phys_RD_decoupled};

    

endmodule
