# Changelog

## 0.1.0

- `read_gridfm` / `read_gridfm_scenarios` read a gridfm-datakit Parquet dataset
  back into a `Network` — the inverse of the gridfm writer, the ML→classical
  return leg (lossy but power-flow-complete; what the schema can't round-trip
  comes back in `warnings`). Needs powerio-capi built `--features gridfm`;
  `gridfm_available()` probes for the symbol (no ABI bump, still version 3).

## 0.0.1

First release, targeting powerio C ABI version 3.

- `parse_file` / `parse_str` / `from_json` → `Network`, with accessors over
  the lossless JSON transport.
- `to_dense` for numeric tables as typed arrays, `to_arrow` for Arrow C Data
  Interface export (owned columns by default, zero copy behind `copy=false`),
  `to_normalized`, `to_matpower`, `to_format`, `convert_file`.
- Bridges: `to_powermodels` / `from_powermodels`, `to_powerdata` /
  `parse_ac_power_data` for ExaPowerIO/ExaModelsPower.
- Binary distribution via lazy artifacts built from tagged powerio releases;
  ABI version handshake at first use; sibling checkout auto-discovery for
  development.
