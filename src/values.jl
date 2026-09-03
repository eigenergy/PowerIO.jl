# The typed values a module can hold, and the structural type name dispatch
# that chooses among them.
#
# Every value wraps a C handle borrowed from a module. The C library keeps the module
# data alive for as long as any borrowed handle exists, so a value outlives the
# module handle it came from. Values that come straight from a module also keep
# the module handle so operations that need the module (emission, PowerModels
# export) can reach it.

"""
    BalancedNetwork

A positive sequence network: buses, branches, generators, loads, shunts, and
the other balanced element tables. Read the tables through properties:
`net.buses`, `net.branches`, `net.generators`, `net.loads`, `net.shunts`,
`net.static_var_compensators`, `net.storage`, `net.switches`, `net.hvdc`,
`net.transformers_3w`, `net.areas`. Scalars: `net.name`, `net.base_mva`,
`net.base_frequency`, `net.geo`, `net.detailed_connectivity`.
"""
struct BalancedNetwork
    handle::BalancedNetworkHandle
    owner::Union{ModuleHandle,Nothing}
end

"""
    MulticonductorNetwork

A conductor level distribution network. Read the tables through properties:
`net.buses`, `net.linecodes`, `net.lines`, `net.switches`, `net.transformers`,
`net.loads`, `net.generators`, `net.ibrs`, `net.control_profiles`,
`net.shunts`, `net.capacitors`, `net.voltage_sources`, `net.untyped`,
`net.commands`, `net.options`. Scalars: `net.name`, `net.base_frequency`,
`net.source_format`, `net.geo`.
"""
struct MulticonductorNetwork
    handle::MulticonductorNetworkHandle
    owner::Union{ModuleHandle,Nothing}
end

"""
    GeoLayer

A standalone geographic document: element points and routes keyed by element
identity, in one coordinate space. `parse` returns it for the canonical
`.geo.json`, GeoJSON, aliased CSV or JSON records, headerless buscoords CSV,
and a PowerWorld `.pwd` display. `layer.diagnostics` lists the reader's notes
on records it could not use. `emit(m, "geo-json")` writes the canonical
document and `serialize` carries the layer through PowerIO IR.

The C ABI keeps a layer's features to itself, so this release reads the
document rather than the individual features; place a layer onto a case in
Rust, Python, or the command line.
"""
struct GeoLayer
    handle::GeoLayerHandle
end

"""
    TimeSeries{T}

Values of type `T` in chronological order. Supports `length`, 1-based
`getindex`, and iteration over the values.
"""
struct TimeSeries{T}
    handle::TimeSeriesHandle
end

"""
    ScenarioSet{T}

Values of type `T` keyed by scenario identifier. Supports `length`, `keys`,
`values`, `haskey`, `getindex` with a scenario id, and iteration over
`id => value` pairs.
"""
struct ScenarioSet{T}
    handle::ScenarioSetHandle
end

"""
    OperatingPoint{N}

One operating point over a network of type `N`. `point.network` is that network.
"""
struct OperatingPoint{N}
    handle::OperatingPointHandle
end

# Calculation instances: a network plus the specification of one calculation.
# `instance.network` is the network.
for (name, doc) in (
        (:DcPfInstance, "DC power flow instance over a `BalancedNetwork`."),
        (:AcPfInstance, "AC power flow instance over a `BalancedNetwork`."),
        (:DcOpfInstance, "DC optimal power flow instance over a `BalancedNetwork`."),
        (:AcOpfInstance, "AC optimal power flow instance over a `BalancedNetwork`."),
        (:McAcPfInstance, "Multiconductor AC power flow instance over a `MulticonductorNetwork`."),
        (:McAcOpfInstance, "Multiconductor AC optimal power flow instance over a `MulticonductorNetwork`."),
        (:AcScucInstance, "AC security constrained unit commitment instance over a `BalancedNetwork`."),
    )
    @eval begin
        Core.@doc $("    $name\n\n$doc `instance.network` is the network.") struct $name
            handle::CalculationInstanceHandle
        end
    end
end

const CalculationInstance = Union{DcPfInstance,AcPfInstance,DcOpfInstance,AcOpfInstance,
                                  McAcPfInstance,McAcOpfInstance,AcScucInstance}

# Calculation solutions: the instance they answer, the termination status, and
# the reported quantities.
for (name, doc) in (
        (:DcPfSolution, "DC power flow solution."),
        (:AcPfSolution, "AC power flow solution."),
        (:DcOpfSolution, "DC optimal power flow solution."),
        (:AcOpfSolution, "AC optimal power flow solution."),
        (:SocwrOpfSolution, "Second order cone (SOCWR) relaxation of an AC OPF instance; not an AC feasible point."),
        (:McAcPfSolution, "Multiconductor AC power flow solution."),
        (:McAcOpfSolution, "Multiconductor AC optimal power flow solution."),
        (:AcScucSolution, "AC security constrained unit commitment solution."),
    )
    @eval begin
        Core.@doc $("    $name\n\n$doc `solution.instance` is the instance it answers and `solution.termination` the solver status.") struct $name
            handle::CalculationSolutionHandle
        end
    end
end

const CalculationSolution = Union{DcPfSolution,AcPfSolution,DcOpfSolution,AcOpfSolution,
                                  SocwrOpfSolution,McAcPfSolution,McAcOpfSolution,AcScucSolution}

"""
    UnknownValue

A module value whose structural type name this PowerIO.jl release does not
bind. `value.type_name` is the name the library reports.
"""
struct UnknownValue
    type_name::String
    handle::ValueHandle
end

# --- structural type names -------------------------------------------------

const _INSTANCE_TYPES = Dict(
    "powerio.DcPfInstance" => (DcPfInstance, :pio_value_dc_pf_instance),
    "powerio.AcPfInstance" => (AcPfInstance, :pio_value_ac_pf_instance),
    "powerio.DcOpfInstance" => (DcOpfInstance, :pio_value_dc_opf_instance),
    "powerio.AcOpfInstance" => (AcOpfInstance, :pio_value_ac_opf_instance),
    "powerio.McAcPfInstance" => (McAcPfInstance, :pio_value_mc_ac_pf_instance),
    "powerio.McAcOpfInstance" => (McAcOpfInstance, :pio_value_mc_ac_opf_instance),
    "powerio.AcScucInstance" => (AcScucInstance, :pio_value_ac_scuc_instance),
)

const _SOLUTION_TYPES = Dict(
    "powerio.DcPfSolution" => (DcPfSolution, :pio_value_dc_pf_solution),
    "powerio.AcPfSolution" => (AcPfSolution, :pio_value_ac_pf_solution),
    "powerio.DcOpfSolution" => (DcOpfSolution, :pio_value_dc_opf_solution),
    "powerio.AcOpfSolution" => (AcOpfSolution, :pio_value_ac_opf_solution),
    "powerio.SocwrOpfSolution" => (SocwrOpfSolution, :pio_value_socwr_opf_solution),
    "powerio.McAcPfSolution" => (McAcPfSolution, :pio_value_mc_ac_pf_solution),
    "powerio.McAcOpfSolution" => (McAcOpfSolution, :pio_value_mc_ac_opf_solution),
    "powerio.AcScucSolution" => (AcScucSolution, :pio_value_ac_scuc_solution),
)

# The Julia type named by one structural type name, or `nothing` for a name
# this release does not bind. Generic names nest: `powerio.TimeSeries<X>` is
# `TimeSeries{julia_type(X)}`.
function _julia_type(name::AbstractString)
    name == "powerio.BalancedNetwork" && return BalancedNetwork
    name == "powerio.MulticonductorNetwork" && return MulticonductorNetwork
    name == "powerio.GeoLayer" && return GeoLayer
    haskey(_INSTANCE_TYPES, name) && return _INSTANCE_TYPES[name][1]
    haskey(_SOLUTION_TYPES, name) && return _SOLUTION_TYPES[name][1]
    for (prefix, wrapper) in (("powerio.TimeSeries<", TimeSeries),
                              ("powerio.ScenarioSet<", ScenarioSet),
                              ("powerio.OperatingPoint<", OperatingPoint))
        if startswith(name, prefix) && endswith(name, ">")
            inner = _julia_type(name[nextind(name, lastindex(prefix)):prevind(name, lastindex(name))])
            inner === nothing && return nothing
            return wrapper{inner}
        end
    end
    return nothing
end

# Borrow one typed handle from a value handle through `sym`.
function _borrow(lib::AbstractString, value::ValueHandle, sym::Symbol)
    return GC.@preserve value _checked(lib) do err
        ccall(_library_symbol(lib, sym), Ptr{Cvoid}, (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), _ptr(value), err)
    end
end

# Wrap a value handle as the Julia value its structural type name selects.
# `owner` is the module the value came from when there is one.
function _wrap_value(lib::AbstractString, value::ValueHandle, owner::Union{ModuleHandle,Nothing})
    name = GC.@preserve value _str(ccall(_library_symbol(lib, :pio_value_type_name), PioStringView,
                                         (Ptr{Cvoid},), _ptr(value)))
    T = _julia_type(name)
    T === nothing && return UnknownValue(name, value)
    wrapped = _wrap_as(T, lib, value, owner)
    release!(value)
    return wrapped
end

_wrap_as(::Type{BalancedNetwork}, lib, value, owner) =
    BalancedNetwork(BalancedNetworkHandle(_borrow(lib, value, :pio_value_balanced_network), lib), owner)
_wrap_as(::Type{MulticonductorNetwork}, lib, value, owner) =
    MulticonductorNetwork(MulticonductorNetworkHandle(_borrow(lib, value, :pio_value_multiconductor_network), lib), owner)
_wrap_as(::Type{GeoLayer}, lib, value, owner) =
    GeoLayer(GeoLayerHandle(_borrow(lib, value, :pio_value_geo_layer), lib))
_wrap_as(::Type{TimeSeries{T}}, lib, value, owner) where {T} =
    TimeSeries{T}(TimeSeriesHandle(_borrow(lib, value, :pio_value_time_series), lib))
_wrap_as(::Type{ScenarioSet{T}}, lib, value, owner) where {T} =
    ScenarioSet{T}(ScenarioSetHandle(_borrow(lib, value, :pio_value_scenario_set), lib))
_wrap_as(::Type{OperatingPoint{BalancedNetwork}}, lib, value, owner) =
    OperatingPoint{BalancedNetwork}(OperatingPointHandle(_borrow(lib, value, :pio_value_balanced_operating_point), lib))
_wrap_as(::Type{OperatingPoint{MulticonductorNetwork}}, lib, value, owner) =
    OperatingPoint{MulticonductorNetwork}(OperatingPointHandle(_borrow(lib, value, :pio_value_multiconductor_operating_point), lib))
function _wrap_as(::Type{T}, lib, value, owner) where {T<:CalculationInstance}
    sym = _INSTANCE_TYPES[_type_name(T)][2]
    return T(CalculationInstanceHandle(_borrow(lib, value, sym), lib))
end
function _wrap_as(::Type{T}, lib, value, owner) where {T<:CalculationSolution}
    sym = _SOLUTION_TYPES[_type_name(T)][2]
    return T(CalculationSolutionHandle(_borrow(lib, value, sym), lib))
end

# The structural type name of a bound Julia type.
_type_name(::Type{BalancedNetwork}) = "powerio.BalancedNetwork"
_type_name(::Type{MulticonductorNetwork}) = "powerio.MulticonductorNetwork"
_type_name(::Type{GeoLayer}) = "powerio.GeoLayer"
_type_name(::Type{TimeSeries{T}}) where {T} = "powerio.TimeSeries<" * _type_name(T) * ">"
_type_name(::Type{ScenarioSet{T}}) where {T} = "powerio.ScenarioSet<" * _type_name(T) * ">"
_type_name(::Type{OperatingPoint{T}}) where {T} = "powerio.OperatingPoint<" * _type_name(T) * ">"
_type_name(::Type{T}) where {T<:CalculationInstance} = "powerio." * String(nameof(T))
_type_name(::Type{T}) where {T<:CalculationSolution} = "powerio." * String(nameof(T))

# The library a value's handle was allocated by.
_lib_of(v) = getfield(getfield(v, :handle), :lib)
_lib_of(v::UnknownValue) = getfield(v.handle, :lib)

function Base.getproperty(layer::GeoLayer, name::Symbol)
    if name === :diagnostics
        handle = getfield(layer, :handle)
        lib = handle.lib
        return GC.@preserve handle _diagnostics(lib,
            ccall(_library_symbol(lib, :pio_geo_layer_diagnostics), Ptr{Cvoid},
                  (Ptr{Cvoid},), _ptr(handle)))
    end
    return getfield(layer, name)
end

Base.propertynames(::GeoLayer, private::Bool=false) =
    private ? (:diagnostics, :handle) : (:diagnostics,)
