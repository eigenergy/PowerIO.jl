# Test fixtures

Everything here is for the test suite only; nothing ships in a release.

- `case9.m`, `case14.m`, `case30.m`: MATPOWER cases, vendored byte exact from
  the MATPOWER repository (BSD 3-Clause, PSERC and contributors). `norm_tiny.m`
  and `angle_bounds_clamp.m` are small original cases.
- `case14.pm.json`, `case14.egret.json`: PowerModels and Egret renderings of
  `case14.m`.
- `psse/case3_3w_v33.raw`: an original three bus PSS/E RAW revision 33 case
  with one three winding transformer.
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
