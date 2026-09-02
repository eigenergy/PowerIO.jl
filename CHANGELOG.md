# Changelog

## 1.0.0

PowerIO.jl 1.0 binds PowerIO 1.0 over C ABI 7. This is a breaking release: the
0.10 binding read every table from a network's JSON payload through accessor
functions, and ABI 7 replaces that layer with typed element views. The public
API follows the cross language vocabulary of PowerIO 1.0.

- `parse(source; format, name)` replaces `parse_file` and `parse_text`. It
  extends `Base.parse` over a path, an `IO`, or bytes and returns a
  `PioModule{T}` whose parameter is the value type: `BalancedNetwork`,
  `MulticonductorNetwork`, `TimeSeries{T}`, `ScenarioSet{T}`,
  `OperatingPoint{N}`, the seven calculation instances, or the eight solutions.
- Element tables are properties: `net.buses`, `net.branches`, `net.generators`,
  `net.loads`, `net.shunts`, `net.storage`, `net.switches`, `net.hvdc`,
  `net.transformers_3w`, `net.areas` on a `BalancedNetwork`; `net.lines`,
  `net.linecodes`, `net.transformers`, `net.loads`, and the other conductor
  level tables on a `MulticonductorNetwork`. Each returns an `Elements{T}`
  vector of immutable structs (`Bus`, `Branch`, `Generator`,
  `MulticonductorLine`, ...) whose field names follow the C header. The
  accessor functions (`buses(net)`, `n_buses(net)`, `base_mva(net)`, ...) and
  the `net.data` JSON payload are removed.
- `emit(m, format, destination)` returns an `EmitResult` with `files`,
  `layout`, `fidelity`, `diagnostics`, and `text`. `serialize` and `deserialize`
  move PowerIO IR; `to_json`, `from_json`, and the `pio-json` format token are
  removed.
- `TimeSeries` supports `length`, 1-based indexing, and iteration;
  `ScenarioSet` supports `keys`, `values`, `haskey`, indexing by id, and
  iteration over pairs. `list_states` and `export_state` are removed.
- Calculation instances expose `.network`; solutions expose `.instance`,
  `.termination`, `.objective`, and `solution[quantity]`. `to_dc_pf_instance`,
  `to_ac_pf_instance`, `to_dc_opf_instance`, `to_ac_opf_instance`,
  `to_mc_ac_pf_instance`, and `to_mc_ac_opf_instance` construct instance
  modules.
- Typed updates: `ComponentId`, `ActivePower`, `ReactivePower`,
  `ApparentPower`, the `set_*` update constructors, and `apply_updates!`,
  which validates a batch, applies it atomically, refreshes `m.value`, and
  returns an `UpdateReport`.
- The eight DC calculations (`calc_incidence_matrix`,
  `calc_branch_susceptances`, `calc_bus_susceptance_matrix`,
  `calc_branch_flow_matrix`, `calc_branch_phase_shift_injection`,
  `calc_bus_phase_shift_injection`, `calc_branch_flow_dc`,
  `calc_bus_injection_dc`) come from the library. `calc_admittance_matrix`,
  `calc_bprime_matrix`, and `calc_bdoubleprime_matrix` are assembled in Julia
  from the element tables following MATPOWER's `makeYbus`.
- `m.producer`, `m.sources`, and `m.history` are typed records.
- Removed with no ABI 7 counterpart: `to_normalized`, `to_balanced`,
  `to_balanced_report`, `resolve_format`, `FormatInfo`, `features`,
  `has_feature`, `build_info`, `schema_versions`, the `*_available` probes,
  `to_arrow`, `ArrowTable`, `arrow_catalog`, `n_islands`, `is_radial`,
  `reference_bus_positions`, `to_bus_type_code`, `kind`, `inspect`.
- The 49 typed detailed connectivity tables, the OPF preparations, and the
  multiconductor admittance matrix are not bound in this release; binding them
  later is additive.
- The PowerModels bridge (`to_powermodels`, `from_powermodels`,
  `build_powermodels_ref`, `repair_powermodels_angle_bounds!`) and the
  ExaModelsPower bridge (`to_powerdata`, `to_ac_power_data`, `LoadSeries`) are
  rebuilt over the element tables. `from_powermodels` returns a module.
- Release validation checks a binary for ABI 7, the version string, the core
  entry points, and GridFM parsing.

## 0.10.0

PowerIO 0.10 is the public beta of the 1.0 API. API corrections may land before 1.0.0 as downstream integrations exercise the new design.

PowerIO.jl 0.10.0 binds powerio 0.10.0 over C ABI 6.

Breaking: `parse_file` and `parse_bytes` return a `PioModule{T}` rather than a bare network. `m.value` is the typed value. `diagnostics`, `write_file`, `state_inventory`, and `select_state` operate on the module.

- `parse_file` (a path) and `parse_bytes` (named in-memory bytes or an `IO`) detect the source format and value kind together and wrap the native module once in a `PioModule{T}`: nothing reparses, serializes, or copies a network to give the module its type. `T` is one of twenty value families the module surface knows: the two network kinds (`BalancedNetwork`, `MulticonductorNetwork`), the calculation instances and solutions (`DcPfInstance` through `AcScucSolution`), the `TimeSeries`, `ScenarioSet`, and `OperatingPoint` series carriers, or `UnknownValue` for a kind a newer library added after this binding shipped.
- Matrix and conversion functions (`calc_admittance_matrix`, `to_format`, `to_json`, ...) dispatch on `m.value`'s type, matching 0.9. Inspection (`inspect`, `kind`, `diagnostics`), state selection (`state_inventory`, `select_state`), and writing (`write_file`, `write_str`, `write_json`) take the module itself.
- `parse_file` / `parse_bytes` read a stored `.pio.json` document the same way as any other source, and `write_json` writes it: a released 0.9 package upgrades one way on read, and a same format write off an unchanged module still echoes the source bytes.
- Multiconductor modules lower explicitly to balanced ones with `lower_to_balanced`, after `lowering_readiness` reports what the pass would lose without transforming.
- The DC branch data serves the corrected equations, `p_shift = A' (b .* shift)` and `p_branch = -Bf va + b .* shift`, with the incidence, Laplacian, flow matrix, and bus injection assembled from the same spans and pinned elementwise on a shifted fixture.
- `using PowerIO` exports the ordinary network tables, counts, metadata, library probes, writer findings, and DC data accessors. Handle level functions remain private.
- All five sparse matrix builders return `BusMappedMatrix`. The unexported `AdmittanceMatrix` alias remains for source compatibility.
- `build_powermodels_ref` and `repair_powermodels_angle_bounds!` avoid collisions with the names PowerModels exports. The former qualified compatibility names remain defined but unexported.
- `features()` reports `arrow`, `matrix`, `gridfm`, `dist`, and `prob`. The `prob` result now reads the compiled feature flag rather than the presence of an ABI symbol.

## 0.9.0

**One GOC3 SCOPF implementation.** `goc3_scopf_data` takes the document text and types the Rust core's instance (`pio_scopf_parse_str`, the projection `parse_scopf` serializes; the native library with the `prob` feature is now required for it). The wire document uses the language-neutral `powerio.scopf` schema. The pure Julia projection is retired, so every language consumes the same rows and every ordinal comes from document-order enumeration. `ScopfInstance` replaces `producers_first::Bool` with `device_class_layout::DeviceClassLayout` (`:contiguous` with `producers_first`, or `:interleaved`) and gains `dt`; device rows carry `j_dev` (position within the class), `j_sdd` (position in the canonical producers-then-consumers stacking), and `u_0` (the document's `initial_status.on_status`, also on AC line and transformer rows); reserve membership rows carry the member device's ordinals. `goc3_add_status_flags!` gains a method taking the typed rows, so no consumer reads raw lookups for initial status. The interleaved-classes warning is deleted because no ordinal depends on a uid. The Rust projection costs ~13 ms on a 340 KB case against ~1.4 ms for the retired Julia one — a one-time per-case load cost; per-field C accessors are the recorded escape hatch if a workload ever cares.

`parse_scopf(text; index_base=1)` accepts index base 0 or 1. PowerIO.jl defaults to 1, and `goc3_scopf_data` explicitly requests 1 so its ordinals index Julia arrays directly without a binding-side conversion map. Rust, C, and Python default to 0.

Moves the binding to powerio C ABI 5 and completes the GOC3 SCOPF instance. A client now builds a security constrained OPF model from `goc3_scopf_data` alone. Before this, it also had to read `parse_goc3_json`'s raw dictionaries for five separate things.

Breaking: seven returned NamedTuple row or length shapes grow: shunt, AC line, transformer, device, active reserve membership, reactive reserve membership, and instance lengths. Positional destructuring and `propertynames` order change.

**This release needs powerio v0.9.0 binaries.** `PIO_ABI_VERSION` is 5 (`src/capi.jl`) and the binding gates on it by equality, so an older library fails `_ensure_compatible` at the first call into it with a version mismatch error rather than degrading. That includes the v0.8.3 artifact 0.8.4 pinned, which reports ABI 4: the pin and the binding move together and cannot be upgraded separately. `PIO_DIST_ABI_VERSION` stays 1.

**What ABI 5 changes for a caller** ([migration guide](https://powerio.dev/guide/abi-v5.html)). The seven conversion entry points return their fidelity loss findings as a JSON array of diagnostic records through an owned out pointer instead of a caller buffer, so a long warning list is no longer truncated with nothing saying so. The binding keeps each record behind the line it renders, so `to_format`, `convert_file`, `convert_str` and `write_pypsa_csv_folder` return a `Vector{Diagnostic}` whose elements read as their `CODE: message` line anywhere a string was expected, every line now leads with its diagnostic code, and every error message the library raises carries the same prefix (`REQUEST.FORMAT.UNKNOWN: unknown format`). Code matching on exact message text sees the new prefixes; read `d.code` to branch on the code. The four transmission write entry points take a `PioWriteOptions` pointer the binding passes as `C_NULL`, every default, and `pio_normalize` folds its two repair arguments into a `PioNormalizeOptions` struct the binding builds per call; `to_normalized` keeps its Julia keyword surface and `to_normalized_with_options` is removed. `pio_n_buses` and `pio_bus_ids` report the star lowered bus space, so `length(bus_ids) == n_buses` holds and both agree with `bus_demand`, `bus_shunt` and the island count on a case carrying an in service three winding transformer. Four C symbols are gone: the three `pio_acopf_*`, which nothing here referenced, and `pio_normalize_with_options`, which the binding used as the key for its C normalize route — `correct_voltage_angle_differences!` gates on `library_available()` now, where the old key would have silently dropped every call to the pure Julia repair. Seven JSON documents changed shape while their symbols kept their signatures: `schema_version` is `powerio_version`, `pio_schema_versions_json` dropped four keys, `pio_summary_json` gained a `topology` block, and the Arrow metadata key is `powerio.version`. A binding built against ABI 4 passes the handshake and then reads `null` for keys it mirrors, which is why the integer moved.

**The `powerio-json` case format token is retired, and generator cost reaches Arrow.** Balanced model JSON is powerio's own document, carried by `to_json` and `from_json`, so the token that routed the same document through the case format entry points is gone: `to_format(net, "powerio-json")` and the `powerio` and bare `json` spellings fail with `REQUEST.FORMAT.UNKNOWN`, and a bare model JSON string routes through `from_json` the way a package document routes through `read_package`. The JSON family answer gains `model-json`, the family set is closed, and `build_info` reports it under `json_classes` beside the new `diagnostic_namespaces`. `arrow_table` gains the two generator cost tables, `solver_gen_cost` and `solver_gen_cost_coeff`, dense over `solver_gen` order with per unit values on the network MVA base, and `solver_bus` appends `area` and `zone` columns. No existing table id or column order moves.

**Reader and writer output moves with the binaries, and no C declaration shows it.** Three classes, each detailed in [powerio's own 0.9.0 notes](https://github.com/eigenergy/powerio/releases/tag/v0.9.0). A PSS/E case whose space delimited records pad a quoted field parses to different values: both delimiter styles trim now, so `' 1'` reads `1`, and a blank quoted field holds its column instead of vanishing and shifting every column after it. PowerWorld device ids and circuits are stored trimmed, and a value equal to the positional default the writer re-derives is not retained, for every parallel circuit rather than the first alone, so code reading `extras["id"]` or the circuit key off a parsed PowerWorld case finds nothing where a default used to sit. The MATPOWER writer's dropped extras warning carries the count of elements it covers and covers three winding transformers.

- `to_powerdata` and `parse_ac_power_data` accept an infinite variable bound, and only a bound. An absent reactive limit is `Inf` in MATPOWER, PowerModels, pandapower and PyPSA, and stock case9241pegase.m carries it on seven generators; the finiteness check refused those cases while reporting a present field as invalid. `±Inf` now passes on the generator and storage reactive and active limits, the branch ratings and the angle-difference bounds. It is refused everywhere else — `br_r`, `br_x`, `b`, `tap`, `shift`, `vm`, `va`, `base_kv`, `vmin`, `vmax`, `pg`, `qg`, `mbase` and the cost coefficients — with the element and the field named. The split is by whether a source format spells "no bound" that way, not by whether a field is a limit: nothing spells "no voltage limit" as `Inf`, so `vmin`/`vmax` are a data defect rather than a convention. **Behavior change from an earlier 0.9 draft**, which relaxed the check for the whole row rather than for the bounds it was written for: an infinite series reactance, tap ratio, voltage magnitude or base kV reached the caller, and for `br_x` the row also carried admittance coefficients derived from `1/Inf` with nothing recorded. The Rust core moved the other way in the same release (#292) — `branch_susceptance` returns `NaN` for a nonfinite denominator and `IncidenceParts` errors with `NonFiniteSusceptance` — so an infinite reactance was a corrupt case through `calc_susceptance_matrix` and a valid row through this bridge. An absent field is still an error and so is a `NaN`, which no bound reads as (eigenergy/PowerIO.jl#113).
- Every float the binding reads out of a parsed payload takes powerio 0.9.0's nonfinite spelling. Model JSON has no `Inf` literal, so the library writes a nonfinite float as the string `"Infinity"`, `"-Infinity"` or `"NaN"` where it used to write an unreadable `null`. `base_mva`, `base_frequency` and every `to_powerdata` field read a number or one of those three.
- New: `Diagnostic`, the element type of the fidelity findings the conversion verbs return. It reads as the `CODE: message` line it always was — `occursin`, `split`, `join` and `==` against a `String` all see that line — and carries the record's `code`, `severity`, `message` and the rest under `record`. A consumer lifting findings no longer splits strings. `warnings(net)` still returns lines; the C ABI carries records on the conversion entry points alone.
- `to_arrow` returns whatever schema metadata a table carries, under field names that drop the `powerio.` prefix. Only the matrix selectors read it before, so `solver_gen_cost` and `solver_gen_cost_coeff` lost `powerio.base_mva`, the MVA base their per unit values sit on, and converting a cost to currency per MWh took a second call. A table the producer attaches no metadata to decodes to its columns alone, as before.
- `parse_ac_power_data` on a large case is roughly twenty times faster, and infers a concrete return type. `collect` on a `JSON3.Array` of cost coefficients hashed the whole case document once per generator, which was 4.9 s of the 5.2 s case13659pegase took; it now reads 0.3 s. `to_powerdata` and `parse_ac_power_data` gain positional `::Type{T}` methods, with the keyword forms forwarding to them, so a caller that needs inference through the bridge has one.
- Building a `LoadSeries` no longer parses the case twice. Its bus alignment ran a full `to_powerdata` to read two vectors off it and then rebuilt everything for the periods; it reads the normalized view directly now, and allocates well under half what it did.
- The ExaModels bridge reports what the normalize pass found. `to_powerdata`, `parse_ac_power_data` and `LoadSeries` normalize internally and keep only the tables, so every finding of that pass went unseen; each distinct diagnostic code is now a `@warn`, once per call, deduped within the call so separate cases still each report. A case carrying no generator cost data reports `CANONICALIZE.NORMALIZE.GEN_COST_ABSENT`, which the caller about to build an identically zero cost objective is the one who needs, and a case stating no reference bus reports `CANONICALIZE.NORMALIZE.REFERENCE_DESIGNATED`. `filtered=false` and an already normalized network run no pass and report nothing.
- `set_library!`, `clear_library!`, `warnings` and `n_buses` are exported. The docs and this package's own `show` methods name all four unqualified, so a reader following them had to discover the `PowerIO.` prefix by error. The rest of the element and scalar accessors stay unexported, where their names would collide with the ecosystem packages loaded beside this one.
- `ArrowTable` and `ScopfInstance` print a summary. An `ArrowTable` reports its column and row counts, and reads `released` rather than throwing from inside `show` once its buffers are freed; a `ScopfInstance` reports the case sizes off `lengths`, where its seven type parameters used to fill the screen.
- Breaking: `CompilerPackage` is removed. It was the fourth 0.3.0 compatibility alias, and the release that dropped `Network`, `DistNetwork` and `NetworkHandle` missed it. Use `NetworkPackage`, which it aliased.
- Breaking: `to_normalized_with_options` is removed. Its keywords are `to_normalized`'s and always were; the separate spelling existed because the binding used the matching C symbol as its dispatch key, and ABI 5 retired that symbol.
- Breaking: `calc_incidence_matrix` returns `PowerIO.AdmittanceMatrix{Float64}` rather than a bare `SparseMatrixCSC`, so the bus id maps travel with the matrix as they do for the other four `calc_*` functions; read `.matrix` for the sparse array. The wrapper's name reads oddly for a bus-by-branch matrix, whose columns are branches and go through no bus map, and renaming it is a 1.0 question — returning what its siblings return is worth more today.
- Breaking: `to_dense(net).reference_bus` is a 1-based index into `bus_ids`, so `bus_ids[reference_bus]` is the reference bus id with no adjustment. It reported the C ABI's 0-based index before, inside a NamedTuple whose every other index is Julia's. The Python binding's `to_dense` stays 0 based, as does `reference_bus_indices`, which reports the C index space verbatim.
- Breaking: `convert_str(MulticonductorNetwork, text, to; from)` takes `from` as a keyword, matching `convert_str(text, to; from)`. The positional spelling is gone.
- `validate_package` and `package_validation` cross reference each other. One runs the validation profile and the other reads the summary already on the package, which the names alone did not say.
- Breaking: the deprecated Julia bindings `Network`, `DistNetwork` and `NetworkHandle` are removed. 0.3.0 introduced `Network` and `DistNetwork` as compatibility names for `BalancedNetwork` and `MulticonductorNetwork`; 0.6.0 kept `NetworkHandle` as one for `BalancedNetworkHandle`. No entry since recorded a removal, and all three resolved through 0.8.4. Rust and Python retain their deprecated compatibility names through powerio 0.9.0 and remove them in 1.0.0.
- Producer and consumer rows carry the reactive capability block. The two mode
  flags `q_bound_cap` and `q_linear_cap` are mutually exclusive. The bound-cap
  mode adds `beta_ub`, `beta_lb`, `q_0_ub` and `q_0_lb`. The linear-cap mode
  adds `beta` and `q_p0`. A device can set neither mode. Every device on the
  official C3E4N00073D1 scenario does. The parameters of a mode a device did not
  set read `NaN`. A row used without a flag check then gives a NaN objective
  instead of a silent zero. `q_p0` holds the document's linear-cap `q_0`, under
  a new name because the row already uses `q_0` for `initial_status.q`.
  Breaking: `SddRow` grows from 34 to 45 fields. `AclRow` and `AcxRow` grow
  from 14 to 15, and active and reactive reserve membership rows grow from 3
  to 5. `NaN` also makes `==` report
  two identical row sets as unequal, so use `isequal`.
- The producer and consumer row fields a startup or shutdown power trajectory needs are now documented against the GOC3 keys behind them, and tested against those keys device by device: `p_ru_su` and `p_rd_sd` are `p_startup_ramp_ub` and `p_shutdown_ramp_ub`, `p_0` and `q_0` are `initial_status` `p` and `q`, and `p_min` and `p_max` are the per-period `p_lb` and `p_ub` series. The rows already carried all of it under short names that nothing mapped back, so a client reading the rows still went to `sdd_lookup` and `sdd_ts_lookup` for the same numbers.
- `ScopfInstance` gains `violation_cost`: the four prices as `(p_bus, q_bus, s,
  e)`. Each price can be absent and then reads `NaN`. GOCompetition's own
  14-bus validation case omits `e_vio_cost`.
- `ScopfInstance` gains `device_class_layout`, which reports contiguous
  producer and consumer runs or an interleaved source section. Device ordinals
  remain valid for either layout and no interleaving warning is emitted.
- `ScopfInstance.lengths` gains `K`, the contingency count. The survivor
  builders already read it. Breaking: `lengths` grows from 13 to 14 fields.
- Shunt rows gain the per-class index `j_sh`. Like every SCOPF ordinal, it is
  assigned by document order. Breaking: `ShuntRow` grows from 4 to 5 fields
  and `j_sh` leads the row.
- `LoadSeries` and `read_load_series` gain positional `::Type{T}` methods, with
  their keyword forms forwarding to them. A compiler can now infer exactly
  `LoadSeries{T}` through every constructor used by an ahead of time consumer.
- Releases use a reviewed intent that fixes the Julia version, powerio tag, and
  source digest before powerio is published. The release updater changes only
  `Artifacts.toml`, parks semantic mismatches without touching it, pushes only
  when `main` has not moved, and registers the exact tested SHA. Scheduled,
  repository, and manual runs all obey the same intent; there is no authority
  bypass that selects a version or writes changelog claims.
- `demands_mw` and `read_load_series` no longer say that
  `ExaModelsPower.mpopf_model` divides its `pd` and `qd` keywords by `baseMVA`.
  That interface gives MW matrices to `LoadSeries`, which converts them.

## 0.8.4

Tracks powerio v0.8.3, keeping core C ABI v4 and distribution C ABI v1.
No breaking changes: the Julia API is unchanged, and the full test suite
passed against the pinned binaries before this release (automated repin).

- Binaries repinned to the [powerio v0.8.3 release](https://github.com/eigenergy/powerio/releases/tag/v0.8.3); see its notes for the upstream changes.

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
