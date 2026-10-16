module zicntr (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [11:0] csr_addr,
    output logic [63:0] rdata,
    output logic        hit,
    output logic        read_only,   // addr[11:10]==2'b11 -> writes are illegal
    input  logic        we,
    input  logic [63:0] wdata,

    input  logic        retire       // one instruction completes EX this cycle
);

  logic [63:0] mcycle, minstret;

  always_comb begin
    hit   = 1'b1;
    rdata = 64'b0;
    case (csr_addr)
      12'hB00, 12'hC00, 12'hC01: rdata = mcycle;     // mcycle / cycle / time
      12'hB02, 12'hC02:          rdata = minstret;   // minstret / instret
      default:                   hit = 1'b0;
    endcase
  end

  assign read_only = (csr_addr[11:10] == 2'b11);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mcycle   <= 64'b0;
      minstret <= 64'b0;
    end else begin
      if (we && csr_addr == 12'hB00) mcycle   <= wdata;
      else                           mcycle   <= mcycle + 64'd1;

      if (we && csr_addr == 12'hB02) minstret <= wdata;
      else                           minstret <= minstret + {63'b0, retire};
    end
  end

endmodule