# Changelog

## 0.6.1

Tracks powerio v0.6.1, keeping core C ABI v4 and distribution C ABI v1.

- `to_normalized` accepts `clamp_angle_bounds=true` and `angle_bound_pad`, using
  the new C ABI normalize options. `to_normalized_with_options` is the explicit
  spelling.
- `to_arrow` adds matrix COO table selectors: `:ybus`, `:incidence`, `:bprime`,
  and `:bdoubleprime`. `matrix_available()` probes whether the loaded C ABI was
  built with that surface.
- The artifact updater now rejects binaries missing the matrix Arrow feature.
- Release notes document the TagBot #44 manual backfill path for `v0.0.1`.

## 0.6.0

Tracks powerio v0.6.0 in lockstep, keeping core C ABI v4 and distribution C
ABI v1 (the core additions are additive symbols, probed at runtime). Breaking
on the Julia side.

- The bare verbs route on format: `parse_file("feeder.dss")` returns a
  `MulticonductorNetwork`, `parse_file("case.pio.json")` returns whichever
  model the package declares, and a bare `.json` routes on the core's
  cross-domain classifier (`pio_classify_str`). The type-marker forms
  (`parse_file(BalancedNetwork, path)`, `parse_file(MulticonductorNetwork,
  path)`) pin a model explicitly and bypass routing. `parse_file(path)`'s
  return type is now a union over the two models.
- `MulticonductorNetwork` carries its element tables: `data::JSON3.Object`
  (the `pio-payload-multiconductor/1` payload) next to the live handle,
  with accessors (`buses`, `lines`, `linecodes`, `switches`, `transformers`,
  `loads`, `generators`, `shunts`, `sources`, `n_buses`, `base_frequency`,
  `network_name`, `source_format`) and a count-based `show`. The old
  opaque-pointer struct (`MulticonductorNetwork(ptr)`, `.ptr`) is gone;
  handles live in `net.handle`.
- `from_package` returns the model the package holds. The silent
  multiconductor to balanced lowering is gone;
  `lower_multiconductor_to_balanced` remains the explicit pass. A handle
  rebuilt from a package retains no source text, so a same-format write is a
  fresh serialization, not a byte-exact echo.
- Cross-model conversion (`convert_file("feeder.dss", "matpower")`) is a
  directed error naming the package lowering pass.
- `NetworkHandle` renames to `BalancedNetworkHandle`; the distribution handle
  is `MulticonductorNetworkHandle`. Deprecated bindings cover the old names.
- PowerModels reference utilities in the PowerModels bridge
  (unexported, use qualified): `PowerIO.calc_branch_t`,
  `PowerIO.calc_branch_y`, `PowerIO.correct_voltage_angle_differences!`,
  `PowerIO.build_ref` (#51, #55).
- Internal reorganization: `src/PowerIO.jl` split into focused source files;
  tests split per area; the Documenter site rebuilt with topical pages.

## 0.5.0

Tracks powerio v0.5.0, keeping core C ABI v4 and distribution C ABI v1. No
Julia API changes; the minor bump is breaking only in the pre-1.0 SemVer sense
and puts the version in lockstep with powerio going forward.

- Binaries repinned to powerio v0.5.0 for Linux, macOS, and Windows.
- Parser routing picks up GO Challenge 3 JSON input and Surge JSON read and
  write.
- The operating point C surface is fully live: `materialize_operating_point`
  works against the shipped binaries, and `package_operating_points` uses
  `pio_package_operating_points_json` instead of the envelope fallback.
- Pulls in powerio v0.5.0 parser fixes: PSS/E v34/v35 revision aware record
  layouts, PSLF parallel load and shunt ids, a work budget on the PowerWorld
  `.pwb` table location search, and GO Challenge 3 reader fixes (line charging
  with additional shunts, transformer control ranges, initial status handling).

## 0.4.0

Tracks powerio v0.4.0, keeping core C ABI v4 and distribution C ABI v1. Binding
only release: the shipped binaries are unchanged. Breaking under pre-1.0 SemVer
versioning, though the Julia surface itself is additive: the primary package
type name is now `NetworkPackage`, and `CompilerPackage` remains as a
compatibility alias.

- `.pio.json` operating point support: `package_operating_points` returns the
  package operating point series, and `materialize_operating_point` applies one
  point to produce a static package. On binaries that predate the operating
  point C surface, `package_operating_points` reads the envelope directly and
  `materialize_operating_point` errors with rebuild guidance.
- `parse_goc3_json` builds the GO Challenge 3 scheduling lookup shape used by
  SCOPF clients, so client packages do not need to carry their own JSON dataset
  parser. `goc3_status_flags` and `goc3_add_status_flags!` derive unit
  commitment transition flags. These helpers are pure Julia and work with any
  binary.

## 0.3.0

Tracks powerio v0.4.0, keeping core C ABI v4 (`PIO_ABI_VERSION` 4) and
distribution C ABI v1 (`PIO_DIST_ABI_VERSION` 1). Breaking under pre-1.0 SemVer:
the primary parsed model names are now `BalancedNetwork` and
`MulticonductorNetwork`; `Network` and `DistNetwork` remain as deprecated
compatibility bindings.

- Binaries repinned to powerio v0.4.0 for Linux, macOS, and Windows. The shipped
  C ABI artifacts include the `arrow`, `gridfm`, `dist`, and `pkg` features.
- `.pio.json` compiler package support through `CompilerPackage`, `to_package`,
  `from_package`, `read_package`, `write_package`, `validate_package`,
  `package_validation`, and `package_diagnostics`.
- Multiconductor packages can be checked and explicitly lowered to balanced
  packages with `multiconductor_to_balanced_preflight` and
  `lower_multiconductor_to_balanced`.
- `to_arrow` adds raw `:switch` output plus normalized solver table selectors:
  `:solver_bus`, `:solver_load`, `:solver_shunt`, `:solver_branch`,
  `:solver_switch`, `:solver_arc`, `:solver_gen`, `:solver_storage`, and
  `:solver_hvdc`.
- The distribution test suite now covers the OpenDSS generator to BMOPF
  regression from BMOPFTools.jl #190. With powerio v0.4.0, fixed P/Q OpenDSS
  generators emit as BMOPF `generator` entries instead of negative `load`
  entries.
- Artifact update tooling now refuses binaries that lack the package feature,
  so future artifact PRs cannot silently drop the `pio_package_*` surface.

## 0.2.3

Tracks powerio v0.3.3, keeping core C ABI v4 and distribution C ABI v1. No
Julia API changes.

- Binaries repinned to powerio v0.3.3 for Linux, macOS, and Windows.
- Pulls in upstream parser, distribution, MCP, and display API fixes from
  powerio v0.3.3.

## 0.2.2

Tracks powerio v0.3.2, keeping core C ABI v4 and distribution C ABI v1. No
Julia API changes.

- Binaries repinned to powerio v0.3.2 for Linux, macOS, and Windows.
- Pulls in upstream OpenDSS to BMOPF shunt conversion fixes, including
  grounding reactors and delta capacitor or reactor banks.

## 0.2.1

Tracks powerio v0.3.1, keeping core C ABI v4 (`PIO_ABI_VERSION` 4) and adding
distribution C ABI v1 (`PIO_DIST_ABI_VERSION` 1). No transmission API changes.

- Binaries repinned to powerio v0.3.1 for Linux, macOS, and Windows.
- Distribution calls now require `pio_dist_abi_version() == 1` and use the
  supported C one-shot conversion order `(text/path, from, to)` underneath the
  stable Julia surface.
- The artifact update workflow now checks core ABI, distribution ABI, and the
  `arrow`, `gridfm`, and `dist` feature-gated symbols before opening an artifact
  PR.

## 0.2.0

Tracks powerio v0.3.0 and its C ABI v4 (`PIO_ABI_VERSION` 4, a breaking ABI
change). The public Julia surface is unchanged for transmission callers — the
renamed and re-signatured C entry points are swapped underneath the same
functions — and a new distribution binding is added.

- C ABI v4 migration. The binding now targets ABI 4: every renamed `pio_*` symbol
  is updated (`pio_normalize`, `pio_to_format` for matpower/powerio-json,
  `pio_parse_str` for the JSON snapshot, `pio_to_arrow`, `pio_write_dir`,
  `pio_read_dir` / `pio_scenario_ids`, `pio_ref_bus_index` /
  `pio_ref_bus_indices`, `pio_bus_demand` / `pio_bus_shunt`, `pio_n_islands`),
  the dense extractors adopt the cap/count convention, `convert_file` follows the
  v4 `(path, from, to)` argument order, and gridfm read warnings now come off the
  handle (`pio_warnings`) instead of a per-call buffer.
- Distribution surface on a new `DistNetwork` handle, over the multiconductor
  `pio_dist_*` ABI. PowerIO.jl requires `pio_dist_abi_version() == 1` before
  using distribution entry points, and calls the C one-shot conversions in the
  supported `(text/path, from, to)` order. It shares the transmission verbs
  rather than prefixing:
  `parse_file(DistNetwork, path)` / `parse_str(DistNetwork, text, fmt)` build the
  handle (the `parse(T, x)` idiom, since Julia cannot dispatch on the return
  type), while `to_format(net, to)` and `warnings(net)` dispatch on the handle;
  `convert_file(DistNetwork, path, to)` / `convert_str(DistNetwork, …)` are the
  one-shot paths. Reads and writes OpenDSS (`"dss"`), PowerModelsDistribution
  ENGINEERING JSON (`"pmd"`), and IEEE BMOPF JSON (`"bmopf"`). Experimental while
  the BMOPF schema is v0.0.1; needs powerio-capi built `--features dist` (on by
  default in the released binaries), probed by `dist_available()`.
- `convert_str(text, to; from)` — the in-memory sibling of `convert_file`, over
  the v4 `pio_convert_str` (and `convert_str(DistNetwork, …)` for distribution).
- `arrow_available` / `gridfm_available` / `dist_available` are now exported.
- Binaries repinned to powerio v0.3.0.

## 0.1.4

Updates binaries to track powerio v0.2.4. No Julia binding changes. 

- Support for reading PSLF `.epc` files
- Broader vintage support for `.pwb` and `.pwd` files
- Various hardening fixes
- C ABI unchanged

## 0.1.3

- `to_normalized` now preserves source bus ids, matching powerio v0.2.3.
- `to_powerdata` and `parse_ac_power_data` now derive their default filtered
  view from `to_normalized`, preserving `bus_i` source ids while keeping
  PowerData branch and generator references dense.
- PowerData polynomial cost lowering now drops leading padded zeros and returns
  quadratic `(quad, lin, const)` coefficients in per unit.

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
