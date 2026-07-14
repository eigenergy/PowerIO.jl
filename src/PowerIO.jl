"""
    PowerIO

Julia entry point for the PowerIO Rust core: parser, compiler package, and IR
infrastructure for power system software. Parse MATPOWER, PSS/E, PowerWorld,
PSLF EPC, PowerModels JSON, egret JSON, pandapower JSON, PyPSA CSV, Surge JSON,
and PowerIO JSON cases, convert between supported pairs, and materialize a
parsed `BalancedNetwork`, all through the `powerio-capi` C ABI.

Parse once with [`parse_file`](@ref) → [`BalancedNetwork`](@ref), then read or transform it,
all over the same C ABI:

- the rich, lossless element tables via the JSON transport (every field + extras,
  costs, storage, HVDC): the accessors and [`to_json`](@ref).
- [`to_dense`](@ref): the numeric tables as dense typed arrays for matrix assembly,
  straight from the C ABI extractors, no JSON.
- [`to_arrow`](@ref): one table over the Arrow C Data Interface (owned columns by
  default; zero copy with `copy=false`), including matrix COO selectors when the
  matrix feature is present.

[`to_normalized`](@ref) derives a per unit / radian / filtered copy that preserves
source bus ids, and
[`to_matpower`](@ref) / [`convert_file`](@ref) serialize back out.

[`read_gridfm`](@ref) / [`read_gridfm_scenarios`](@ref) read a gridfm-datakit Parquet
dataset back into a `BalancedNetwork` (the ML→classical return leg; lossy but complete
enough for power flow, needs powerio-capi built `--features gridfm`).

Multiconductor distribution cases are a separate model, [`MulticonductorNetwork`](@ref),
with the same handle plus cached payload pattern as the balanced side
(`net.data`). The bare verbs route on the format — `parse_file("feeder.dss")`,
`convert_file("feeder.dss", "bmopf")`, `parse_file("case.pio.json")` — and the
type marker forms (`parse_file(MulticonductorNetwork, path)`) stay as the
explicit spelling. OpenDSS, PowerModelsDistribution JSON, and IEEE BMOPF JSON
read and write (experimental; needs powerio-capi built `--features dist`, plus
`pkg` for the element tables).

`.pio.json` network packages use the `pio_package_*` C ABI API. They can
wrap balanced and multiconductor handles, run package validation, expose
structured diagnostics, and explicitly lower supported multiconductor packages
to balanced packages.

At first use the binding checks the library's ABI version (`pio_abi_version`)
against the version it targets (`PIO_ABI_VERSION`) and refuses a stale or
mismatched library with an error stating both versions. Distribution calls also
check `pio_dist_abi_version` against `PIO_DIST_ABI_VERSION`.

The C library resolves automatically: the bundled lazy artifact, or a sibling
powerio build during development. Point at a custom build with
[`set_library!`](@ref), the `POWERIO_CAPI` environment variable, or a persisted
Preferences.jl override.
"""
module PowerIO

using JSON3
using LazyArtifacts
using Preferences: load_preference, set_preferences!
import Libdl
import SparseArrays

# Parsing and the parsed models
export BalancedNetwork, MulticonductorNetwork, parse_file, parse_str, from_json

# Conversion and serialization
export convert_file, convert_str, to_format, to_normalized, to_normalized_with_options,
       to_json, to_matpower, write_pypsa_csv_folder

# Materialized numeric views
export to_dense, to_arrow, ArrowTable, release_c_data, arrow_catalog

# Sparse system matrices (Rust matrix feature)
export calc_admittance_matrix, calc_susceptance_matrix, calc_incidence_matrix,
       calc_bprime_matrix, calc_bdoubleprime_matrix

# Ecosystem bridges (PowerModels, ExaModels, gridfm). `to_powerdata`/`parse_ac_power_data`
# and the `LoadSeries` multiperiod-load surface are ExaModels-facing convenience bridges
# (documented as interim where they will be superseded by the Rust-backed series).
export to_powermodels, from_powermodels, to_powerdata, parse_ac_power_data,
       LoadSeries, read_load_series, n_periods,
       read_gridfm, read_gridfm_scenarios

# GO Challenge 3 (general, format-neutral SCOPF input data). `goc3_scopf_data` is the
# single entry point: it returns a `ScopfInstance` of per-class index sets in one call.
# The individual `_goc3_*` builders behind it are internal. `parse_scopf` is the
# Rust-parsed sibling: the native problem instance's versioned JSON (feature prob).
export parse_goc3_json, goc3_scopf_data, ScopfInstance,
       goc3_status_flags, goc3_add_status_flags!, goc3_interval_bounds,
       parse_scopf, scopf_available

# .pio.json network packages (Rust pkg feature)
export NetworkPackage, CompilerPackage, to_package, from_package, read_package, write_package,
       package_model_kind, package_available, validate_package, package_validation,
       package_diagnostics, package_operating_points, package_study,
       set_operating_points, materialize_operating_point, materialize_study_commit

# Multiconductor distribution
export multiconductor_to_balanced_preflight, lower_multiconductor_to_balanced,
       dist_available, dist_abi_version, dist_capabilities

# Graph projection and feature probes
export to_graph, features, has_feature, arrow_available, gridfm_available, matrix_available

include("capi.jl")        # library resolution, ABI handshake, BalancedNetworkHandle, buffer helpers
include("network.jl")     # BalancedNetwork and the parse / convert / serialize verbs
include("accessors.jl")   # element tables and scalar accessors
include("dense.jl")       # to_dense: numeric tables straight from the C ABI extractors
include("powermodels.jl") # PowerModels.jl network data bridge
include("exa.jl")         # ExaModels bridge: to_powerdata / parse_ac_power_data / LoadSeries
include("operatingpoints.jl") # OperatingPointSeries skeleton (reserved; not yet functional)
include("arrow.jl")       # Arrow C Data Interface export (feature arrow)
include("matrix.jl")      # sparse matrices computed by the Rust matrix API
include("gridfm.jl")      # gridfm-datakit Parquet reader (feature gridfm)
include("dist.jl")        # MulticonductorNetwork distribution API (feature dist)
include("display.jl")     # compact and multiline display for parsed networks
include("graphs.jl")      # graph projections for balanced and multiconductor models
include("package.jl")     # .pio.json network packages (feature pkg)
include("scopf.jl")       # native SCOPF problem instance JSON (feature prob)
include("features.jl")    # public feature probe summary (reads scopf.jl's probe)
include("goc3.jl")        # GO Challenge 3 JSON helpers (pure Julia)

end # module
