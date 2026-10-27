function mpc = nonconsecutive_bus_ids
%NONCONSECUTIVE_BUS_IDS Three buses with nonconsecutive external IDs.
mpc.version = '2';
mpc.baseMVA = 100;
mpc.bus = [
    10  3   0   0   0   0   1   1.00  0   230  1   1.1  0.9;
    30  1  25   8   0   0   1   1.00  0   115  1   1.1  0.9;
    90  1  40  12   0   0   1   1.00  0    69  1   1.1  0.9;
];
mpc.gen = [
    10  65  20  100  -100  1.00  100  1  100  0;
];
mpc.branch = [
    10  30  0.01  0.10  0.00  100  100  100  0  0  1  -60  60;
    30  90  0.02  0.20  0.00  100  100  100  0  0  1  -60  60;
];
mpc.gencost = [
    2  0  0  3  0.01  10  0;
];
