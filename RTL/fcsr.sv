module fcsr (
    input  logic        clk,
    input  logic        rst_n,

    // CSR instruction port (EX stage)
    input  logic [11:0] csr_addr,
    output logic [63:0] rdata,
    output logic        hit,          // csr_addr is one of the FP CSRs
    input  logic        we,
    input  logic [63:0] wdata,

    // exception flags raised by a completing FP instruction
    input  logic [4:0]  flags_set,

    output logic [2:0]  frm
);

  logic [4:0] fflags;

  always_comb begin
    hit   = 1'b1;
    case (csr_addr)
      12'h001: rdata = {59'b0, fflags};
      12'h002: rdata = {61'b0, frm};
      12'h003: rdata = {56'b0, frm, fflags};
      default: begin rdata = 64'b0; hit = 1'b0; end
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fflags <= 5'b0;
      frm    <= 3'b0;
    end else if (we) begin
      case (csr_addr)
        12'h001: fflags <= wdata[4:0];
        12'h002: frm    <= wdata[2:0];
        12'h003: begin fflags <= wdata[4:0]; frm <= wdata[7:5]; end
        default: ;
      endcase
    end else begin
      fflags <= fflags | flags_set;
    end
  end

endmodule