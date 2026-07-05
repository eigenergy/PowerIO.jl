"""
    PowerIO

Julia entry point for the PowerIO Rust core: parser, compiler package, and IR
infrastructure for power system software. Parse MATPOWER, PSS/E, PowerWorld,
PSLF EPC, PowerModels JSON, egret JSON, pandapower JSON, PyPSA CSV, Surge JSON,
and PowerIO JSON cases, convert between supported pairs, and materialize an
immutable `BalancedNetwork`, all through the `powerio-capi` C ABI.

Parse once with [`parse_file`](@ref) → [`BalancedNetwork`](@ref), then read or transform it,
all over the same C ABI:

- the rich, lossless element tables via the JSON transport (every field + extras,
  costs, storage, HVDC): the accessors and [`to_json`](@ref).
- [`to_dense`](@ref): the numeric tables as dense typed arrays for matrix assembly,
  straight from the C ABI extractors, no JSON.
- [`to_arrow`](@ref): one table over the Arrow C Data Interface (owned columns by
  default; zero copy with `copy=false`), including matrix COO selectors when the
  matrix surface is present.

[`to_normalized`](@ref) derives a per unit / radian / filtered copy that preserves
source bus ids, and
[`to_matpower`](@ref) / [`convert_file`](@ref) serialize back out.

[`read_gridfm`](@ref) / [`read_gridfm_scenarios`](@ref) read a gridfm-datakit Parquet
dataset back into a `BalancedNetwork` (the ML→classical return leg; lossy but complete
enough for power flow, needs powerio-capi built `--features gridfm`).

Multiconductor distribution cases are a separate model, [`MulticonductorNetwork`](@ref),
with the same shape as the balanced side: a live handle and lazy element tables
(`net.data`). The bare verbs route on the format — `parse_file("feeder.dss")`,
`convert_file("feeder.dss", "bmopf")`, `parse_file("case.pio.json")` — and the
type-marker forms (`parse_file(MulticonductorNetwork, path)`) stay as the
explicit spelling. OpenDSS, PowerModelsDistribution JSON, and IEEE BMOPF JSON
read and write (experimental; needs powerio-capi built `--features dist`, plus
`pkg` for the element tables).

`.pio.json` network packages use the `pio_package_*` C ABI surface. They can
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

export BalancedNetwork, parse_file, parse_str, from_json, convert_file, convert_str,
       to_format, to_normalized, to_normalized_with_options, to_json, to_dense,
       to_matpower, to_arrow, calc_admittance_matrix, calc_susceptance_matrix,
       calc_incidence_matrix, calc_bprime_matrix, calc_bdoubleprime_matrix,
       ArrowTable, write_pypsa_csv_folder, to_powermodels, from_powermodels,
       to_powerdata, parse_ac_power_data, read_gridfm, read_gridfm_scenarios,
       parse_goc3_json, goc3_status_flags, goc3_add_status_flags!,
       NetworkPackage, CompilerPackage, to_package, from_package, read_package, write_package,
       package_model_kind, package_available, validate_package, package_validation,
       package_diagnostics, package_operating_points, package_study,
       materialize_operating_point, materialize_study_commit,
       multiconductor_to_balanced_preflight,
       lower_multiconductor_to_balanced, arrow_available, gridfm_available,
       matrix_available, features, MulticonductorNetwork, dist_available, dist_abi_version,
       dist_capabilities, to_graph

include("capi.jl")        # library resolution, ABI handshake, BalancedNetworkHandle, buffer helpers
include("network.jl")     # BalancedNetwork and the parse / convert / serialize verbs
include("accessors.jl")   # element tables and scalar accessors
include("dense.jl")       # to_dense: numeric tables straight from the C ABI extractors
include("powermodels.jl") # PowerModels.jl network data bridge
include("powerdata.jl")   # ExaPowerIO / ExaModelsPower PowerData bridge
include("arrow.jl")       # Arrow C Data Interface export (feature arrow)
include("matrix.jl")      # sparse matrices computed by the Rust matrix surface
include("gridfm.jl")      # gridfm-datakit Parquet reader (feature gridfm)
include("dist.jl")        # MulticonductorNetwork distribution surface (feature dist)
include("graphs.jl")      # graph projections for balanced and multiconductor models
include("package.jl")     # .pio.json network packages (feature pkg)
include("features.jl")    # public feature probe summary
include("goc3.jl")        # GO Challenge 3 JSON helpers (pure Julia)

end # module
