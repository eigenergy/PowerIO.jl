# `BalancedNetwork`: properties over the owner rooted network handle, element
# collections, and the immutable element structs they produce.
#
# Every element struct repeats the C view's field names without the `has_*`
# companions: an absent optional is `nothing`. Nested tables the C ABI exposes
# through secondary `_at` calls (branch ratings, generator capabilities, shunt
# blocks, transformer windings, route points) are materialized as fields.
# Bus ids are source bus numbers. Loads, shunts, and generators are one row per
# element and several rows can share a bus.

"""
    ComponentId(component_type, local_id)

Stable identity of one component: its structural type (`"bus"`, `"load"`,
`"generator"`, `"branch"`, `"switch"`, ...) and its local identity. An
element's `component_id` field is the local identity, so
`ComponentId("load", load.component_id)` names that load in an update.
"""
struct ComponentId
    component_type::String
    local_id::String
end

_component_id(v::PioComponentIdView) = ComponentId(_str(v.component_type), _str(v.local_id))

"""
    TerminalReference(equipment, terminal)

A numbered terminal of one piece of equipment.
"""
struct TerminalReference
    equipment::ComponentId
    terminal::Int
end

_terminal_reference(v::PioTerminalReferenceView, present::Bool) =
    present ? TerminalReference(_component_id(v.equipment), Int(v.terminal)) : nothing

"""
    Location(x, y, kind)

One point in the network coordinate space. `kind` names the point kind when
the source states one.
"""
struct Location
    x::Float64
    y::Float64
    kind::Union{String,Nothing}
end

_location(v::Union{PioBalancedLocationView,PioMulticonductorLocationView}, present::Bool) =
    present ? Location(v.x, v.y, _optional_str(v.kind, v.has_kind)) : nothing

"""
    Geo

Coordinate metadata of a network: the coordinate `space`, its `crs` and
`kind` when stated, and the canvas size (`canvas_width`, `canvas_height`,
`canvas_units`) for display coordinates.
"""
struct Geo
    space::String
    crs::Union{String,Nothing}
    kind::Union{String,Nothing}
    canvas_width::Union{Float64,Nothing}
    canvas_height::Union{Float64,Nothing}
    canvas_units::Union{String,Nothing}
end

function _geo(v::Union{PioBalancedGeoView,PioMulticonductorGeoView})
    v.has_geo || return nothing
    return Geo(_str(v.space), _optional_str(v.crs, v.has_crs), _optional_str(v.kind, v.has_kind),
               _optional(v.canvas_width, v.has_canvas && v.has_canvas_width),
               _optional(v.canvas_height, v.has_canvas && v.has_canvas_height),
               _optional_str(v.canvas_units, v.has_canvas && v.has_canvas_units))
end

# --- element structs ------------------------------------------------------

"""
    Bus

One balanced bus. `id` is the source bus number; `bus_type` is `"PQ"`, `"PV"`,
`"REF"`, or `"ISOLATED"`; voltages are per unit and degrees.
"""
struct Bus
    id::Int
    component_id::Union{String,Nothing}
    bus_type::String
    vm_pu::Float64
    va_degrees::Float64
    base_kv::Float64
    vmax_pu::Float64
    vmin_pu::Float64
    emergency_vmax_pu::Union{Float64,Nothing}
    emergency_vmin_pu::Union{Float64,Nothing}
    area::Int
    zone::Int
    name::Union{String,Nothing}
    location::Union{Location,Nothing}
end

"""
    LoadVoltageModel

Voltage dependence of one load: `kind` names the model; the constant power,
constant current, and constant impedance shares and the exponential terms
follow the C view field for field.
"""
struct LoadVoltageModel
    kind::String
    p_constant_power_mw::Float64
    q_constant_power_mvar::Float64
    p_constant_current_mw::Float64
    q_constant_current_mvar::Float64
    p_constant_impedance_mw::Float64
    q_constant_impedance_mvar::Float64
    exponential_p_mw::Float64
    exponential_q_mvar::Float64
    gamma_p::Float64
    gamma_q::Float64
    nominal_voltage_pu::Union{Float64,Nothing}
    load_type::Union{Int,Nothing}
    scaling::Union{Float64,Nothing}
end

"""
    Load

One balanced load at `bus_id`: `p_mw`, `q_mvar`, `in_service`, and its
`voltage_model`.
"""
struct Load
    component_id::Union{String,Nothing}
    bus_id::Int
    p_mw::Float64
    q_mvar::Float64
    in_service::Bool
    voltage_model::LoadVoltageModel
end

"""
    ShuntBlock(steps, conductance_mw, susceptance_mvar)

One block of a switched shunt.
"""
struct ShuntBlock
    steps::Int
    conductance_mw::Float64
    susceptance_mvar::Float64
end

"""
    ShuntControl

Switched shunt control: `mode`, the voltage band `vmax_pu` and `vmin_pu`, the
controlled `bus_id` when it differs from the shunt's bus, the reactive range
percent, and the switchable `blocks`.
"""
struct ShuntControl
    mode::String
    vmax_pu::Float64
    vmin_pu::Float64
    bus_id::Union{Int,Nothing}
    reactive_range_percent::Float64
    blocks::Vector{ShuntBlock}
end

"""
    Shunt

One balanced shunt at `bus_id`: `conductance_mw` and `susceptance_mvar` at
nominal voltage, `in_service`, the `section_count` when stated, and the
switched shunt `control` when present.
"""
struct Shunt
    component_id::Union{String,Nothing}
    bus_id::Int
    conductance_mw::Float64
    susceptance_mvar::Float64
    in_service::Bool
    section_count::Union{Int,Nothing}
    control::Union{ShuntControl,Nothing}
end

"""
    StaticVarCompensator

One balanced static VAR compensator.
"""
struct StaticVarCompensator
    component_id::Union{String,Nothing}
    bus_id::Int
    minimum_susceptance_siemens::Float64
    maximum_susceptance_siemens::Float64
    voltage_setpoint_kv::Float64
    reactive_power_setpoint_mvar::Float64
    regulation_mode::String
    regulating::Bool
    regulating_terminal::Union{TerminalReference,Nothing}
    active_power_mw::Float64
    reactive_power_mvar::Float64
    in_service::Bool
end

"""
    TransformerControl

Automatic tap or phase control of a transformer branch or winding.
"""
struct TransformerControl
    mode::String
    enabled::Bool
    controlled_bus_id::Union{Int,Nothing}
    controlled_bus_on_winding_side::Bool
    regulating_terminal::Union{TerminalReference,Nothing}
    tap_min::Float64
    tap_max::Float64
    band_min::Float64
    band_max::Float64
    tap_position_count::Int
    mva_base::Float64
    winding_connection_angle::Union{Float64,Nothing}
end

function _transformer_control(v::PioTransformerControlView, present::Bool)
    present || return nothing
    return TransformerControl(_str(v.mode), v.enabled,
                              _optional(Int(v.controlled_bus_id), v.has_controlled_bus),
                              v.controlled_bus_on_winding_side,
                              _terminal_reference(v.regulating_terminal, v.has_regulating_terminal),
                              v.tap_min, v.tap_max, v.band_min, v.band_max,
                              Int(v.tap_position_count), v.mva_base,
                              _optional(v.winding_connection_angle, v.has_winding_connection_angle))
end

"""
    BranchRating(name, rate_mva)

One named MVA rating of a branch beyond ratings A, B, and C.
"""
struct BranchRating
    name::String
    rate_mva::Float64
end

"""
    Branch

One balanced branch or two winding transformer between `from_bus_id` and
`to_bus_id`. Impedances and charging are per unit on the system base;
`total_charging_susceptance_pu` is the whole line charging and the four
terminal terms give its split; `tap_ratio` is the source value (0 means 1) and
`effective_tap_ratio` the value in effect; `phase_shift_degrees`, the angle
limits, ratings A, B, C in MVA, further named `ratings`, optional
`current_ratings` (A, B, C in amperes), the transformer `control`, and the
geographic `route`.
"""
struct Branch
    component_id::Union{String,Nothing}
    name::Union{String,Nothing}
    from_bus_id::Int
    to_bus_id::Int
    resistance_pu::Float64
    reactance_pu::Float64
    total_charging_susceptance_pu::Float64
    terminal_charging_is_explicit::Bool
    from_conductance_pu::Float64
    from_susceptance_pu::Float64
    to_conductance_pu::Float64
    to_susceptance_pu::Float64
    rate_a_mva::Float64
    rate_b_mva::Float64
    rate_c_mva::Float64
    ratings::Vector{BranchRating}
    current_ratings::Union{NTuple{3,Float64},Nothing}
    tap_ratio::Float64
    effective_tap_ratio::Float64
    phase_shift_degrees::Float64
    in_service::Bool
    angle_min_degrees::Float64
    angle_max_degrees::Float64
    control::Union{TransformerControl,Nothing}
    route::Union{Vector{Location},Nothing}
end

"""
    GeneratorCost

One MATPOWER style cost curve: `model` (1 piecewise linear, 2 polynomial),
`startup` and `shutdown` costs, `ncost`, and the `coefficients`.
"""
struct GeneratorCost
    model::Int
    startup::Float64
    shutdown::Float64
    ncost::Int
    coefficients::Vector{Float64}
end

_generator_cost(v::PioGeneratorCostView, present::Bool) =
    present ? GeneratorCost(Int(v.model), v.startup, v.shutdown, Int(v.ncost), _f64s(v.coefficients)) : nothing

"""
    ActivePowerControl

Governor and distributed slack settings of a generator or storage element.
"""
struct ActivePowerControl
    participate::Bool
    droop_percent::Union{Float64,Nothing}
    participation_factor::Union{Float64,Nothing}
    minimum_target_active_power_mw::Union{Float64,Nothing}
    maximum_target_active_power_mw::Union{Float64,Nothing}
end

function _active_power_control(v::PioActivePowerControlView, present::Bool)
    present || return nothing
    return ActivePowerControl(v.participate,
                              _optional(v.droop_percent, v.has_droop_percent),
                              _optional(v.participation_factor, v.has_participation_factor),
                              _optional(v.minimum_target_active_power_mw, v.has_minimum_target_active_power),
                              _optional(v.maximum_target_active_power_mw, v.has_maximum_target_active_power))
end

"""
    GeneratorCapability(name, value)

One optional generator capability or ramp field; `value` is `nothing` when
the source leaves it unset.
"""
struct GeneratorCapability
    name::String
    value::Union{Float64,Nothing}
end

"""
    Generator

One balanced generator at `bus_id`: dispatch, limits, voltage setpoint,
machine base, service status, `cost`, the `regulated_bus_id` when it differs
from the connection bus, `capabilities`, `active_power_control`, and the
voltage regulation state.
"""
struct Generator
    component_id::Union{String,Nothing}
    bus_id::Int
    energy_source::String
    active_power_mw::Float64
    reactive_power_mvar::Float64
    active_power_max_mw::Float64
    active_power_min_mw::Float64
    reactive_power_max_mvar::Float64
    reactive_power_min_mvar::Float64
    voltage_setpoint_pu::Float64
    machine_base_mva::Float64
    in_service::Bool
    cost::Union{GeneratorCost,Nothing}
    regulated_bus_id::Union{Int,Nothing}
    capabilities::Vector{GeneratorCapability}
    active_power_control::Union{ActivePowerControl,Nothing}
    voltage_regulation_on::Bool
    regulating_terminal::Union{TerminalReference,Nothing}
end

"""
    Storage

One balanced storage element at `bus_id`.
"""
struct Storage
    component_id::Union{String,Nothing}
    bus_id::Int
    active_power_mw::Float64
    reactive_power_mvar::Float64
    energy_mwh::Float64
    energy_rating_mwh::Float64
    charge_rating_mw::Float64
    discharge_rating_mw::Float64
    charge_efficiency::Float64
    discharge_efficiency::Float64
    thermal_rating_mva::Float64
    current_rating::Union{Float64,Nothing}
    reactive_power_min_mvar::Float64
    reactive_power_max_mvar::Float64
    resistance_pu::Float64
    reactance_pu::Float64
    active_power_loss_mw::Float64
    reactive_power_loss_mvar::Float64
    in_service::Bool
    active_power_control::Union{ActivePowerControl,Nothing}
end

"""
    Switch

One balanced transmission switch between `from_bus_id` and `to_bus_id`.
"""
struct Switch
    component_id::Union{String,Nothing}
    from_bus_id::Int
    to_bus_id::Int
    closed::Bool
    thermal_rating_mva::Union{Float64,Nothing}
    current_rating_a::Union{Float64,Nothing}
    from_active_power_mw::Union{Float64,Nothing}
    from_reactive_power_mvar::Union{Float64,Nothing}
    to_active_power_mw::Union{Float64,Nothing}
    to_reactive_power_mvar::Union{Float64,Nothing}
end

"""
    HvdcConverter

One AC terminal converter station of an HVDC line.
"""
struct HvdcConverter
    component::ComponentId
    kind::String
    loss_factor_percent::Float64
    voltage_regulator_on::Union{Bool,Nothing}
    voltage_setpoint_kv::Union{Float64,Nothing}
    reactive_power_setpoint_mvar::Union{Float64,Nothing}
    power_factor::Union{Float64,Nothing}
    regulating_terminal::Union{TerminalReference,Nothing}
end

function _hvdc_converter(v::PioBalancedHvdcConverterView, present::Bool)
    present || return nothing
    return HvdcConverter(_component_id(v.component), _str(v.kind), v.loss_factor_percent,
                         _optional(v.voltage_regulator_on, v.has_voltage_regulator_on),
                         _optional(v.voltage_setpoint_kv, v.has_voltage_setpoint),
                         _optional(v.reactive_power_setpoint_mvar, v.has_reactive_power_setpoint),
                         _optional(v.power_factor, v.has_power_factor),
                         _terminal_reference(v.regulating_terminal, v.has_regulating_terminal))
end

"""
    Hvdc

One balanced two terminal HVDC line.
"""
struct Hvdc
    component_id::Union{String,Nothing}
    from_bus_id::Int
    to_bus_id::Int
    in_service::Bool
    from_active_power_mw::Float64
    to_active_power_mw::Float64
    from_reactive_power_mvar::Float64
    to_reactive_power_mvar::Float64
    from_voltage_pu::Float64
    to_voltage_pu::Float64
    minimum_active_power_mw::Float64
    maximum_active_power_mw::Float64
    minimum_from_reactive_power_mvar::Float64
    maximum_from_reactive_power_mvar::Float64
    minimum_to_reactive_power_mvar::Float64
    maximum_to_reactive_power_mvar::Float64
    constant_loss_mw::Float64
    proportional_loss::Float64
    resistance_ohm::Union{Float64,Nothing}
    nominal_voltage_kv::Union{Float64,Nothing}
    converters_mode::Union{String,Nothing}
    converter1::Union{HvdcConverter,Nothing}
    converter2::Union{HvdcConverter,Nothing}
    cost::Union{GeneratorCost,Nothing}
end

"""
    TransformerWinding

One winding of a three winding transformer.
"""
struct TransformerWinding
    bus_id::Int
    tap_ratio::Float64
    phase_shift_degrees::Float64
    nominal_voltage_kv::Float64
    rating_a_mva::Float64
    rating_b_mva::Float64
    rating_c_mva::Float64
    control::Union{TransformerControl,Nothing}
end

"""
    TransformerImpedance(resistance_pu, reactance_pu, base_mva)

One pairwise impedance of a three winding transformer.
"""
struct TransformerImpedance
    resistance_pu::Float64
    reactance_pu::Float64
    base_mva::Float64
end

"""
    ThreeWindingTransformer

One balanced three winding transformer: its `windings`, pairwise
`impedances`, star point voltage, magnetizing branch, and service status.
"""
struct ThreeWindingTransformer
    component_id::Union{String,Nothing}
    name::Union{String,Nothing}
    windings::Vector{TransformerWinding}
    impedances::Vector{TransformerImpedance}
    star_voltage_magnitude_pu::Float64
    star_voltage_angle_degrees::Float64
    magnetizing_conductance_pu::Float64
    magnetizing_susceptance_pu::Float64
    in_service::Bool
end

"""
    Area

One balanced control area.
"""
struct Area
    number::Int
    slack_bus_id::Union{Int,Nothing}
    net_interchange_mw::Float64
    tolerance_mw::Float64
    name::Union{String,Nothing}
    component_id::Union{String,Nothing}
    area_type::Union{String,Nothing}
end

"""
    DetailedConnectivity

Source neutral detailed connectivity retained from node breaker formats such
as XIIDM and CGMES. `dc.counts` is a `NamedTuple` of table lengths. The typed
tables are not bound in this release.
"""
struct DetailedConnectivity
    handle::DetailedConnectivityHandle
end

function Base.getproperty(dc::DetailedConnectivity, name::Symbol)
    name === :counts || return getfield(dc, name)
    h = getfield(dc, :handle)
    lib = getfield(h, :lib)
    v = GC.@preserve h _fill(PioDetailedConnectivityCountsView, lib) do out, err
        ccall(_library_symbol(lib, :pio_detailed_connectivity_counts), Bool,
              (Ptr{Cvoid}, Ref{PioDetailedConnectivityCountsView}, Ref{Ptr{Cvoid}}), _ptr(h), out, err)
    end
    names = fieldnames(PioDetailedConnectivityCountsView)
    return NamedTuple{names}(map(f -> Int(getfield(v, f)), names))
end

Base.propertynames(::DetailedConnectivity, private::Bool=false) = private ? (:counts, :handle) : (:counts,)

# --- element collections ----------------------------------------------------

"""
    Elements{T} <: AbstractVector{T}

The elements of one network table. `length`, 1-based indexing, iteration,
`filter`, `collect`, and broadcasting all work; each index fills one C view and
converts it to an immutable element struct.
"""
struct Elements{T,N} <: AbstractVector{T}
    network::N
    count::Int
end

Base.size(v::Elements) = (v.count,)
Base.IndexStyle(::Type{<:Elements}) = IndexLinear()
function Base.getindex(v::Elements{T}, i::Int) where {T}
    @boundscheck checkbounds(v, i)
    return _element(T, v.network, i - 1)
end
Base.summary(io::IO, v::Elements{T}) where {T} = print(io, length(v), "-element Elements{", T, "}")

# One typed view fill. `sym` names the `_at` entry point, `p` the network
# pointer, and the indices are zero based.
function _at(::Type{V}, sym::Symbol, lib, p::Ptr{Cvoid}, i::Integer) where {V}
    return _fill(V, lib) do out, err
        ccall(_library_symbol(lib, sym), Bool,
              (Ptr{Cvoid}, Csize_t, Ref{V}, Ref{Ptr{Cvoid}}), p, Csize_t(i), out, err)
    end
end
function _at(::Type{V}, sym::Symbol, lib, p::Ptr{Cvoid}, i::Integer, j::Integer) where {V}
    return _fill(V, lib) do out, err
        ccall(_library_symbol(lib, sym), Bool,
              (Ptr{Cvoid}, Csize_t, Csize_t, Ref{V}, Ref{Ptr{Cvoid}}), p, Csize_t(i), Csize_t(j), out, err)
    end
end
function _at(::Type{V}, sym::Symbol, lib, p::Ptr{Cvoid}, i::Integer, j::Integer, k::Integer) where {V}
    return _fill(V, lib) do out, err
        ccall(_library_symbol(lib, sym), Bool,
              (Ptr{Cvoid}, Csize_t, Csize_t, Csize_t, Ref{V}, Ref{Ptr{Cvoid}}),
              p, Csize_t(i), Csize_t(j), Csize_t(k), out, err)
    end
end

_count(sym::Symbol, lib, p::Ptr{Cvoid}) =
    Int(ccall(_library_symbol(lib, sym), Csize_t, (Ptr{Cvoid},), p))

# --- BalancedNetwork properties ----------------------------------------------

const _BALANCED_TABLES = (
    buses = (Bus, :pio_balanced_network_bus_count),
    branches = (Branch, :pio_balanced_network_branch_count),
    generators = (Generator, :pio_balanced_network_generator_count),
    loads = (Load, :pio_balanced_network_load_count),
    shunts = (Shunt, :pio_balanced_network_shunt_count),
    static_var_compensators = (StaticVarCompensator, :pio_balanced_network_static_var_compensator_count),
    storage = (Storage, :pio_balanced_network_storage_count),
    switches = (Switch, :pio_balanced_network_switch_count),
    hvdc = (Hvdc, :pio_balanced_network_hvdc_count),
    transformers_3w = (ThreeWindingTransformer, :pio_balanced_network_three_winding_transformer_count),
    areas = (Area, :pio_balanced_network_area_count),
)

const _BALANCED_SCALARS = (:name, :base_mva, :base_frequency, :geo, :detailed_connectivity)

function Base.getproperty(net::BalancedNetwork, name::Symbol)
    h = getfield(net, :handle)
    lib = getfield(h, :lib)
    if haskey(_BALANCED_TABLES, name)
        T, count_sym = _BALANCED_TABLES[name]
        n = GC.@preserve h _count(count_sym, lib, _ptr(h))
        return Elements{T,BalancedNetwork}(net, n)
    elseif name === :name
        return GC.@preserve h _str(ccall(_library_symbol(lib, :pio_balanced_network_name), PioStringView,
                                         (Ptr{Cvoid},), _ptr(h)))
    elseif name === :base_mva
        return GC.@preserve h ccall(_library_symbol(lib, :pio_balanced_network_base_mva), Float64,
                                    (Ptr{Cvoid},), _ptr(h))
    elseif name === :base_frequency
        return GC.@preserve h ccall(_library_symbol(lib, :pio_balanced_network_base_frequency_hz), Float64,
                                    (Ptr{Cvoid},), _ptr(h))
    elseif name === :geo
        v = GC.@preserve h _fill(PioBalancedGeoView, lib) do out, err
            ccall(_library_symbol(lib, :pio_balanced_network_geo), Bool,
                  (Ptr{Cvoid}, Ref{PioBalancedGeoView}, Ref{Ptr{Cvoid}}), _ptr(h), out, err)
        end
        return _geo(v)
    elseif name === :detailed_connectivity
        return GC.@preserve h begin
            has = ccall(_library_symbol(lib, :pio_balanced_network_has_detailed_connectivity), Bool,
                        (Ptr{Cvoid},), _ptr(h))
            has || return nothing
            ptr = ccall(_library_symbol(lib, :pio_balanced_network_detailed_connectivity), Ptr{Cvoid},
                        (Ptr{Cvoid},), _ptr(h))
            ptr == C_NULL ? nothing : DetailedConnectivity(DetailedConnectivityHandle(ptr, lib))
        end
    end
    return getfield(net, name)
end

Base.propertynames(::BalancedNetwork, private::Bool=false) =
    private ? (_BALANCED_SCALARS..., keys(_BALANCED_TABLES)..., :handle, :owner) :
              (_BALANCED_SCALARS..., keys(_BALANCED_TABLES)...)

_lib_of(net::BalancedNetwork) = getfield(getfield(net, :handle), :lib)

# --- element conversions -----------------------------------------------------

# Run `f(lib, p)` with the network pointer preserved for the duration.
function _with_network(f, net::BalancedNetwork)
    h = getfield(net, :handle)
    return GC.@preserve h f(getfield(h, :lib), _ptr(h))
end

_element(::Type{Bus}, net::BalancedNetwork, i) = _with_network(net) do lib, p
    v = _at(PioBalancedBusView, :pio_balanced_network_bus_at, lib, p, i)
    Bus(Int(v.id), _optional_str(v.component_id, v.has_component_id), _str(v.bus_type),
        v.vm_pu, v.va_degrees, v.base_kv, v.vmax_pu, v.vmin_pu,
        _optional(v.emergency_vmax_pu, v.has_emergency_voltage_limits),
        _optional(v.emergency_vmin_pu, v.has_emergency_voltage_limits),
        Int(v.area), Int(v.zone), _optional_str(v.name, v.has_name),
        _location(v.location, v.has_location))
end

_element(::Type{Load}, net::BalancedNetwork, i) = _with_network(net) do lib, p
    v = _at(PioBalancedLoadView, :pio_balanced_network_load_at, lib, p, i)
    m = v.voltage_model
    model = LoadVoltageModel(_str(m.kind), m.p_constant_power_mw, m.q_constant_power_mvar,
                             m.p_constant_current_mw, m.q_constant_current_mvar,
                             m.p_constant_impedance_mw, m.q_constant_impedance_mvar,
                             m.exponential_p_mw, m.exponential_q_mvar, m.gamma_p, m.gamma_q,
                             _optional(m.nominal_voltage_pu, m.has_nominal_voltage),
                             _optional(Int(m.load_type), m.has_load_type),
                             _optional(m.scaling, m.has_scaling))
    Load(_optional_str(v.component_id, v.has_component_id), Int(v.bus_id), v.p_mw, v.q_mvar,
         v.in_service, model)
end

_element(::Type{Shunt}, net::BalancedNetwork, i) = _with_network(net) do lib, p
    v = _at(PioBalancedShuntView, :pio_balanced_network_shunt_at, lib, p, i)
    control = if v.has_control
        blocks = map(0:Int(v.control_block_count)-1) do j
            b = _at(PioShuntBlockView, :pio_balanced_network_shunt_block_at, lib, p, i, j)
            ShuntBlock(Int(b.steps), b.conductance_mw, b.susceptance_mvar)
        end
        ShuntControl(_str(v.control_mode), v.control_vmax_pu, v.control_vmin_pu,
                     _optional(Int(v.control_bus_id), v.has_control_bus),
                     v.control_reactive_range_percent, blocks)
    else
        nothing
    end
    Shunt(_optional_str(v.component_id, v.has_component_id), Int(v.bus_id),
          v.conductance_mw, v.susceptance_mvar, v.in_service,
          _optional(Int(v.section_count), v.has_section_count), control)
end

_element(::Type{StaticVarCompensator}, net::BalancedNetwork, i) = _with_network(net) do lib, p
    v = _at(PioBalancedStaticVarCompensatorView, :pio_balanced_network_static_var_compensator_at, lib, p, i)
    StaticVarCompensator(_optional_str(v.component_id, v.has_component_id), Int(v.bus_id),
                         v.minimum_susceptance_siemens, v.maximum_susceptance_siemens,
                         v.voltage_setpoint_kv, v.reactive_power_setpoint_mvar,
                         _str(v.regulation_mode), v.regulating,
                         _terminal_reference(v.regulating_terminal, v.has_regulating_terminal),
                         v.active_power_mw, v.reactive_power_mvar, v.in_service)
end

_element(::Type{Branch}, net::BalancedNetwork, i) = _with_network(net) do lib, p
    v = _at(PioBalancedBranchView, :pio_balanced_network_branch_at, lib, p, i)
    ratings = map(0:Int(v.additional_rating_count)-1) do j
        r = _at(PioBranchRatingView, :pio_balanced_network_branch_rating_at, lib, p, i, j)
        BranchRating(_str(r.name), r.rate_mva)
    end
    route = if v.has_route
        map(0:Int(v.route_point_count)-1) do j
            pt = _at(PioBalancedLocationView, :pio_balanced_network_branch_route_point_at, lib, p, i, j)
            Location(pt.x, pt.y, _optional_str(pt.kind, pt.has_kind))
        end
    else
        nothing
    end
    Branch(_optional_str(v.component_id, v.has_component_id), _optional_str(v.name, v.has_name),
           Int(v.from_bus_id), Int(v.to_bus_id), v.resistance_pu, v.reactance_pu,
           v.total_charging_susceptance_pu, v.terminal_charging_is_explicit,
           v.from_conductance_pu, v.from_susceptance_pu, v.to_conductance_pu, v.to_susceptance_pu,
           v.rate_a_mva, v.rate_b_mva, v.rate_c_mva, ratings,
           _optional((v.current_rating_a, v.current_rating_b, v.current_rating_c), v.has_current_ratings),
           v.tap_ratio, v.effective_tap_ratio, v.phase_shift_degrees, v.in_service,
           v.angle_min_degrees, v.angle_max_degrees,
           _transformer_control(v.control, v.has_control), route)
end

_element(::Type{Generator}, net::BalancedNetwork, i) = _with_network(net) do lib, p
    v = _at(PioBalancedGeneratorView, :pio_balanced_network_generator_at, lib, p, i)
    capabilities = map(0:Int(v.capability_count)-1) do j
        c = _at(PioGeneratorCapabilityView, :pio_balanced_network_generator_capability_at, lib, p, i, j)
        GeneratorCapability(_str(c.name), _optional(c.value, c.has_value))
    end
    Generator(_optional_str(v.component_id, v.has_component_id), Int(v.bus_id), _str(v.energy_source),
              v.active_power_mw, v.reactive_power_mvar, v.active_power_max_mw, v.active_power_min_mw,
              v.reactive_power_max_mvar, v.reactive_power_min_mvar, v.voltage_setpoint_pu,
              v.machine_base_mva, v.in_service, _generator_cost(v.cost, v.has_cost),
              _optional(Int(v.regulated_bus_id), v.has_regulated_bus), capabilities,
              _active_power_control(v.active_power_control, v.has_active_power_control),
              v.voltage_regulation_on,
              _terminal_reference(v.regulating_terminal, v.has_regulating_terminal))
end

_element(::Type{Storage}, net::BalancedNetwork, i) = _with_network(net) do lib, p
    v = _at(PioBalancedStorageView, :pio_balanced_network_storage_at, lib, p, i)
    Storage(_optional_str(v.component_id, v.has_component_id), Int(v.bus_id),
            v.active_power_mw, v.reactive_power_mvar, v.energy_mwh, v.energy_rating_mwh,
            v.charge_rating_mw, v.discharge_rating_mw, v.charge_efficiency, v.discharge_efficiency,
            v.thermal_rating_mva, _optional(v.current_rating, v.has_current_rating),
            v.reactive_power_min_mvar, v.reactive_power_max_mvar, v.resistance_pu, v.reactance_pu,
            v.active_power_loss_mw, v.reactive_power_loss_mvar, v.in_service,
            _active_power_control(v.active_power_control, v.has_active_power_control))
end

_element(::Type{Switch}, net::BalancedNetwork, i) = _with_network(net) do lib, p
    v = _at(PioBalancedSwitchView, :pio_balanced_network_switch_at, lib, p, i)
    Switch(_optional_str(v.component_id, v.has_component_id), Int(v.from_bus_id), Int(v.to_bus_id),
           v.closed, _optional(v.thermal_rating_mva, v.has_thermal_rating),
           _optional(v.current_rating_a, v.has_current_rating),
           _optional(v.from_active_power_mw, v.has_from_active_power),
           _optional(v.from_reactive_power_mvar, v.has_from_reactive_power),
           _optional(v.to_active_power_mw, v.has_to_active_power),
           _optional(v.to_reactive_power_mvar, v.has_to_reactive_power))
end

_element(::Type{Hvdc}, net::BalancedNetwork, i) = _with_network(net) do lib, p
    v = _at(PioBalancedHvdcView, :pio_balanced_network_hvdc_at, lib, p, i)
    Hvdc(_optional_str(v.component_id, v.has_component_id), Int(v.from_bus_id), Int(v.to_bus_id),
         v.in_service, v.from_active_power_mw, v.to_active_power_mw,
         v.from_reactive_power_mvar, v.to_reactive_power_mvar, v.from_voltage_pu, v.to_voltage_pu,
         v.minimum_active_power_mw, v.maximum_active_power_mw,
         v.minimum_from_reactive_power_mvar, v.maximum_from_reactive_power_mvar,
         v.minimum_to_reactive_power_mvar, v.maximum_to_reactive_power_mvar,
         v.constant_loss_mw, v.proportional_loss,
         _optional(v.resistance_ohm, v.has_resistance),
         _optional(v.nominal_voltage_kv, v.has_nominal_voltage),
         _optional_str(v.converters_mode, v.has_converters_mode),
         _hvdc_converter(v.converter1, v.has_converter1),
         _hvdc_converter(v.converter2, v.has_converter2),
         _generator_cost(v.cost, v.has_cost))
end

_element(::Type{ThreeWindingTransformer}, net::BalancedNetwork, i) = _with_network(net) do lib, p
    v = _at(PioBalancedThreeWindingTransformerView, :pio_balanced_network_three_winding_transformer_at, lib, p, i)
    windings = map(0:Int(v.winding_count)-1) do j
        w = _at(PioThreeWindingTransformerWindingView,
                :pio_balanced_network_three_winding_transformer_winding_at, lib, p, i, j)
        TransformerWinding(Int(w.bus_id), w.tap_ratio, w.phase_shift_degrees, w.nominal_voltage_kv,
                           w.rating_a_mva, w.rating_b_mva, w.rating_c_mva,
                           _transformer_control(w.control, w.has_control))
    end
    impedances = map(0:Int(v.impedance_count)-1) do j
        z = _at(PioThreeWindingTransformerImpedanceView,
                :pio_balanced_network_three_winding_transformer_impedance_at, lib, p, i, j)
        TransformerImpedance(z.resistance_pu, z.reactance_pu, z.base_mva)
    end
    ThreeWindingTransformer(_optional_str(v.component_id, v.has_component_id),
                            _optional_str(v.name, v.has_name), windings, impedances,
                            v.star_voltage_magnitude_pu, v.star_voltage_angle_degrees,
                            v.magnetizing_conductance_pu, v.magnetizing_susceptance_pu, v.in_service)
end

_element(::Type{Area}, net::BalancedNetwork, i) = _with_network(net) do lib, p
    v = _at(PioBalancedAreaView, :pio_balanced_network_area_at, lib, p, i)
    Area(Int(v.number), _optional(Int(v.slack_bus_id), v.has_slack_bus), v.net_interchange_mw,
         v.tolerance_mw, _optional_str(v.name, v.has_name),
         _optional_str(v.component_id, v.has_component_id),
         _optional_str(v.area_type, v.has_area_type))
end

"""
    reference_bus_ids(net::BalancedNetwork) -> Vector{Int}

The ids of the buses whose type is `"REF"`, in table order.
"""
reference_bus_ids(net::BalancedNetwork) = [b.id for b in net.buses if b.bus_type == "REF"]
