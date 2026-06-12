# Changelog

## 0.2.0

Targets powerio C ABI version 4 (powerio v0.2.1); an older library or artifact
is refused at first use. Breaking.

- `to_dense` renames: `reference_bus → ref_bus_index`, `n_components →
  n_islands` (both topology scalars; `ref_bus_index` is a dense 0-based index,
  unlike the 1-based ids in `branch.from`/`to`).
- `PowerIO.warnings(net)`: the fidelity warnings a lossy reader attaches to the
  handle, sized exactly. Unexported: `text, warnings = convert_file(...)` stays
  the documented destructuring idiom.
- Zero-copy `to_arrow(...; copy=false)` columns are `ArrowColumn`s that root
  the shared producer buffers, so a column extracted from its `ArrowTable`
  stays valid on its own. `close(t)` releases the buffers eagerly; the table is
  no longer a finalizable object, so 0.1.0 code calling `finalize(t)` must move
  to `close(t)`.
- Use after free hardening: every helper that lowers a `NetworkHandle` to a raw
  pointer runs its ccalls under `GC.@preserve`; dense extractors pass caps and
  verify the returned totals.

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
