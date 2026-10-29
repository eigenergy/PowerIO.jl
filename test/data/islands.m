function mpc = islands
% Two AC islands and an isolated bus. Buses 1 to 3 form a triangle with
% reference 1, buses 4 and 5 a pair with reference 4, and bus 6 is typed
% isolated. The tie 3-4 and the branch 5-6 are out of service.
mpc.version = '2';
mpc.baseMVA = 100;
mpc.bus = [
  1 3  0 0 0 0 1 1 0 230 1 1.1 0.9;
  2 1 40 0 0 0 1 1 0 230 1 1.1 0.9;
  3 1 30 0 0 0 1 1 0 230 1 1.1 0.9;
  4 3  0 0 0 0 1 1 0 230 1 1.1 0.9;
  5 1 20 0 0 0 1 1 0 230 1 1.1 0.9;
  6 4  0 0 0 0 1 1 0 230 1 1.1 0.9;
];
mpc.gen = [
  1 70 0 100 -100 1 100 1 200 0;
  4 20 0 100 -100 1 100 1 200 0;
];
mpc.branch = [
  1 2 0.01 0.10 0 100 100 100 0 0 1 -60 60;
  2 3 0.01 0.20 0 100 100 100 0 0 1 -60 60;
  1 3 0.01 0.25 0 100 100 100 0 0 1 -60 60;
  4 5 0.01 0.10 0 100 100 100 0 0 1 -60 60;
  3 4 0.01 0.10 0 100 100 100 0 0 0 -60 60;
  5 6 0.01 0.10 0 100 100 100 0 0 0 -60 60;
];
mpc.gencost = [
  2 0 0 3 0.01 10 0;
  2 0 0 3 0.01 10 0;
];
