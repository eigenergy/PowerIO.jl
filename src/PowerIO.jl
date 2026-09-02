"""
    PowerIO

Julia binding of PowerIO, the power system data compiler, over C ABI 7.

```julia
using PowerIO
case = parse("case9.m")             # PioModule{BalancedNetwork}
net = case.value
length(net.buses)                   # 9
net.branches[1].reactance_pu
case.diagnostics                    # the reader's findings
emit(case, "matpower", "copy.m")    # same format: writes the original file unchanged
result = emit(case, "psse")         # another format, in memory
result.text
serialize(case, "case9.pio.json")   # PowerIO IR
```

`parse` reads a grid exchange source into a typed module. `emit` writes one.
`serialize` and `deserialize` move PowerIO IR between PowerIO consumers.
`calc_*` functions compute matrices and vectors. `to_*` functions construct
another value type in memory. `apply_updates!` changes a module in place.

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

# Operations. `parse` extends `Base.parse` and is not exported.
export PioModule, emit, serialize, deserialize

# Values.
export BalancedNetwork, MulticonductorNetwork, TimeSeries, ScenarioSet, OperatingPoint,
       DcPfInstance, AcPfInstance, DcOpfInstance, AcOpfInstance,
       McAcPfInstance, McAcOpfInstance, AcScucInstance,
       DcPfSolution, AcPfSolution, DcOpfSolution, AcOpfSolution, SocwrOpfSolution,
       McAcPfSolution, McAcOpfSolution, AcScucSolution, UnknownValue

# Records and results.
export Diagnostic, SourceSpan, PowerIOError, EmitResult, EmittedFile,
       Producer, ModuleSource, HistoryEntry

# Balanced network elements.
export Elements, ComponentId, TerminalReference, Location, Geo, DetailedConnectivity,
       Bus, Branch, Generator, Load, Shunt, StaticVarCompensator, Storage, Switch, Hvdc,
       ThreeWindingTransformer, Area,
       LoadVoltageModel, ShuntBlock, ShuntControl, TransformerControl, BranchRating,
       GeneratorCost, GeneratorCapability, ActivePowerControl, HvdcConverter,
       TransformerWinding, TransformerImpedance, reference_bus_ids

# Multiconductor network elements.
export MulticonductorBus, MulticonductorLineCode, MulticonductorLine, MulticonductorSwitch,
       MulticonductorTransformer, MulticonductorTransformerWinding, MulticonductorLoad,
       MulticonductorGenerator, InverterBasedResource, ControlProfile, VoltVarControl,
       VoltWattControl, MulticonductorShunt, MulticonductorCapacitor, VoltageSource,
       UntypedObject, SourceCommand

# Dense tables and graph projections.
export to_dense, to_graph

# Matrices and vectors.
export calc_incidence_matrix, calc_branch_susceptances, calc_bus_susceptance_matrix,
       calc_branch_flow_matrix, calc_branch_phase_shift_injection, calc_bus_phase_shift_injection,
       calc_branch_flow_dc, calc_bus_injection_dc,
       calc_admittance_matrix, calc_bprime_matrix, calc_bdoubleprime_matrix, BusMappedMatrix

# Calculation constructions and solution access.
export to_dc_pf_instance, to_ac_pf_instance, to_dc_opf_instance, to_ac_opf_instance,
       to_mc_ac_pf_instance, to_mc_ac_opf_instance, time_count

# Typed updates.
export ActivePower, ReactivePower, ApparentPower, OperatingPointUpdate, NetworkUpdate,
       UpdateReport, UpdateChange, apply_updates!,
       set_load_active_power, set_load_reactive_power, set_generator_active_power,
       set_generator_reactive_power, set_generator_voltage_magnitude, set_generator_in_service,
       set_branch_in_service, set_transformer_tap_ratio, set_transformer_phase_shift_degrees,
       set_switch_closed, set_branch_thermal_rating

# Solver and modeling bridges.
export to_powermodels, from_powermodels, build_powermodels_ref, repair_powermodels_angle_bounds!,
       to_powerdata, to_ac_power_data

# Library resolution.
export set_library!, clear_library!, abi_version, library_version, library_available

include("views.jl")          # C struct mirrors and span conversions
include("capi.jl")           # library resolution and the ABI handshake
include("handles.jl")        # owned handle types with release finalizers
include("diagnostics.jl")    # Diagnostic and SourceSpan
include("errors.jl")         # PowerIOError and the checked call helpers
include("values.jl")         # the value type tree and structural name dispatch
include("module.jl")         # PioModule, parse, deserialize, records
include("emit.jl")           # emit, serialize, EmitResult, EmittedFile
include("network.jl")        # BalancedNetwork properties and element structs
include("multiconductor.jl") # MulticonductorNetwork properties and element structs
include("dense.jl")          # to_dense
include("graphs.jl")         # to_graph
include("collections.jl")    # TimeSeries, ScenarioSet, OperatingPoint
include("instances.jl")      # calculation instances, solutions, to_*_instance
include("updates.jl")        # typed updates and apply_updates!
include("calc.jl")           # the eight DC calculations from the library
include("ybus.jl")           # admittance matrices assembled in Julia
include("powermodels.jl")    # PowerModels.jl network data bridge
include("exa.jl")            # ExaModelsPower bridge and LoadSeries
include("display.jl")        # show methods

end # module
