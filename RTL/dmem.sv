import rv64im_pkg::*;

module dmem #(
    parameter int MEM_BYTES = 4096
) (
    input  logic         clk,
    input  logic [63:0]  addr,
    input  logic [63:0]  wdata,
    input  logic         mem_write,
    input  mem_width_e   width,
    output logic [63:0]  rdata
);

  logic [7:0]  mem [0:MEM_BYTES-1];
  logic [3:0]  nbytes;
  logic [63:0] raw;
  logic [11:0] a;   // truncated address into this local memory

  assign a = addr[11:0];

  always_comb begin
    case (width)
      MEM_B, MEM_BU: nbytes = 4'd1;
      MEM_H, MEM_HU: nbytes = 4'd2;
      MEM_W, MEM_WU: nbytes = 4'd4;
      MEM_D:         nbytes = 4'd8;
      default:       nbytes = 4'd4;
    endcase
  end

  // synchronous write
  always_ff @(posedge clk) begin
    if (mem_write) begin
      for (int i = 0; i < 8; i++) begin
        if (i < nbytes) mem[a + i[11:0]] <= wdata[8*i +: 8];
      end
    end
  end

  // combinational read + sign/zero extension
  always_comb begin
    raw = 64'b0;
    for (int i = 0; i < 8; i++) begin
      if (i < nbytes) raw[8*i +: 8] = mem[a + i[11:0]];
    end
    case (width)
      MEM_B:  rdata = {{56{raw[7]}},  raw[7:0]};
      MEM_H:  rdata = {{48{raw[15]}}, raw[15:0]};
      MEM_W:  rdata = {{32{raw[31]}}, raw[31:0]};
      MEM_BU: rdata = {56'b0, raw[7:0]};
      MEM_HU: rdata = {48'b0, raw[15:0]};
      MEM_WU: rdata = {32'b0, raw[31:0]};
      MEM_D:  rdata = raw;
      default: rdata = raw;
    endcase
  end

endmodule