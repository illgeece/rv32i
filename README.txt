PIPELINING:
I started with a simple four stage pipeline but...
The macro for the register file not only doesnt support pipelining but it makes forwarding a nightmare, comparing the source and destination registers and implementing a mux is impossible inside this macro. So I have to start with a new register file myself.

REG FILE:
