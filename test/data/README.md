# Test fixtures

Everything here is for the test suite only; nothing ships in a release.

- `case9.m`, `case14.m`, `case30.m`: MATPOWER cases, vendored byte exact from
  the MATPOWER repository (BSD 3-Clause, PSERC and contributors). `norm_tiny.m`,
  `angle_bounds_clamp.m`, `zero_impedance.m` (one zero impedance bus tie), and
  `oos_cubic_cost.m` (an out of service generator with a cubic cost) are small
  original cases.
- `case14.pm.json`, `case14.egret.json`: PowerModels and Egret renderings of
  `case14.m`.
- `psse/case3_3w_v33.raw`: an original three bus PSS/E RAW revision 33 case
  with one three winding transformer.
- `psse/contingency/`: PSS/E contingency analysis fixtures copied byte exact
  from the powerio repository, `tests/data/psse/contingency/`, where their
  provenance is recorded. Every file is original to powerio. `resolve_cases.con`
  states one case per binding rule and `resolve_v33.raw` is the five bus
  network it resolves against. `expand.con` states one automatic specification
  per target, `selectors.sub` every selector spelling, and `select_v33.raw` is
  the six bus network they work over. `psse35_area.sub` is the header PSS/E 35
  writes with one `AREA` subsystem; `generated.mon` and `blocks.mon` are the
  statement and the block forms of a monitored element file.
- `pypsa/example/`: written by PyPSA 1.2.2 `Network.export_to_csv_folder` for
  a three bus network. `pypsa/series/`: an original two snapshot folder whose
  load table varies per snapshot, so it parses as a time series.
- `case14_gridfm/`, `case14_gridfm_batch/`: GridFM Parquet renderings of
  `case14.m`, one snapshot and two scenarios.
- `goc3/`: a minimal GO Challenge 3 problem and solution pair written for the
  powerio test suite (two buses, one time period pair).
- `opfdataset/example_0.json`: one solved case 14 example from DeepMind's
  OPFData `dataset_release_1` (CC BY 4.0, (c) 2024 DeepMind Technologies
  Limited); `opfdataset/README.md` records the source archive and hash.
- `capi_matrix/`: bus admittance matrices of `case9.m` and `case30.m` as
  coordinate lists, written by the powerio matrix crate, for checking the
  Julia assembly.
- `dist/`: OpenDSS feeders; provenance in `dist/README.md`.
- `xiidm/`: five small XIIDM documents copied byte exact from the inline
  sources of the detailed connectivity tests in `powerio-capi/src/lib.rs`, so
  the Julia records pin the values the C tests pin. `hierarchy.xiidm` has a
  substation with three voltage levels, a three winding transformer, an
  apparent power limit group, and a ratio tap changer; `merged.xiidm` has two
  subnetworks joined by a tie line over two boundary lines; `nodes.xiidm` has
  a node breaker voltage level with a breaker and an internal connection;
  `equipment.xiidm` is an equipment-only document with a reactive capability
  curve; `dc.xiidm` has DC nodes, a DC line, ground and switch, and a voltage
  source converter.
