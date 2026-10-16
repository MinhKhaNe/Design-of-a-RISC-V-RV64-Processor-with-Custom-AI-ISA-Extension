import rv64imafc_pkg::*;

module amo_alu (
    input  amo_op_e     op,
    input  logic        is_word,
    input  logic [63:0] old,        // value read from memory (already extended by dmem)
    input  logic [63:0] src,        // rs2
    output logic [63:0] result
);

  logic [63:0] o, s;

  always_comb begin
    o = is_word ? {{32{old[31]}}, old[31:0]} : old;
    s = is_word ? {{32{src[31]}}, src[31:0]} : src;
    case (op)
      AMO_SWAP: result = s;
      AMO_ADD:  result = o + s;
      AMO_XOR:  result = o ^ s;
      AMO_AND:  result = o & s;
      AMO_OR:   result = o | s;
      AMO_MIN:  result = ($signed(o) < $signed(s)) ? o : s;
      AMO_MAX:  result = ($signed(o) > $signed(s)) ? o : s;
      AMO_MINU: result = (o < s) ? o : s;
      AMO_MAXU: result = (o > s) ? o : s;
      default:  result = s;
    endcase
  end

endmodule