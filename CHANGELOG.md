# Changelog

## 0.8.3

Tracks powerio v0.8.2, keeping core C ABI v4 and distribution C ABI v1.
No breaking changes: the Julia API is unchanged, and the full test suite
passed against the pinned binaries before this release (automated repin).

- Binaries repinned to the [powerio v0.8.2 release](https://github.com/eigenergy/powerio/releases/tag/v0.8.2); see its notes for the upstream changes.

## 0.8.2

Tracks powerio v0.8.1, keeping core C ABI v4 and distribution C ABI v1.
No breaking changes: the Julia API is unchanged, and the full test suite
passed against the pinned binaries before this release (automated repin).

- Binaries repinned to the [powerio v0.8.1 release](https://github.com/eigenergy/powerio/releases/tag/v0.8.1); see its notes for the upstream changes.

## 0.8.1

Tracks powerio v0.8.0, keeping core C ABI v4 and distribution C ABI v1.
No breaking changes: the Julia API is unchanged, and the full test suite
passed against the pinned binaries before this release (automated repin).

- Binaries repinned to the [powerio v0.8.0 release](https://github.com/eigenergy/powerio/releases/tag/v0.8.0); see its notes for the upstream changes.

## 0.8.0

Tracks the powerio v0.8 document surface: the `.pio.json` envelope moves to
schema 0.2.0 and the distribution capability document to 1.1.0. Breaking for
the Julia API: `PIO_PACKAGE_SCHEMA_URL` is removed, `dist_capabilities()`
reports a wider layout, and the warning truncation marker text changed.
Binaries stay pinned to powerio v0.7.3 until the automated repin; the test
suite passes against both vintages.

- `dist_capabilities()` reports the powerio v0.8 flags (`typed_capacitors`,
  `line_and_generator_ratings`, `per_sequence_bus_bounds`,
  `transformer_extras_relocation`) and the writer's BMOPF schema vintage
  (`bmopf_schema_id`, `bmopf_schema_version`). The probe never throws on a
  document entry: a null or reshaped flag reads as `false`. Breaking: the
  NamedTuple grows from 8 to 14 fields.
- New `MulticonductorNetwork` tables: `ibrs`, `control_profiles`,
  `capacitors` (powerio v0.8 typed banks), and `untyped`, as accessors and
  properties. The writer omits the first three when empty, so a missing key
  reads as an empty table; a missing always-serialized table still raises
  `KeyError`, so a wrong-shaped document fails loudly.
- New exported `schema_versions()`: the document-format lineages the library
  reports through `pio_schema_versions_json` (powerio v0.8).
  `PIO_PACKAGE_SCHEMA_VERSION` is now `"0.2.0"`, and the release gate parks
  a repin whose binaries report a different package or Arrow lineage.
- New exported `demands_mw(series)`: the `LoadSeries` matrices rescaled to
  MW for interfaces that divide by `baseMVA` themselves, such as
  `ExaModelsPower.mpopf_model`.
- The per-call warning buffer grows from 4 KiB to 64 KiB and is no longer
  zero filled; a near-cap fill appends a marker and keeps every line,
  including a partially cut last line. Breaking: the marker text is now
  "warning list may be truncated". `to_matpower` skips the warn channel
  whose output it always discarded.
- Removed `PIO_PACKAGE_SCHEMA_URL` (breaking): the envelope no longer
  carries a schema URL; `schema_versions()` and the version constants cover
  lineage checks.

## 0.7.3

Tracks powerio v0.7.3, keeping core C ABI v4 and distribution C ABI v1.
No breaking changes: the Julia API is unchanged, and the full test suite
passed against the pinned binaries before this release (automated repin).

- Binaries repinned to the [powerio v0.7.3 release](https://github.com/eigenergy/powerio/releases/tag/v0.7.3); see its notes for the upstream changes.

## 0.7.2

Tracks powerio v0.7.2, keeping core C ABI v4 and distribution C ABI v1. No
Julia API changes.

- Binaries repinned to powerio v0.7.2 (#80).
- Pulls in the upstream v0.7.2 JSON reader hardening (PowerModels,
  pandapower, egret, GOC3, Surge) and the leading UTF-8 byte order mark
  strip in every text reader (eigenergy/powerio#260).

## 0.7.1

Wraps the C symbols powerio 0.7.0 added (#74). All additive: `PIO_ABI_VERSION`
stays 4 and `PIO_DIST_ABI_VERSION` stays 1. `Artifacts.toml` tracks the
powerio v0.7.1 binaries (#77), which keep C ABI 4; upstream v0.7.1 hardened
the SCOPF index classification (eigenergy/powerio#252) with unchanged output.

- `parse_scopf(text; from="goc3-json")` parses SCOPF source text into the Rust
  core's native problem instance and returns the versioned 1-based JSON
  `pio_scopf_to_json` produces (with `pio_scopf_parse_str` /
  `pio_scopf_instance_free` behind it); `scopf_available()` probes the prob
  feature and `features()` gains a `prob` field. The pure Julia
  `goc3_scopf_data` surface is unchanged; the serialization numbers zones and
  branches from document order while the Julia builders use uid suffixes, and
  the two agree on official GOC3 files (powerio v0.7.1 hardened the
  renumbering structurally, eigenergy/powerio#252).
- `to_dense` gains the switch table (`ns`, `switch` with `from`, `to`,
  `closed`, ratings, and terminal flows via `pio_switches` /
  `pio_n_switches`) and the terminal branch charging split (`branch.g_fr`,
  `b_fr`, `g_to`, `b_to` via `pio_branch_charging`); the unexported
  `n_switches(net)` accessor joins `n_buses` / `n_branches` / `n_gens`. The
  new fields are present exactly when the resolved library exports the
  extractors, so an older ABI 4 library keeps its previous `to_dense`
  behavior instead of erroring.
- `arrow_catalog()` returns the feature based Arrow table catalog
  (`pio_arrow_catalog_json`): every table the build can export with its
  columns, axes, units, and availability.
- `has_feature(name)` asks the library which cargo features it was compiled
  with (`pio_has_feature`), falling back to symbol probes on older libraries.
- The dedicated scalar string accessors (`pio_network_name` /
  `pio_source_format`) are bound as internals, and a drift canary test asserts
  they agree with the summary-backed `network_name` / `source_format`; the
  public accessors keep reading the cached summary, so their behavior is
  unchanged.
- `from_json(MulticonductorNetwork, text)` rebuilds a live distribution handle
  from the model JSON `net.data` serializes to (`pio_dist_from_json`), the
  distribution sibling of the balanced `from_json`.
- `set_operating_points(pkg, series)` replaces a package's operating point
  series from JSON text or any JSON-serializable value and recomputes
  validation (`pio_package_set_operating_points`); `nothing` clears it. The
  `OperatingPointSeries` skeleton docs now point at it as the JSON-level
  attach.

## 0.7.0

Artifact repin to the powerio v0.7.0 binaries. No breaking changes in the
Julia API: `PIO_ABI_VERSION` stays 4 and `PIO_DIST_ABI_VERSION` stays 1, so
the Julia surface is unchanged, and the minor version tracks the pinned
powerio release.

- Repin `Artifacts.toml` to the powerio v0.7.0 release tarballs.
- Upstream, powerio 0.7.0 adds the `powerio-prob` crate (DC OPF, AC OPF, and
  GOC3 SCOPF problem instances) and demotes `powerio-json` from the public
  case format surface while keeping the `"powerio-json"` token as an ABI v4
  alias, which this package's round trip tests exercise.
- New C symbols (`pio_scopf_parse_str`, `pio_scopf_to_json`, `pio_switches`,
  `pio_branch_charging`, and others) are available to wrap in a later
  release (#74).

## 0.6.4

Julia side release for ExaModelsPower SCOPF parser integration. The shipped C
ABI artifacts remain the v0.6.3 binaries.

- `goc3_scopf_data(data) -> ScopfInstance` is the single exported entry point for
  GOC3 SCOPF extraction: one call returns the static topology, per-class index
  sizes, energy windows, price blocks, and AC/DC contingency survivors. Rows are
  format neutral with per class indices (`j_ln` AC lines, `j_xf` transformers,
  `j_dc` DC lines, `n_p`/`n_q` reserve zones); client models own stacked indices
  (`j`, `j_ac`, combined reserve `n`). The individual `_goc3_*` builders behind it
  are internal. `ScopfInstance` is a derived instance — the SCOPF analog of the Rust
  DC-OPF `OpfInstance` — not a format type. Retiring `goc3_scopf_data` mirrors
  `build_opf_instance`: a canonical Rust `ScopfInstance` built from the IR, which the
  function then binds. That is blocked until the IR gains reserve, contingency, and
  temporal-constraint constructs (issue #235).
- The GOC3 row builders return concrete row vector types for empty and nonempty
  sets. Exported GOC3 surface: `parse_goc3_json`, `goc3_scopf_data`,
  `ScopfInstance`, `goc3_status_flags`, `goc3_add_status_flags!`,
  `goc3_interval_bounds`.
- `LoadSeries`, `read_load_series`, and `n_periods` (the ExaModels multiperiod
  load bridge) are now exported. `LoadSeries` is interim: its `pd`/`qd`/`bus_ids`/
  `base_mva`/`n_periods` surface stays stable when a later release re-backs it with
  the Rust `OperatingPointSeries` (issue #236), so no consumer change is required.
- The ExaModels bridge builds bus, gen, branch, arc, and storage rows into
  concrete row types, so an empty gen/branch/arc/storage section stays a
  concrete `Vector{Row}` instead of inferring `Vector{Any}`, and GPU backends
  can adapt parsed PowerData without seeing abstract `NamedTuple` vectors.
- The test suite and manual registration workflow now require the top
  `CHANGELOG.md` section to match the package version before a release can move
  forward.

## 0.6.3

Tracks powerio v0.6.3, keeping core C ABI v4 and distribution C ABI v1.

- Binaries repinned to powerio v0.6.3.
- Added Rust backed sparse matrix helpers for balanced networks:
  `calc_admittance_matrix`, `calc_susceptance_matrix`, `calc_bprime_matrix`,
  `calc_bdoubleprime_matrix`, and `calc_incidence_matrix`.
- `to_arrow` matrix COO tables now carry explicit row and column axis metadata,
  and Julia matrix materialization uses those axis maps instead of assuming bus
  order matches matrix order.
- Added matrix documentation, matrix fixtures, local benchmark notes, and memory
  safety coverage around library overrides and handle ownership.

## 0.6.2

Tracks powerio v0.6.2, keeping core C ABI v4 and distribution C ABI v1.

- Binaries repinned to powerio v0.6.2.
- `dist_capabilities()` reports the native BMOPF export fidelity flags exposed
  by `pio_dist_capabilities_json`.
- `to_graph(net)` exposes graph projections for `BalancedNetwork` and
  `MulticonductorNetwork`.
- `package_study(pkg)` and `materialize_study_commit(pkg, index)` expose the
  study block C ABI surface for `.pio.json` packages.

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
  `PowerIO.build_ref` (#51 by @rpiansky3, integrated in #55).
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