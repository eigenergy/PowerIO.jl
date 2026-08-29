"""
    PowerIO

Julia binding of the PowerIO power system data compiler. One call parses a
supported source into a typed module:

```julia
using PowerIO
case = parse_file("case9.m")       # PioModule{BalancedNetwork}
feeder = parse_file("feeder.dss")  # PioModule{MulticonductorNetwork}
case.value                         # the typed network, shared native data
diagnostics(case)                  # the reader's findings, native records
write_file(case, "copy.m")         # byte exact same format echo
```

The value kind is detected from the source: balanced network formats
(MATPOWER, PSS/E, PowerWorld, PSLF EPC, PowerModels JSON, Egret JSON,
pandapower JSON, PyPSA CSV, Surge JSON), multiconductor distribution formats
(OpenDSS, PMD engineering JSON), calculation formats (DOE GO Challenge 3 →
`AcScucInstance`, BMOPF → `McAcOpfInstance`, DeepMind OPFData →
`AcOpfSolution`), time series and scenario profiles (PyPSA snapshot axes,
Egret time keys, GridFM Parquet datasets), and the stored `.pio.json`
document. `m.value` is the typed network: matrix and conversion functions
dispatch on its type, while inspection, state selection, and writing take
the module itself.

The binding rides the `powerio-capi` C ABI (version 6): every handle keeps
its owning library, borrowed numerical views root their owner, and failures
carry structured [`Diagnostic`](@ref) records through
[`PowerIOCError`](@ref). At first use the binding checks the library's ABI
version and refuses a stale or mismatched library with both versions named.

The C library resolves automatically: the bundled artifact, or a sibling
powerio build during development. Point at a custom build with
[`set_library!`](@ref), the `POWERIO_CAPI` environment variable, or a
persisted Preferences.jl override.
"""
module PowerIO

using JSON3
using LazyArtifacts
using Preferences: @load_preference, load_preference, set_preferences!
import Libdl
import SparseArrays

# The typed module surface: the ordinary path after `using PowerIO`.
export PioModule, parse_file, parse_bytes, kind, diagnostics,
       write_file, write_str, write_json, inspect, source_format,
       state_inventory, select_state, lower_to_balanced, lowering_readiness

# The value families a module can hold.
export BalancedNetwork, MulticonductorNetwork, TimeSeries, ScenarioSet,
       OperatingPoint, UnknownValue,
       DcPfInstance, AcPfInstance, DcOpfInstance, AcOpfInstance,
       McAcPfInstance, McAcOpfInstance, AcScucInstance,
       DcPfSolution, AcPfSolution, DcOpfSolution, AcOpfSolution,
       McAcPfSolution, McAcOpfSolution, AcScucSolution

# Structured findings and failures.
export Diagnostic, SourceSpan, PowerIOCError

# Conversion and serialization over networks.
export convert_file, convert_str, to_format, to_normalized,
       to_json, from_json, to_matpower, write_pypsa_csv_folder

# Reading a parsed network. The element and scalar accessors stay
# unexported: their names collide with the ecosystem packages a consumer
# loads beside this one. `n_buses` does not, and the docs name it
# unqualified.
export n_buses

# C library resolution.
export set_library!, clear_library!

# DC branch data and borrowed numerical views.
export DcData, dc_data, BorrowedVector, branch_flow

# Materialized numeric views.
export to_dense, to_arrow, ArrowTable, release_c_data, arrow_catalog

# Sparse system matrices (Rust matrix feature).
export calc_admittance_matrix, calc_susceptance_matrix, calc_incidence_matrix,
       calc_bprime_matrix, calc_bdoubleprime_matrix

# Ecosystem bridges (PowerModels, ExaModels, gridfm).
export to_powermodels, from_powermodels, to_powerdata, parse_ac_power_data,
       read_gridfm, read_gridfm_scenarios

# Distribution availability and feature probes.
export dist_available, to_graph, features, has_feature, schema_versions,
       build_info, arrow_available, gridfm_available, matrix_available

include("capi.jl")        # library resolution, ABI handshake, handle types
include("diagnostics.jl") # native Diagnostic records over the structured C list
include("v6.jl")          # error handles, stored module handles, DC branch data
include("network.jl")     # BalancedNetwork and the convert / serialize verbs
include("accessors.jl")   # element tables and scalar accessors
include("dense.jl")       # to_dense: numeric tables straight from the C extractors
include("powermodels.jl") # PowerModels.jl network data bridge
include("exa.jl")         # ExaModels bridge: to_powerdata / parse_ac_power_data
include("arrow.jl")       # Arrow C Data Interface export (feature arrow)
include("matrix.jl")      # sparse matrices computed by the Rust matrix API
include("gridfm.jl")      # GridFM Parquet datasets through the module surface
include("dist.jl")        # MulticonductorNetwork distribution API (feature dist)
include("parse.jl")       # the typed value accessors behind PioModule wrapping
include("module.jl")      # PioModule{T}, parse_file, and the module operations
include("display.jl")     # compact and multiline display for parsed networks
include("graphs.jl")      # graph projections for balanced and multiconductor models
include("features.jl")    # public feature probe summary

end # module
