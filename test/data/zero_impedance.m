function mpc = zero_impedance
%ZERO_IMPEDANCE  Three buses; branch 1-2 is a zero impedance bus tie.
%   An original case for the PowerIO.jl test suite. Branch 2-3 is an
%   ordinary line so the network solves once the tie is skipped or merged.
mpc.version = '2';
mpc.baseMVA = 100;
mpc.bus = [
	1	3	0	0	0	0	1	1	0	230	1	1.1	0.9;
	2	1	50	0	0	0	1	1	0	230	1	1.1	0.9;
	3	1	50	0	0	0	1	1	0	230	1	1.1	0.9;
];
mpc.gen = [
	1	100	0	100	-100	1	100	1	200	0;
];
mpc.branch = [
	1	2	0	0	0.02	100	100	100	0	0	1	-60	60;
	2	3	0	0.1	0	100	100	100	0	0	1	-60	60;
];
mpc.gencost = [
	2	0	0	3	0.01	10	0;
];
