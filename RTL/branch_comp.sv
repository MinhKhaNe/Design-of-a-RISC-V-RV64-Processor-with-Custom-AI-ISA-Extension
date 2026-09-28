import rv64im_pkg::*;

module branch_comp (
    input  branch_type_e branch_type,
    input  logic [63:0]  rs1_data,
    input  logic [63:0]  rs2_data,
    output logic         taken
);

  always_comb begin
    case (branch_type)
      BR_EQ:  taken = (rs1_data == rs2_data);
      BR_NE:  taken = (rs1_data != rs2_data);
      BR_LT:  taken = ($signed(rs1_data) <  $signed(rs2_data));
      BR_GE:  taken = ($signed(rs1_data) >= $signed(rs2_data));
      BR_LTU: taken = (rs1_data <  rs2_data);
      BR_GEU: taken = (rs1_data >= rs2_data);
      default: taken = 1'b0;   // BR_NONE / not a branch
    endcase
  end

endmodule