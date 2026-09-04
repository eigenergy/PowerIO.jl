# `MulticonductorNetwork`: properties over the network handle and the
# conductor level element structs. Terminal names, per conductor vectors, and
# impedance matrices are copied out of the borrowed spans.

"""
    MulticonductorBus

One multiconductor bus: its `id`, `terminals`, `grounded_terminals`, and the
voltage limits the source states (volts; per terminal vectors for the phase
limits).
"""
struct MulticonductorBus
    id::String
    terminals::Vector{String}
    grounded_terminals::Vector{String}
    voltage_min_v::Union{Float64,Nothing}
    voltage_max_v::Union{Float64,Nothing}
    phase_to_neutral_voltage_min_v::Union{Vector{Float64},Nothing}
    phase_to_neutral_voltage_max_v::Union{Vector{Float64},Nothing}
    phase_to_phase_voltage_min_v::Union{Vector{Float64},Nothing}
    phase_to_phase_voltage_max_v::Union{Vector{Float64},Nothing}
    positive_sequence_voltage_min_v::Union{Float64,Nothing}
    positive_sequence_voltage_max_v::Union{Float64,Nothing}
    negative_sequence_voltage_max_v::Union{Float64,Nothing}
    zero_sequence_voltage_max_v::Union{Float64,Nothing}
    neutral_to_ground_voltage_max_v::Union{Float64,Nothing}
    location::Union{Location,Nothing}
end

"""
    MulticonductorLineCode

Per length impedance of a line: the `resistance`, `reactance`, and terminal
`conductance_from`, `susceptance_from`, `conductance_to`, `susceptance_to`
matrices (ohm per metre and siemens per metre, `conductor_count` square), the
per conductor limits, and the `source` the code came from.
"""
struct MulticonductorLineCode
    name::String
    conductor_count::Int
    resistance::Matrix{Float64}
    reactance::Matrix{Float64}
    conductance_from::Matrix{Float64}
    susceptance_from::Matrix{Float64}
    conductance_to::Matrix{Float64}
    susceptance_to::Matrix{Float64}
    current_limit_a::Union{Vector{Float64},Nothing}
    apparent_power_limit_va::Union{Vector{Float64},Nothing}
    source::Union{String,Nothing}
end

"""
    MulticonductorLine

One line from `bus_from` to `bus_to` with its terminal maps, `line_code`,
`length_m`, optional `route`, and per conductor limits.
"""
struct MulticonductorLine
    name::String
    bus_from::String
    bus_to::String
    terminals_from::Vector{String}
    terminals_to::Vector{String}
    line_code::String
    length_m::Float64
    route::Union{Vector{Location},Nothing}
    current_limit_a::Union{Vector{Float64},Nothing}
    apparent_power_limit_va::Union{Vector{Float64},Nothing}
end

"""
    MulticonductorSwitch

One switch between `bus_from` and `bus_to`; `open` is its state.
"""
struct MulticonductorSwitch
    name::String
    bus_from::String
    bus_to::String
    terminals_from::Vector{String}
    terminals_to::Vector{String}
    open::Bool
    current_limit_a::Union{Vector{Float64},Nothing}
end

"""
    MulticonductorTransformerWinding

One winding: its `bus`, `terminals`, `connection` (wye or delta), ratings,
`resistance_percent`, `tap`, and neutral impedance when grounded through one.
"""
struct MulticonductorTransformerWinding
    bus::String
    terminals::Vector{String}
    connection::String
    rated_voltage_v::Float64
    apparent_power_rating_va::Float64
    resistance_percent::Float64
    tap::Float64
    neutral_resistance_ohm::Union{Float64,Nothing}
    neutral_reactance_ohm::Union{Float64,Nothing}
end

"""
    MulticonductorTransformer

One transformer: its `windings`, the pairwise `short_circuit_reactance_percent`
values, and `phase_count`.
"""
struct MulticonductorTransformer
    name::String
    windings::Vector{MulticonductorTransformerWinding}
    short_circuit_reactance_percent::Vector{Float64}
    phase_count::Int
end

"""
    MulticonductorLoad

One load: `configuration`, per terminal nominal powers, the `voltage_model`
name, and the per terminal ZIP and exponential coefficients.
"""
struct MulticonductorLoad
    name::String
    bus::String
    terminals::Vector{String}
    configuration::String
    active_power_nominal_w::Vector{Float64}
    reactive_power_nominal_var::Vector{Float64}
    voltage_model::String
    nominal_voltage_v::Vector{Float64}
    active_power_constant_impedance::Vector{Float64}
    active_power_constant_current::Vector{Float64}
    active_power_constant_power::Vector{Float64}
    reactive_power_constant_impedance::Vector{Float64}
    reactive_power_constant_current::Vector{Float64}
    reactive_power_constant_power::Vector{Float64}
    active_power_exponent::Vector{Float64}
    reactive_power_exponent::Vector{Float64}
end

"""
    MulticonductorGenerator

One generator with per terminal nominal powers, optional limits, dispatch
cost, and apparent power and current limits.
"""
struct MulticonductorGenerator
    name::String
    bus::String
    terminals::Vector{String}
    configuration::String
    active_power_nominal_w::Vector{Float64}
    reactive_power_nominal_var::Vector{Float64}
    active_power_min_w::Union{Vector{Float64},Nothing}
    active_power_max_w::Union{Vector{Float64},Nothing}
    reactive_power_min_var::Union{Vector{Float64},Nothing}
    reactive_power_max_var::Union{Vector{Float64},Nothing}
    active_power_dispatch_cost_per_kwh::Union{Vector{Float64},Nothing}
    apparent_power_limit_va::Union{Vector{Float64},Nothing}
    current_limit_a::Union{Vector{Float64},Nothing}
end

"""
    InverterBasedResource

One inverter based resource: `topology`, `prime_mover`, limits, available
active power, and the `control_profile` it follows.
"""
struct InverterBasedResource
    name::String
    bus::String
    terminals::Vector{String}
    topology::String
    prime_mover::String
    apparent_power_limit_va::Vector{Float64}
    current_limit_a::Union{Vector{Float64},Nothing}
    active_power_available_w::Union{Float64,Nothing}
    active_power_min_w::Union{Vector{Float64},Nothing}
    active_power_max_w::Union{Vector{Float64},Nothing}
    reactive_power_min_var::Union{Vector{Float64},Nothing}
    reactive_power_max_var::Union{Vector{Float64},Nothing}
    control_profile::Union{String,Nothing}
    voltage_aggregation::Union{String,Nothing}
end

"""
    VoltVarControl

Volt-var curve of a control profile.
"""
struct VoltVarControl
    voltage_reference::Union{String,Nothing}
    breakpoints::Vector{Float64}
    reactive_power_limits::Vector{Float64}
    reactive_power_unit::Union{String,Nothing}
    reactive_power_reference::Union{String,Nothing}
    active_power_min_for_reactive_power_w::Union{Float64,Nothing}
    active_power_min_for_max_reactive_power_w::Union{Float64,Nothing}
end

"""
    VoltWattControl

Volt-watt curve of a control profile.
"""
struct VoltWattControl
    voltage_reference::Union{String,Nothing}
    breakpoints::Vector{Float64}
    active_power_limits::Vector{Float64}
    active_power_unit::Union{String,Nothing}
    active_power_reference::Union{String,Nothing}
end

"""
    ControlProfile

One inverter control profile: a fixed `power_factor`, a `volt_var` curve, a
`volt_watt` curve, or a combination.
"""
struct ControlProfile
    name::String
    power_factor::Union{Float64,Nothing}
    volt_var::Union{VoltVarControl,Nothing}
    volt_watt::Union{VoltWattControl,Nothing}
end

"""
    MulticonductorShunt

One shunt with its `conductance` and `susceptance` matrices (siemens).
"""
struct MulticonductorShunt
    name::String
    bus::String
    terminals::Vector{String}
    conductance::Matrix{Float64}
    susceptance::Matrix{Float64}
end

"""
    MulticonductorCapacitor

One rated capacitor bank.
"""
struct MulticonductorCapacitor
    name::String
    bus::String
    terminals::Vector{String}
    configuration::String
    rated_reactive_power_var::Float64
    nominal_voltage_v::Float64
end

"""
    VoltageSource

One ideal voltage source with per terminal magnitude (volts) and angle
(radians).
"""
struct VoltageSource
    name::String
    bus::String
    terminals::Vector{String}
    voltage_magnitude_v::Vector{Float64}
    voltage_angle_rad::Vector{Float64}
end

"""
    UntypedObject

One source object retained without a typed PowerIO representation: its
`class_name`, `name`, and `properties` as `name => value` pairs (a positional
property has `nothing` as its name).
"""
struct UntypedObject
    class_name::String
    name::String
    properties::Vector{Pair{Union{String,Nothing},String}}
end

"""
    SourceCommand(verb, args)

One retained source command, such as an OpenDSS `solve` line.
"""
struct SourceCommand
    verb::String
    args::String
end

# --- properties ---------------------------------------------------------------

const _MC_TABLES = (
    buses = (MulticonductorBus, :buses),
    line_codes = (MulticonductorLineCode, :line_codes),
    lines = (MulticonductorLine, :lines),
    switches = (MulticonductorSwitch, :switches),
    transformers = (MulticonductorTransformer, :transformers),
    loads = (MulticonductorLoad, :loads),
    generators = (MulticonductorGenerator, :generators),
    ibrs = (InverterBasedResource, :inverter_based_resources),
    control_profiles = (ControlProfile, :control_profiles),
    shunts = (MulticonductorShunt, :shunts),
    capacitors = (MulticonductorCapacitor, :capacitors),
    voltage_sources = (VoltageSource, :voltage_sources),
    untyped_objects = (UntypedObject, :untyped_objects),
    commands = (SourceCommand, :commands),
    options = (Pair{String,String}, :options),
)

const _MC_SCALARS = (:name, :base_frequency, :source_format, :geo)

function _mc_counts(net::MulticonductorNetwork)
    h = getfield(net, :handle)
    lib = getfield(h, :lib)
    return GC.@preserve h _fill(PioMulticonductorNetworkCountsView, lib) do out, err
        ccall(_library_symbol(lib, :pio_multiconductor_network_counts), Bool,
              (Ptr{Cvoid}, Ref{PioMulticonductorNetworkCountsView}, Ref{Ptr{Cvoid}}), _ptr(h), out, err)
    end
end

function Base.getproperty(net::MulticonductorNetwork, name::Symbol)
    h = getfield(net, :handle)
    lib = getfield(h, :lib)
    if haskey(_MC_TABLES, name)
        T, field = _MC_TABLES[name]
        return Elements{T,MulticonductorNetwork}(net, Int(getfield(_mc_counts(net), field)))
    elseif name === :name
        return GC.@preserve h begin
            has = ccall(_library_symbol(lib, :pio_multiconductor_network_has_name), Bool, (Ptr{Cvoid},), _ptr(h))
            has ? _str(ccall(_library_symbol(lib, :pio_multiconductor_network_name), PioStringView,
                             (Ptr{Cvoid},), _ptr(h))) : nothing
        end
    elseif name === :source_format
        return GC.@preserve h begin
            has = ccall(_library_symbol(lib, :pio_multiconductor_network_has_source_format), Bool,
                        (Ptr{Cvoid},), _ptr(h))
            has ? _str(ccall(_library_symbol(lib, :pio_multiconductor_network_source_format), PioStringView,
                             (Ptr{Cvoid},), _ptr(h))) : nothing
        end
    elseif name === :base_frequency
        return GC.@preserve h ccall(_library_symbol(lib, :pio_multiconductor_network_base_frequency_hz), Float64,
                                    (Ptr{Cvoid},), _ptr(h))
    elseif name === :geo
        v = GC.@preserve h _fill(PioMulticonductorGeoView, lib) do out, err
            ccall(_library_symbol(lib, :pio_multiconductor_network_geo), Bool,
                  (Ptr{Cvoid}, Ref{PioMulticonductorGeoView}, Ref{Ptr{Cvoid}}), _ptr(h), out, err)
        end
        return _geo(v)
    end
    return getfield(net, name)
end

Base.propertynames(::MulticonductorNetwork, private::Bool=false) =
    private ? (_MC_SCALARS..., keys(_MC_TABLES)..., :handle, :owner) :
              (_MC_SCALARS..., keys(_MC_TABLES)...)

_lib_of(net::MulticonductorNetwork) = getfield(getfield(net, :handle), :lib)

function _with_network(f, net::MulticonductorNetwork)
    h = getfield(net, :handle)
    return GC.@preserve h f(getfield(h, :lib), _ptr(h))
end

# `count` terminal names through a two index string fill.
function _terminals(sym::Symbol, lib, p, i, count)
    return map(0:Int(count)-1) do j
        _str(_at(PioStringView, sym, lib, p, i, j))
    end
end

# Terminal names of one transformer winding (three index fill).
function _winding_terminals(lib, p, i, j, count)
    return map(0:Int(count)-1) do k
        _str(_at(PioStringView, :pio_multiconductor_network_transformer_winding_terminal_at, lib, p, i, j, k))
    end
end

# Assemble a matrix from `rows` row spans read through `sym`.
function _matrix(sym::Symbol, lib, p, i, rows)
    rows = Int(rows)
    rows == 0 && return Matrix{Float64}(undef, 0, 0)
    first_row = _f64s(_at(PioF64View, sym, lib, p, i, 0))
    out = Matrix{Float64}(undef, rows, length(first_row))
    out[1, :] = first_row
    for r in 2:rows
        out[r, :] = _f64s(_at(PioF64View, sym, lib, p, i, r - 1))
    end
    return out
end

_element(::Type{MulticonductorBus}, net::MulticonductorNetwork, i) = _with_network(net) do lib, p
    v = _at(PioMulticonductorBusView, :pio_multiconductor_network_bus_at, lib, p, i)
    MulticonductorBus(_str(v.id),
                      _terminals(:pio_multiconductor_network_bus_terminal_at, lib, p, i, v.terminal_count),
                      _terminals(:pio_multiconductor_network_bus_grounded_terminal_at, lib, p, i, v.grounded_terminal_count),
                      _optional(v.voltage_min_v, v.has_voltage_min),
                      _optional(v.voltage_max_v, v.has_voltage_max),
                      _optional_f64s(v.phase_to_neutral_voltage_min_v, v.has_phase_to_neutral_voltage_min),
                      _optional_f64s(v.phase_to_neutral_voltage_max_v, v.has_phase_to_neutral_voltage_max),
                      _optional_f64s(v.phase_to_phase_voltage_min_v, v.has_phase_to_phase_voltage_min),
                      _optional_f64s(v.phase_to_phase_voltage_max_v, v.has_phase_to_phase_voltage_max),
                      _optional(v.positive_sequence_voltage_min_v, v.has_positive_sequence_voltage_min),
                      _optional(v.positive_sequence_voltage_max_v, v.has_positive_sequence_voltage_max),
                      _optional(v.negative_sequence_voltage_max_v, v.has_negative_sequence_voltage_max),
                      _optional(v.zero_sequence_voltage_max_v, v.has_zero_sequence_voltage_max),
                      _optional(v.neutral_to_ground_voltage_max_v, v.has_neutral_to_ground_voltage_max),
                      _location(v.location, v.has_location))
end

_element(::Type{MulticonductorLineCode}, net::MulticonductorNetwork, i) = _with_network(net) do lib, p
    v = _at(PioMulticonductorLineCodeView, :pio_multiconductor_network_line_code_at, lib, p, i)
    MulticonductorLineCode(_str(v.name), Int(v.conductor_count),
                           _matrix(:pio_multiconductor_network_line_code_resistance_matrix_row_at, lib, p, i, v.resistance_matrix_row_count),
                           _matrix(:pio_multiconductor_network_line_code_reactance_matrix_row_at, lib, p, i, v.reactance_matrix_row_count),
                           _matrix(:pio_multiconductor_network_line_code_conductance_from_matrix_row_at, lib, p, i, v.conductance_from_matrix_row_count),
                           _matrix(:pio_multiconductor_network_line_code_susceptance_from_matrix_row_at, lib, p, i, v.susceptance_from_matrix_row_count),
                           _matrix(:pio_multiconductor_network_line_code_conductance_to_matrix_row_at, lib, p, i, v.conductance_to_matrix_row_count),
                           _matrix(:pio_multiconductor_network_line_code_susceptance_to_matrix_row_at, lib, p, i, v.susceptance_to_matrix_row_count),
                           _optional_f64s(v.current_limit_a, v.has_current_limit),
                           _optional_f64s(v.apparent_power_limit_va, v.has_apparent_power_limit),
                           _optional_str(v.source, v.has_source))
end

_element(::Type{MulticonductorLine}, net::MulticonductorNetwork, i) = _with_network(net) do lib, p
    v = _at(PioMulticonductorLineView, :pio_multiconductor_network_line_at, lib, p, i)
    route = if v.has_route
        map(0:Int(v.route_point_count)-1) do j
            pt = _at(PioMulticonductorLocationView, :pio_multiconductor_network_line_route_point_at, lib, p, i, j)
            Location(pt.x, pt.y, _optional_str(pt.kind, pt.has_kind))
        end
    else
        nothing
    end
    MulticonductorLine(_str(v.name), _str(v.bus_from), _str(v.bus_to),
                       _terminals(:pio_multiconductor_network_line_terminal_from_at, lib, p, i, v.terminal_map_from_count),
                       _terminals(:pio_multiconductor_network_line_terminal_to_at, lib, p, i, v.terminal_map_to_count),
                       _str(v.line_code), v.length_m, route,
                       _optional_f64s(v.current_limit_a, v.has_current_limit),
                       _optional_f64s(v.apparent_power_limit_va, v.has_apparent_power_limit))
end

_element(::Type{MulticonductorSwitch}, net::MulticonductorNetwork, i) = _with_network(net) do lib, p
    v = _at(PioMulticonductorSwitchView, :pio_multiconductor_network_switch_at, lib, p, i)
    MulticonductorSwitch(_str(v.name), _str(v.bus_from), _str(v.bus_to),
                         _terminals(:pio_multiconductor_network_switch_terminal_from_at, lib, p, i, v.terminal_map_from_count),
                         _terminals(:pio_multiconductor_network_switch_terminal_to_at, lib, p, i, v.terminal_map_to_count),
                         v.open, _optional_f64s(v.current_limit_a, v.has_current_limit))
end

_element(::Type{MulticonductorTransformer}, net::MulticonductorNetwork, i) = _with_network(net) do lib, p
    v = _at(PioMulticonductorTransformerView, :pio_multiconductor_network_transformer_at, lib, p, i)
    windings = map(0:Int(v.winding_count)-1) do j
        w = _at(PioMulticonductorTransformerWindingView, :pio_multiconductor_network_transformer_winding_at, lib, p, i, j)
        MulticonductorTransformerWinding(_str(w.bus), _winding_terminals(lib, p, i, j, w.terminal_map_count),
                                         _str(w.connection), w.rated_voltage_v, w.apparent_power_rating_va,
                                         w.resistance_percent, w.tap,
                                         _optional(w.neutral_resistance_ohm, w.has_neutral_resistance),
                                         _optional(w.neutral_reactance_ohm, w.has_neutral_reactance))
    end
    MulticonductorTransformer(_str(v.name), windings, _f64s(v.short_circuit_reactance_percent), Int(v.phase_count))
end

_element(::Type{MulticonductorLoad}, net::MulticonductorNetwork, i) = _with_network(net) do lib, p
    v = _at(PioMulticonductorLoadView, :pio_multiconductor_network_load_at, lib, p, i)
    MulticonductorLoad(_str(v.name), _str(v.bus),
                       _terminals(:pio_multiconductor_network_load_terminal_at, lib, p, i, v.terminal_map_count),
                       _str(v.configuration), _f64s(v.active_power_nominal_w), _f64s(v.reactive_power_nominal_var),
                       _str(v.voltage_model), _f64s(v.nominal_voltage_v),
                       _f64s(v.active_power_constant_impedance), _f64s(v.active_power_constant_current),
                       _f64s(v.active_power_constant_power), _f64s(v.reactive_power_constant_impedance),
                       _f64s(v.reactive_power_constant_current), _f64s(v.reactive_power_constant_power),
                       _f64s(v.active_power_exponent), _f64s(v.reactive_power_exponent))
end

_element(::Type{MulticonductorGenerator}, net::MulticonductorNetwork, i) = _with_network(net) do lib, p
    v = _at(PioMulticonductorGeneratorView, :pio_multiconductor_network_generator_at, lib, p, i)
    MulticonductorGenerator(_str(v.name), _str(v.bus),
                            _terminals(:pio_multiconductor_network_generator_terminal_at, lib, p, i, v.terminal_map_count),
                            _str(v.configuration), _f64s(v.active_power_nominal_w), _f64s(v.reactive_power_nominal_var),
                            _optional_f64s(v.active_power_min_w, v.has_active_power_min),
                            _optional_f64s(v.active_power_max_w, v.has_active_power_max),
                            _optional_f64s(v.reactive_power_min_var, v.has_reactive_power_min),
                            _optional_f64s(v.reactive_power_max_var, v.has_reactive_power_max),
                            _optional_f64s(v.active_power_dispatch_cost_per_kwh, v.has_active_power_dispatch_cost),
                            _optional_f64s(v.apparent_power_limit_va, v.has_apparent_power_limit),
                            _optional_f64s(v.current_limit_a, v.has_current_limit))
end

_element(::Type{InverterBasedResource}, net::MulticonductorNetwork, i) = _with_network(net) do lib, p
    v = _at(PioInverterBasedResourceView, :pio_multiconductor_network_inverter_based_resource_at, lib, p, i)
    InverterBasedResource(_str(v.name), _str(v.bus),
                          _terminals(:pio_multiconductor_network_inverter_based_resource_terminal_at, lib, p, i, v.terminal_map_count),
                          _str(v.topology), _str(v.prime_mover), _f64s(v.apparent_power_limit_va),
                          _optional_f64s(v.current_limit_a, v.has_current_limit),
                          _optional(v.active_power_available_w, v.has_active_power_available),
                          _optional_f64s(v.active_power_min_w, v.has_active_power_min),
                          _optional_f64s(v.active_power_max_w, v.has_active_power_max),
                          _optional_f64s(v.reactive_power_min_var, v.has_reactive_power_min),
                          _optional_f64s(v.reactive_power_max_var, v.has_reactive_power_max),
                          _optional_str(v.control_profile, v.has_control_profile),
                          _optional_str(v.voltage_aggregation, v.has_voltage_aggregation))
end

_element(::Type{ControlProfile}, net::MulticonductorNetwork, i) = _with_network(net) do lib, p
    v = _at(PioControlProfileView, :pio_multiconductor_network_control_profile_at, lib, p, i)
    volt_var = v.has_volt_var ? VoltVarControl(
        _optional_str(v.volt_var_voltage_reference, v.has_volt_var_voltage_reference),
        _f64s(v.volt_var_breakpoints), _f64s(v.volt_var_reactive_power_limits),
        _optional_str(v.volt_var_reactive_power_unit, v.has_volt_var_reactive_power_unit),
        _optional_str(v.volt_var_reactive_power_reference, v.has_volt_var_reactive_power_reference),
        _optional(v.volt_var_active_power_min_for_reactive_power_w, v.has_volt_var_active_power_min_for_reactive_power),
        _optional(v.volt_var_active_power_min_for_max_reactive_power_w, v.has_volt_var_active_power_min_for_max_reactive_power)) : nothing
    volt_watt = v.has_volt_watt ? VoltWattControl(
        _optional_str(v.volt_watt_voltage_reference, v.has_volt_watt_voltage_reference),
        _f64s(v.volt_watt_breakpoints), _f64s(v.volt_watt_active_power_limits),
        _optional_str(v.volt_watt_active_power_unit, v.has_volt_watt_active_power_unit),
        _optional_str(v.volt_watt_active_power_reference, v.has_volt_watt_active_power_reference)) : nothing
    ControlProfile(_str(v.name), _optional(v.power_factor, v.has_power_factor), volt_var, volt_watt)
end

_element(::Type{MulticonductorShunt}, net::MulticonductorNetwork, i) = _with_network(net) do lib, p
    v = _at(PioMulticonductorShuntView, :pio_multiconductor_network_shunt_at, lib, p, i)
    MulticonductorShunt(_str(v.name), _str(v.bus),
                        _terminals(:pio_multiconductor_network_shunt_terminal_at, lib, p, i, v.terminal_map_count),
                        _matrix(:pio_multiconductor_network_shunt_conductance_matrix_row_at, lib, p, i, v.conductance_matrix_row_count),
                        _matrix(:pio_multiconductor_network_shunt_susceptance_matrix_row_at, lib, p, i, v.susceptance_matrix_row_count))
end

_element(::Type{MulticonductorCapacitor}, net::MulticonductorNetwork, i) = _with_network(net) do lib, p
    v = _at(PioMulticonductorCapacitorView, :pio_multiconductor_network_capacitor_at, lib, p, i)
    MulticonductorCapacitor(_str(v.name), _str(v.bus),
                            _terminals(:pio_multiconductor_network_capacitor_terminal_at, lib, p, i, v.terminal_map_count),
                            _str(v.configuration), v.rated_reactive_power_var, v.nominal_voltage_v)
end

_element(::Type{VoltageSource}, net::MulticonductorNetwork, i) = _with_network(net) do lib, p
    v = _at(PioVoltageSourceView, :pio_multiconductor_network_voltage_source_at, lib, p, i)
    VoltageSource(_str(v.name), _str(v.bus),
                  _terminals(:pio_multiconductor_network_voltage_source_terminal_at, lib, p, i, v.terminal_map_count),
                  _f64s(v.voltage_magnitude_v), _f64s(v.voltage_angle_rad))
end

_element(::Type{UntypedObject}, net::MulticonductorNetwork, i) = _with_network(net) do lib, p
    v = _at(PioMulticonductorUntypedObjectView, :pio_multiconductor_network_untyped_object_at, lib, p, i)
    properties = map(0:Int(v.property_count)-1) do j
        prop = _at(PioMulticonductorUntypedPropertyView, :pio_multiconductor_network_untyped_object_property_at, lib, p, i, j)
        Pair{Union{String,Nothing},String}(_optional_str(prop.name, prop.has_name), _str(prop.value))
    end
    UntypedObject(_str(v.class_name), _str(v.name), properties)
end

_element(::Type{SourceCommand}, net::MulticonductorNetwork, i) = _with_network(net) do lib, p
    v = _at(PioMulticonductorCommandView, :pio_multiconductor_network_command_at, lib, p, i)
    SourceCommand(_str(v.verb), _str(v.args))
end

_element(::Type{Pair{String,String}}, net::MulticonductorNetwork, i) = _with_network(net) do lib, p
    v = _at(PioStringPropertyView, :pio_multiconductor_network_option_at, lib, p, i)
    _str(v.name) => _str(v.value)
end
