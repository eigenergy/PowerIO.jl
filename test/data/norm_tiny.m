function mpc = norm_tiny
%NORM_TINY  Tiny fixture for to_normalized: non-contiguous ids, an isolated bus,
%   an out-of-service branch, a branch onto a dropped bus, and a gen-less bus.
mpc.version = '2';

%% system MVA base
mpc.baseMVA = 100;

%% bus data
%	bus_i	type	Pd	Qd	Gs	Bs	area	Vm	Va	baseKV	zone	Vmax	Vmin
mpc.bus = [
	1	3	0	0	0	0	1	1.00	0	138	1	1.1	0.9;
	3	2	30	10	0	0	1	1.00	-2	138	1	1.1	0.9;
	5	1	50	20	0	0	1	1.00	-5	138	1	1.1	0.9;
	8	4	0	0	0	0	1	1.00	0	138	1	1.1	0.9;
];

%% generator data
%	bus	Pg	Qg	Qmax	Qmin	Vg	mBase	status	Pmax	Pmin
mpc.gen = [
	1	100	0	100	-100	1.0	100	1	200	0;
	3	50	0	100	-100	1.0	100	1	100	0;
];

%% branch data
%	fbus	tbus	r	x	b	rateA	rateB	rateC	ratio	angle	status	angmin	angmax
mpc.branch = [
	1	3	0.01	0.10	0	100	100	100	0	0	1	-30	30;
	3	5	0.02	0.20	0	100	100	100	0.98	2	1	-30	30;
	1	5	0.03	0.30	0	100	100	100	0	0	0	-30	30;
	5	8	0.04	0.40	0	100	100	100	0	0	1	-30	30;
];
