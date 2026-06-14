# Changelog

## 0.1.2

Tracks powerio v0.2.2 (C ABI version 3, unchanged); the repinned binaries improve
PSS/E and PowerWorld parsing. Additive Julia-side changes only.

- `n_components(net)` and `is_radial(net)` accessors over `pio_n_components` /
  `pio_is_radial` — the connectivity scalars `to_dense` already returns, now
  reachable without building the dense view.
- `Base.show` for `Network` prints a one-line summary (source format, bus / branch /
  gen counts).
- Aqua.jl quality tests added to the suite.

## 0.1.1

Adds two C-ABI bindings; still targets powerio C ABI version 3 (powerio 0.2.x
binaries are drop in, the v0.2.1 artifact pin unchanged). No breaking changes —
an additive patch over 0.1.0.

- `write_pypsa_csv_folder(net, out_dir) -> (out_dir, warnings)` writes a PyPSA
  CSV folder — the directory-shaped inverse of
  `parse_file(out_dir; from="pypsa-csv")`, binding `pio_write_pypsa_csv_folder`.
- `reference_bus_indices(net) -> Vector{Int}` returns the dense indices of every
  reference bus (zero, one, or many), over `pio_n_reference_buses` /
  `pio_reference_buses` — the multi-slack companion to `reference_bus_id`.

## 0.1.0

First current release: the gridfm reader plus pointer-lifetime hardening, on
powerio C ABI version 3 (v0.2.1 binaries are drop in). Breaking under pre-1.0
SemVer as a minor bump from 0.0.1; no source-level break, no signature changes.
The one behavioral change is `finalize` on a zero-copy table, below.

- `read_gridfm` / `read_gridfm_scenarios` read a gridfm-datakit Parquet dataset
  back into a `Network` — the inverse of the gridfm writer, the ML→classical
  return leg (lossy but power-flow-complete; what the schema can't round-trip
  comes back in `warnings`). Needs powerio-capi built `--features gridfm`;
  `gridfm_available()` probes for the symbol (no ABI bump, still version 3).
- Use after free: every helper that lowers a `NetworkHandle` to a raw pointer
  now runs its ccalls under `GC.@preserve` — Julia may collect a handle after
  its last use, not at end of call, so a GC between pointer extraction and a
  ccall could finalize the handle and hand Rust a freed pointer (reachable in
  ordinary code such as `to_dense(parse_file(path))`). `_cstr` gains the same
  guard for its message buffers.
- Zero-copy `to_arrow(...; copy=false)` columns are `ArrowColumn`s that root
  the shared producer buffers (`ArrowBuffers`), so a column extracted from its
  `ArrowTable` stays valid on its own; previously it dangled once the table
  was collected. `close(t)` releases the buffers eagerly; `finalize(t)` is now
  a no-op (the owner frees once the table and every column drop).
- The handle finalizer captures `pio_network_free` from the library that
  allocated the network, so a `set_library!` swap can no longer free across
  allocators; `set_library!` also resets the ABI handshake.
- `read_gridfm_scenarios` verifies the scenario count between probe and fill
  (the directory can change under us; a short fill left heap garbage in the
  tail). Feature-gate errors rethrow non-toolchain exceptions instead of
  blaming the build.
- Per-call warning buffers grow to 4096 bytes and a fill near the cap is
  surfaced as a truncation marker instead of silently dropping warnings.

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
