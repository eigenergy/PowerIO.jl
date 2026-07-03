"""
    PowerIO

Julia bindings for the PowerIO Rust core: parse MATPOWER / PSS/E / PowerWorld /
PowerModels JSON / egret JSON case files, convert between any pair (byte exact on a
same-format round trip, maximal fidelity otherwise), and materialize an immutable
`BalancedNetwork`, all through the `powerio-capi` C ABI.

Parse once with [`parse_file`](@ref) → [`BalancedNetwork`](@ref), then read or transform it,
all over the same C ABI:

- the rich, lossless element tables via the JSON transport (every field + extras,
  costs, storage, HVDC): the accessors and [`to_json`](@ref).
- [`to_dense`](@ref): the numeric tables as dense typed arrays for matrix assembly,
  straight from the C ABI extractors, no JSON.
- [`to_arrow`](@ref): one table over the Arrow C Data Interface (owned columns by
  default; zero copy with `copy=false`).

[`to_normalized`](@ref) derives a per unit / radian / filtered copy that preserves
source bus ids, and
[`to_matpower`](@ref) / [`convert_file`](@ref) serialize back out.

[`read_gridfm`](@ref) / [`read_gridfm_scenarios`](@ref) read a gridfm-datakit Parquet
dataset back into a `BalancedNetwork` (the ML→classical return leg; lossy but complete
enough for power flow, needs powerio-capi built `--features gridfm`).

Multiconductor distribution cases are a separate model on their own
[`MulticonductorNetwork`](@ref) handle, sharing the same verbs: `parse_file(MulticonductorNetwork, path)`,
`to_format(net, to)`, `convert_file(MulticonductorNetwork, path, to)` read and write OpenDSS,
PowerModelsDistribution JSON, and IEEE BMOPF JSON (experimental; needs powerio-capi
built `--features dist`).

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
[`set_library!`](@ref) or the `POWERIO_CAPI` environment variable.
"""
module PowerIO

using JSON3
using LazyArtifacts
import Libdl

export BalancedNetwork, parse_file, parse_str, from_json, convert_file, convert_str,
       to_format, to_normalized, to_json, to_dense, to_matpower, to_arrow,
       ArrowTable, write_pypsa_csv_folder, to_powermodels, from_powermodels,
       to_powerdata, parse_ac_power_data, read_gridfm, read_gridfm_scenarios,
       parse_goc3_json, goc3_status_flags, goc3_add_status_flags!,
       NetworkPackage, CompilerPackage, to_package, from_package, read_package, write_package,
       package_model_kind, package_available, validate_package, package_validation,
       package_diagnostics, package_operating_points, materialize_operating_point,
       multiconductor_to_balanced_preflight,
       lower_multiconductor_to_balanced, arrow_available, gridfm_available,
       MulticonductorNetwork, dist_available, dist_abi_version

include("capi.jl")        # library resolution, ABI handshake, NetworkHandle, buffer helpers
include("network.jl")     # BalancedNetwork and the parse / convert / serialize verbs
include("accessors.jl")   # the JSON-backed element tables and scalar accessors
include("dense.jl")       # to_dense: numeric tables straight from the C ABI extractors
include("powermodels.jl") # PowerModels.jl network data bridge
include("powerdata.jl")   # ExaPowerIO / ExaModelsPower PowerData bridge
include("arrow.jl")       # Arrow C Data Interface export (feature arrow)
include("gridfm.jl")      # gridfm-datakit Parquet reader (feature gridfm)
include("dist.jl")        # MulticonductorNetwork distribution surface (feature dist)
include("package.jl")     # .pio.json network packages (feature pkg)
include("goc3.jl")        # GO Challenge 3 JSON helpers (pure Julia)

end # module
