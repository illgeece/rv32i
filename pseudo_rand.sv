module pseudo_rand #(parameter WIDTH = 32) (
   input  wire             clk,
   input  wire             reset,
   output wire [WIDTH-1:0] rand_vect
);
   assign rand_vect = '0;   // unused by this design
endmodule
