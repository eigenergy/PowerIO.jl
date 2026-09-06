function mpc = oos_cubic_cost
%OOS_CUBIC_COST  Two generators; the second is out of service with a cubic cost.
%   An original case for the PowerIO.jl test suite (PowerIO.jl#143).
mpc.version = '2';
mpc.baseMVA = 100;
mpc.bus = [
	1	3	0	0	0	0	1	1	0	230	1	1.1	0.9;
	2	1	60	0	0	0	1	1	0	230	1	1.1	0.9;
];
mpc.gen = [
	1	60	0	100	-100	1	100	1	150	0;
	2	0	0	50	-50	1	100	0	50	0;
];
mpc.branch = [
	1	2	0.01	0.1	0	100	100	100	0	0	1	-60	60;
];
mpc.gencost = [
	2	0	0	3	0	0.01	2;
	2	0	0	4	1	0.01	2	3;
];
