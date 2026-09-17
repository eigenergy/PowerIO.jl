# `DetailedConnectivity`: the 28 tables node breaker formats such as XIIDM and
# CGMES retain beyond the bus branch view, as properties over the detailed
# connectivity handle.
#
# Every record repeats the C view's field names without the `has_*`
# companions: an absent optional is `nothing`. Nested tables the C ABI exposes
# through secondary `_at` calls (aliases, geographical tags, curve points,
# tap changer steps, droop curve segments, string properties) are materialized
# as fields, so one row is a complete value.
#
# Five tables (`dc_grounds`, `dc_busbars`, `dc_lines`, `dc_series_devices`,
# `dc_switches`) share `DcEquipment`, two (`dc_topological_nodes`, `dc_nodes`)
# share `DcNode`, and two (`voltage_source_converters`,
# `line_commutated_converters`) share `AcDcConverter`, because the C ABI fills
# one view struct for each group. The table name therefore travels in the
# `DetailsTable` type parameter and selects the accessor.

using .LibPowerIO: PioAcDcConverterView, PioBoundaryLineGenerationView, PioBoundaryLineView,
    PioBusBreakerBusView, PioBusbarSectionView, PioCalculatedBusView, PioCaseMetadataView,
    PioComponentAliasView, PioComponentMetadataView, PioConnectivityNodeView,
    PioDcConverterUnitView, PioDcEquipmentView, PioDcNodeView, PioDcTerminalView,
    PioDetailedTerminalView, PioDroopCurveSegmentView, PioEquipmentReactiveLimitsView,
    PioExternalIdentifierView, PioInternalConnectionView, PioJunctionView,
    PioOmittedFieldView, PioOperationalLimitGroupView, PioReactiveCapabilityCurvePointView,
    PioReactiveLimitsView, PioSubnetworkView, PioSubstationView, PioTapChangerStepView,
    PioTapChangerView, PioTemporaryLimitView, PioTieLineView, PioTopologySwitchView,
    PioVoltageLevelView

# --- records ----------------------------------------------------------------

"""
    OmittedField(component, field)

One field the source representation did not state for `component`. `field` is
the PowerIO field name, such as `"voltage_setpoint"`.
"""
struct OmittedField
    component::ComponentId
    field::String
end

"""
    ComponentAlias(value, alias_type)

One alternative identifier of a component. `alias_type` names the alias scheme
when the source states one.
"""
struct ComponentAlias
    value::String
    alias_type::Union{String,Nothing}
end

"""
    ExternalIdentifier(value, authority)

One identifier a component carries from outside the source model. `authority`
names the issuing authority when the source states one.
"""
struct ExternalIdentifier
    value::String
    authority::Union{String,Nothing}
end

"""
    ComponentMetadata

Identity metadata of one component: its display `name`, the
`equipment_container` that holds it, whether the source marks it `fictitious`,
its `aliases` and `external_identifiers`, and its string `properties`.
"""
struct ComponentMetadata
    component::ComponentId
    name::Union{String,Nothing}
    equipment_container::Union{ComponentId,Nothing}
    fictitious::Bool
    aliases::Vector{ComponentAlias}
    external_identifiers::Vector{ExternalIdentifier}
    properties::Dict{String,String}
end

"""
    CaseMetadata

Provenance of one subnetwork: the `case_date` as the source wrote it, the
`forecast_distance` in minutes, the `source_model_format`, and the
`minimum_validation_level` the source declares.
"""
struct CaseMetadata
    case_date::Union{String,Nothing}
    forecast_distance::Union{Int,Nothing}
    source_model_format::Union{String,Nothing}
    minimum_validation_level::Union{String,Nothing}
end

"""
    Subnetwork

One subnetwork of a merged network: its own identity, its `parent` network,
the `case_metadata` it was merged with, and the identities of the
`components` it contributes.
"""
struct Subnetwork
    component::ComponentId
    parent::ComponentId
    case_metadata::CaseMetadata
    components::Vector{ComponentId}
end

"""
    Substation

One substation: its `country` and `operator_name` when stated, and its
`geographical_tags`.
"""
struct Substation
    component::ComponentId
    country::Union{String,Nothing}
    operator_name::Union{String,Nothing}
    geographical_tags::Vector{String}
end

"""
    VoltageLevel

One voltage level inside a substation. `topology_kind` is `"bus_breaker"` or
`"node_breaker"`, and `buses` lists the source bus numbers of the balanced
buses assigned to this level.
"""
struct VoltageLevel
    component::ComponentId
    substation::Union{ComponentId,Nothing}
    nominal_voltage_kv::Float64
    low_voltage_limit_kv::Union{Float64,Nothing}
    high_voltage_limit_kv::Union{Float64,Nothing}
    topology_kind::String
    buses::Vector{Int}
end

"""
    BusBreakerBus

One configured bus of a bus breaker voltage level. `calculated_bus_id` names
the calculated bus it merged into when the source solved the topology.
"""
struct BusBreakerBus
    component::ComponentId
    voltage_level::ComponentId
    calculated_bus_id::Union{Int,Nothing}
    voltage_kv::Union{Float64,Nothing}
    angle_degrees::Union{Float64,Nothing}
end

"""
    CalculatedBus

One bus the source computed by merging closed switches. `nodes` are the
connectivity nodes it covers.
"""
struct CalculatedBus
    voltage_level::ComponentId
    calculated_bus_id::Int
    nodes::Vector{ComponentId}
    voltage_kv::Union{Float64,Nothing}
    angle_degrees::Union{Float64,Nothing}
end

"""
    ConnectivityNode

One node of a node breaker voltage level. `node_number` is the number the
source gave it inside its voltage level.
"""
struct ConnectivityNode
    component::ComponentId
    voltage_level::ComponentId
    node_number::Union{Int,Nothing}
    calculated_bus_id::Union{Int,Nothing}
end

"""
    BusbarSection(component, voltage_level, node)

One busbar section attached to a node of a node breaker voltage level.
"""
struct BusbarSection
    component::ComponentId
    voltage_level::ComponentId
    node::ComponentId
end

"""
    Junction(component)

One CIM junction retained from the source.
"""
struct Junction
    component::ComponentId
end

"""
    DetailedTerminal

One AC terminal of a piece of equipment. `terminal` numbers the terminal on
its equipment from 1. `bus`, `connectable_bus`, and `node` name the topology
the terminal attaches to, and `connected` states whether it is in service.
"""
struct DetailedTerminal
    component::Union{ComponentId,Nothing}
    equipment::ComponentId
    terminal::Int
    voltage_level::ComponentId
    bus::Union{ComponentId,Nothing}
    connectable_bus::Union{ComponentId,Nothing}
    node::Union{ComponentId,Nothing}
    connected::Bool
    active_power_mw::Union{Float64,Nothing}
    reactive_power_mvar::Union{Float64,Nothing}
end

"""
    TopologyEndpoint(kind, component)

One end of a topology switch. `kind` is `"bus"` or `"node"` and names what
`component` identifies.
"""
struct TopologyEndpoint
    kind::String
    component::ComponentId
end

"""
    TopologySwitch

One switch of the detailed topology, between `endpoint1` and `endpoint2`.
`kind` is the source switch kind, such as `"breaker"` or `"disconnector"`;
`retained` marks a switch the source keeps when it merges buses.

[`Switch`](@ref) is the balanced transmission switch table; this is the node
breaker switch the detailed topology retains.
"""
struct TopologySwitch
    component::ComponentId
    voltage_level::ComponentId
    kind::String
    endpoint1::TopologyEndpoint
    endpoint2::TopologyEndpoint
    open::Bool
    retained::Bool
end

"""
    InternalConnection(voltage_level, node1, node2)

One permanent connection between two nodes of a node breaker voltage level.
"""
struct InternalConnection
    voltage_level::ComponentId
    node1::ComponentId
    node2::ComponentId
end

"""
    TemporaryLimit

One temporary limit: the value that applies for `acceptable_duration_seconds`
after the permanent limit is exceeded.
"""
struct TemporaryLimit
    name::String
    value::Float64
    acceptable_duration_seconds::Int
    fictitious::Bool
end

"""
    LoadingLimits

The limits of one quantity in an operational limit group: the
`permanent_limit` and its name, and the `temporary_limits` ordered as the
source wrote them. Currents are amperes, active power megawatts, apparent
power megavolt amperes.
"""
struct LoadingLimits
    permanent_limit::Union{Float64,Nothing}
    permanent_limit_name::Union{String,Nothing}
    temporary_limits::Vector{TemporaryLimit}
end

"""
    OperationalLimitGroup

One named group of operational limits on a numbered terminal of one piece of
equipment. `selected` marks the group in effect. Each of `current_limits`,
`active_power_limits`, and `apparent_power_limits` is `nothing` unless the
source states that quantity.
"""
struct OperationalLimitGroup
    equipment::ComponentId
    terminal::Int
    id::String
    selected::Bool
    properties::Dict{String,String}
    current_limits::Union{LoadingLimits,Nothing}
    active_power_limits::Union{LoadingLimits,Nothing}
    apparent_power_limits::Union{LoadingLimits,Nothing}
end

"""
    TapChangerStep

One step of a tap changer: its `position`, the voltage `ratio_pu` and
`phase_shift_degrees` it applies, and the four percent deviations it applies
to the transformer impedance and magnetizing branch.
"""
struct TapChangerStep
    position::Int
    ratio_pu::Float64
    phase_shift_degrees::Float64
    resistance_deviation_percent::Float64
    reactance_deviation_percent::Float64
    conductance_deviation_percent::Float64
    susceptance_deviation_percent::Float64
end

"""
    TapChanger

One tap changer of a transformer. `winding` numbers the winding it acts on
from 1, `kind` is `"ratio"` or `"phase"`, and `steps` are its positions.
`tap_position` is `nothing` when the source declares the steps without
assigning one.
"""
struct TapChanger
    component::Union{ComponentId,Nothing}
    transformer::ComponentId
    winding::Int
    kind::String
    tap_position::Union{Int,Nothing}
    solved_tap_position::Union{Int,Nothing}
    low_tap_position::Int
    neutral_tap_position::Union{Int,Nothing}
    normal_tap_position::Union{Int,Nothing}
    voltage_step_increment_percent::Union{Float64,Nothing}
    load_tap_changing_capabilities::Bool
    regulating::Bool
    regulation_mode::Union{String,Nothing}
    regulation_value::Union{Float64,Nothing}
    target_deadband::Union{Float64,Nothing}
    regulation_terminal::Union{TerminalReference,Nothing}
    steps::Vector{TapChangerStep}
end

"""
    ReactiveCapabilityCurvePoint

One point of a reactive capability curve: the reactive power band available at
`active_power_mw`, with the string `properties` the source attached to it.
"""
struct ReactiveCapabilityCurvePoint
    active_power_mw::Float64
    minimum_reactive_power_mvar::Float64
    maximum_reactive_power_mvar::Float64
    properties::Dict{String,String}
end

"""
    ReactiveLimits

Reactive power limits of one machine. `kind` is `"min_max"` or
`"capability_curve"`: a min max record fills the two bounds and leaves
`points` empty, a capability curve fills `points` and leaves the bounds
`nothing`.
"""
struct ReactiveLimits
    kind::String
    minimum_reactive_power_mvar::Union{Float64,Nothing}
    maximum_reactive_power_mvar::Union{Float64,Nothing}
    curve_style::Union{String,Nothing}
    properties::Dict{String,String}
    points::Vector{ReactiveCapabilityCurvePoint}
end

"""
    EquipmentReactiveLimits(equipment, limits)

The [`ReactiveLimits`](@ref) the source stated for one piece of equipment,
retained beyond the balanced generator bounds.
"""
struct EquipmentReactiveLimits
    equipment::ComponentId
    limits::ReactiveLimits
end

"""
    BoundaryLineGeneration

The generation attached to the open end of a boundary line: its regulation
state, active power range and targets, and its `reactive_limits`.
"""
struct BoundaryLineGeneration
    voltage_regulation_on::Bool
    minimum_active_power_mw::Union{Float64,Nothing}
    maximum_active_power_mw::Union{Float64,Nothing}
    target_active_power_mw::Union{Float64,Nothing}
    target_reactive_power_mvar::Union{Float64,Nothing}
    target_voltage_kv::Union{Float64,Nothing}
    reactive_limits::Union{ReactiveLimits,Nothing}
end

"""
    BoundaryLine

One boundary line: a half line whose far end is a boundary rather than a bus.
Setpoints are the boundary injection, impedances are ohms and siemens at the
voltage level, `pairing_key` matches the line against its other half, and
`calculation_load` and `calculation_generator` name the balanced elements the
boundary injection became.
"""
struct BoundaryLine
    component::ComponentId
    voltage_level::ComponentId
    active_power_setpoint_mw::Float64
    reactive_power_setpoint_mvar::Float64
    resistance_ohm::Float64
    reactance_ohm::Float64
    conductance_siemens::Float64
    susceptance_siemens::Float64
    pairing_key::Union{String,Nothing}
    generation::Union{BoundaryLineGeneration,Nothing}
    calculation_load::Union{ComponentId,Nothing}
    calculation_generator::Union{ComponentId,Nothing}
end

"""
    TieLine

One tie line: the pairing of two boundary lines, and the balanced branch the
pair became when stated.
"""
struct TieLine
    component::ComponentId
    boundary_line1::ComponentId
    boundary_line2::ComponentId
    calculation_branch::Union{ComponentId,Nothing}
end

"""
    DcConverterUnit(component, substation, operation_mode)

One DC converter unit: the converters of one pole or bipole, grouped.
"""
struct DcConverterUnit
    component::ComponentId
    substation::Union{ComponentId,Nothing}
    operation_mode::String
end

"""
    DcNode

One node of the DC topology. `kind` distinguishes a physical node from a
calculated topological node; `dc_topological_node` names the topological node
a physical node merged into.
"""
struct DcNode
    component::ComponentId
    kind::String
    nominal_voltage_kv::Union{Float64,Nothing}
    voltage_kv::Union{Float64,Nothing}
    dc_converter_unit::Union{ComponentId,Nothing}
    dc_topological_node::Union{ComponentId,Nothing}
end

"""
    DcTerminal

One terminal of a piece of DC equipment. `polarity` is the source polarity
token, and the flow fields carry the solved values when the source states
them.
"""
struct DcTerminal
    component::Union{ComponentId,Nothing}
    sequence_number::Union{Int,Nothing}
    dc_node::Union{ComponentId,Nothing}
    dc_topological_node::Union{ComponentId,Nothing}
    polarity::Union{String,Nothing}
    connected::Union{Bool,Nothing}
    active_power_mw::Union{Float64,Nothing}
    current_a::Union{Float64,Nothing}
end

"""
    DcEquipment

One piece of DC equipment. `kind` names the table the row came from
(`"ground"`, `"busbar"`, `"line"`, `"series_device"`, `"switch"`), and only
the fields that kind uses are filled: a line states `resistance_ohm` and
`length_km`, a switch states `switch_kind` and `open`. `terminals` holds the
one or two terminals the equipment connects through.
"""
struct DcEquipment
    component::ComponentId
    equipment_container::Union{ComponentId,Nothing}
    kind::String
    terminals::Vector{DcTerminal}
    rated_dc_voltage_kv::Union{Float64,Nothing}
    resistance_ohm::Union{Float64,Nothing}
    inductance_h::Union{Float64,Nothing}
    capacitance_f::Union{Float64,Nothing}
    length_km::Union{Float64,Nothing}
    switch_kind::Union{String,Nothing}
    open::Union{Bool,Nothing}
end

"""
    DroopCurveSegment(minimum_voltage_kv, maximum_voltage_kv, k)

One segment of a converter DC voltage droop curve: the gain `k` that applies
over the DC voltage band.
"""
struct DroopCurveSegment
    minimum_voltage_kv::Float64
    maximum_voltage_kv::Float64
    k::Float64
end

"""
    AcDcConverter

One AC/DC converter station. `kind` names the table the row came from:
`"voltage_source"` for a voltage source converter, `"line_commutated"` for a
line commutated converter. Each converter fills the fields its technology
uses, so a voltage source converter states `voltage_setpoint_kv` and
`reactive_limits` while a line commutated converter states the alpha and
gamma firing angles.

`droop_curve` is `nothing` when the source states no curve, and an empty
vector when it states an empty one. The C ABI reads reactive limit properties
and capability points for voltage source converters only, so a line commutated
converter's `reactive_limits` carries its `kind` and bounds with empty
`properties` and `points`.
"""
struct AcDcConverter
    component::ComponentId
    kind::String
    dc_converter_unit::Union{ComponentId,Nothing}
    dc_terminal1::DcTerminal
    dc_terminal2::DcTerminal
    base_apparent_power_mva::Union{Float64,Nothing}
    minimum_active_power_mw::Union{Float64,Nothing}
    maximum_active_power_mw::Union{Float64,Nothing}
    minimum_dc_voltage_kv::Union{Float64,Nothing}
    maximum_dc_voltage_kv::Union{Float64,Nothing}
    rated_dc_voltage_kv::Union{Float64,Nothing}
    valve_u0_kv::Union{Float64,Nothing}
    number_of_valves::Union{Int,Nothing}
    idle_loss_mw::Union{Float64,Nothing}
    switching_loss_mw_per_ampere::Union{Float64,Nothing}
    resistive_loss_ohm::Union{Float64,Nothing}
    control_mode::Union{String,Nothing}
    active_power_at_pcc_mw::Union{Float64,Nothing}
    reactive_power_at_pcc_mvar::Union{Float64,Nothing}
    target_active_power_mw::Union{Float64,Nothing}
    target_dc_voltage_kv::Union{Float64,Nothing}
    pcc_terminal::Union{TerminalReference,Nothing}
    droop_curve::Union{Vector{DroopCurveSegment},Nothing}
    droop::Union{Float64,Nothing}
    droop_compensation::Union{Float64,Nothing}
    q_share::Union{Float64,Nothing}
    maximum_modulation_index::Union{Float64,Nothing}
    maximum_valve_current_a::Union{Float64,Nothing}
    dc_current_a::Union{Float64,Nothing}
    ac_voltage_kv::Union{Float64,Nothing}
    dc_voltage_kv::Union{Float64,Nothing}
    voltage_regulator_on::Union{Bool,Nothing}
    voltage_setpoint_kv::Union{Float64,Nothing}
    reactive_power_setpoint_mvar::Union{Float64,Nothing}
    reactive_limits::Union{ReactiveLimits,Nothing}
    pole_loss_active_power_mw::Union{Float64,Nothing}
    reactive_model::Union{String,Nothing}
    power_factor::Union{Float64,Nothing}
    operating_mode::Union{String,Nothing}
    rated_dc_current_a::Union{Float64,Nothing}
    minimum_alpha_degrees::Union{Float64,Nothing}
    maximum_alpha_degrees::Union{Float64,Nothing}
    minimum_gamma_degrees::Union{Float64,Nothing}
    maximum_gamma_degrees::Union{Float64,Nothing}
    target_alpha_degrees::Union{Float64,Nothing}
    target_gamma_degrees::Union{Float64,Nothing}
    target_dc_current_a::Union{Float64,Nothing}
    alpha_degrees::Union{Float64,Nothing}
    gamma_degrees::Union{Float64,Nothing}
    delta_degrees::Union{Float64,Nothing}
    uf_kv::Union{Float64,Nothing}
    uv_kv::Union{Float64,Nothing}
end

# --- the handle and its tables ----------------------------------------------

"""
    DetailedConnectivity

Source neutral detailed connectivity retained from node breaker formats such
as XIIDM and CGMES. `dc.counts` is a `NamedTuple` of table lengths, and each
of the 28 tables is a property returning an [`Elements`](@ref) vector of the
matching record:

```julia
details = parse("grid.xiidm").value.detailed_connectivity

details.counts.voltage_levels       # 3
details.substations[1].country      # "US"
details.switches[1].endpoint1.kind  # "node"
[t.equipment for t in details.terminals]
```
"""
struct DetailedConnectivity
    handle::DetailedConnectivityHandle
end

# Table name => record type, in the order of the counts view, which is also
# the order `propertynames` reports.
const _DETAILS_TABLES = (
    omitted_fields = OmittedField,
    component_metadata = ComponentMetadata,
    subnetworks = Subnetwork,
    substations = Substation,
    voltage_levels = VoltageLevel,
    bus_breaker_buses = BusBreakerBus,
    calculated_buses = CalculatedBus,
    connectivity_nodes = ConnectivityNode,
    busbar_sections = BusbarSection,
    junctions = Junction,
    terminals = DetailedTerminal,
    switches = TopologySwitch,
    internal_connections = InternalConnection,
    operational_limit_groups = OperationalLimitGroup,
    tap_changers = TapChanger,
    equipment_reactive_limits = EquipmentReactiveLimits,
    boundary_lines = BoundaryLine,
    tie_lines = TieLine,
    dc_converter_units = DcConverterUnit,
    dc_topological_nodes = DcNode,
    dc_nodes = DcNode,
    dc_grounds = DcEquipment,
    dc_busbars = DcEquipment,
    dc_lines = DcEquipment,
    dc_series_devices = DcEquipment,
    dc_switches = DcEquipment,
    voltage_source_converters = AcDcConverter,
    line_commutated_converters = AcDcConverter,
)

# One named table of one `DetailedConnectivity`. The name selects the C
# accessor in `_element`, which the record type alone cannot do for the
# groups that share a view struct.
struct DetailsTable{name}
    details::DetailedConnectivity
end

function _details_counts(dc::DetailedConnectivity)
    h = getfield(dc, :handle)
    lib = getfield(h, :lib)
    v = @with_handles h _fill(PioDetailedConnectivityCountsView, lib) do out, err
        @capi lib :pio_detailed_connectivity_counts(_ptr(h), out, err)
    end
    names = fieldnames(PioDetailedConnectivityCountsView)
    return NamedTuple{names}(map(f -> Int(getfield(v, f)), names))
end

function Base.getproperty(dc::DetailedConnectivity, name::Symbol)
    name === :counts && return _details_counts(dc)
    if haskey(_DETAILS_TABLES, name)
        T = _DETAILS_TABLES[name]
        return Elements{T,DetailsTable{name}}(DetailsTable{name}(dc), getfield(_details_counts(dc), name))
    end
    return getfield(dc, name)
end

Base.propertynames(::DetailedConnectivity, private::Bool=false) =
    private ? (:counts, keys(_DETAILS_TABLES)..., :handle) : (:counts, keys(_DETAILS_TABLES)...)

_lib_of(dc::DetailedConnectivity) = getfield(getfield(dc, :handle), :lib)

# --- record conversions ------------------------------------------------------

# Run `f(lib, p)` with the detailed connectivity pointer preserved for the
# duration, as `_with_network` does for a balanced network.
function _with_details(f, t::DetailsTable)
    h = getfield(getfield(t, :details), :handle)
    return @with_handles h f(getfield(h, :lib), _ptr(h))
end

# The string properties of row `i`, keyed by property name.
function _string_properties(entry, lib, p::Ptr{Cvoid}, i::Integer, count::Integer)
    out = Dict{String,String}()
    for j in 0:count-1
        v = _at(PioStringPropertyView, entry, lib, p, i, j)
        out[_str(v.name)] = _str(v.value)
    end
    return out
end

# The string properties of sub-row `j` of row `i`.
function _string_properties(entry, lib, p::Ptr{Cvoid}, i::Integer, j::Integer, count::Integer)
    out = Dict{String,String}()
    for k in 0:count-1
        v = _at(PioStringPropertyView, entry, lib, p, i, j, k)
        out[_str(v.name)] = _str(v.value)
    end
    return out
end

_case_metadata(v::PioCaseMetadataView) =
    CaseMetadata(_optional_str(v.case_date, v.has_case_date),
                 _optional(Int(v.forecast_distance), v.has_forecast_distance),
                 _optional_str(v.source_model_format, v.has_source_model_format),
                 _optional_str(v.minimum_validation_level, v.has_minimum_validation_level))

_optional_component_id(v::PioComponentIdView, present::Bool) =
    present ? _component_id(v) : nothing

# One reactive limit record with its curve. `properties`, `points`, and
# `point_properties` are the `Val` entry points of the owning table, since the
# C ABI reads a curve through the accessors of whatever holds it.
function _reactive_limits(v::PioReactiveLimitsView, present::Bool, lib, p::Ptr{Cvoid},
                          i::Integer, properties, points, point_properties)
    present || return nothing
    curve = map(0:Int(v.point_count)-1) do j
        pt = _at(PioReactiveCapabilityCurvePointView, points, lib, p, i, j)
        ReactiveCapabilityCurvePoint(pt.active_power_mw, pt.minimum_reactive_power_mvar,
                                     pt.maximum_reactive_power_mvar,
                                     _string_properties(point_properties, lib, p, i, j,
                                                        Int(pt.property_count)))
    end
    return ReactiveLimits(_str(v.kind),
                          _optional(v.minimum_reactive_power_mvar, v.has_minimum_and_maximum),
                          _optional(v.maximum_reactive_power_mvar, v.has_minimum_and_maximum),
                          _optional_str(v.curve_style, v.has_curve_style),
                          _string_properties(properties, lib, p, i, Int(v.property_count)),
                          curve)
end

# A table the C ABI gives no property or capability point accessors for keeps
# the bounds and leaves the curve empty.
function _reactive_limits(v::PioReactiveLimitsView, present::Bool, lib, ::Ptr{Cvoid},
                          ::Integer, ::Nothing, ::Nothing, ::Nothing)
    present || return nothing
    return ReactiveLimits(_str(v.kind),
                          _optional(v.minimum_reactive_power_mvar, v.has_minimum_and_maximum),
                          _optional(v.maximum_reactive_power_mvar, v.has_minimum_and_maximum),
                          _optional_str(v.curve_style, v.has_curve_style),
                          Dict{String,String}(), ReactiveCapabilityCurvePoint[])
end

_dc_terminal(v::PioDcTerminalView) =
    DcTerminal(_optional_component_id(v.component, v.has_component),
               _optional(Int(v.sequence_number), v.has_sequence_number),
               _optional_component_id(v.dc_node, v.has_dc_node),
               _optional_component_id(v.dc_topological_node, v.has_dc_topological_node),
               _optional_str(v.polarity, v.has_polarity),
               _optional(v.connected, v.has_connected),
               _optional(v.active_power_mw, v.has_active_power),
               _optional(v.current_a, v.has_current))

_element(::Type{OmittedField}, t::DetailsTable, i) = _with_details(t) do lib, p
    v = _at(PioOmittedFieldView, Val(:pio_detailed_connectivity_omitted_field_at), lib, p, i)
    OmittedField(_component_id(v.component), _str(v.field))
end

_element(::Type{ComponentMetadata}, t::DetailsTable, i) = _with_details(t) do lib, p
    v = _at(PioComponentMetadataView, Val(:pio_detailed_connectivity_component_metadata_at), lib, p, i)
    aliases = map(0:Int(v.alias_count)-1) do j
        a = _at(PioComponentAliasView, Val(:pio_detailed_connectivity_component_alias_at), lib, p, i, j)
        ComponentAlias(_str(a.value), _optional_str(a.alias_type, a.has_alias_type))
    end
    identifiers = map(0:Int(v.external_identifier_count)-1) do j
        e = _at(PioExternalIdentifierView, Val(:pio_detailed_connectivity_external_identifier_at), lib, p, i, j)
        ExternalIdentifier(_str(e.value), _optional_str(e.authority, e.has_authority))
    end
    ComponentMetadata(_component_id(v.component), _optional_str(v.name, v.has_name),
                      _optional_component_id(v.equipment_container, v.has_equipment_container),
                      v.fictitious, aliases, identifiers,
                      _string_properties(Val(:pio_detailed_connectivity_component_property_at),
                                         lib, p, i, Int(v.property_count)))
end

_element(::Type{Subnetwork}, t::DetailsTable, i) = _with_details(t) do lib, p
    v = _at(PioSubnetworkView, Val(:pio_detailed_connectivity_subnetwork_at), lib, p, i)
    components = map(0:Int(v.component_count)-1) do j
        _component_id(_at(PioComponentIdView, Val(:pio_detailed_connectivity_subnetwork_component_at),
                          lib, p, i, j))
    end
    Subnetwork(_component_id(v.component), _component_id(v.parent), _case_metadata(v.case_metadata),
               components)
end

_element(::Type{Substation}, t::DetailsTable, i) = _with_details(t) do lib, p
    v = _at(PioSubstationView, Val(:pio_detailed_connectivity_substation_at), lib, p, i)
    tags = map(0:Int(v.geographical_tag_count)-1) do j
        _str(_at(PioStringView, Val(:pio_detailed_connectivity_substation_geographical_tag_at),
                 lib, p, i, j))
    end
    Substation(_component_id(v.component), _optional_str(v.country, v.has_country),
               _optional_str(v.operator_name, v.has_operator_name), tags)
end

_element(::Type{VoltageLevel}, t::DetailsTable, i) = _with_details(t) do lib, p
    v = _at(PioVoltageLevelView, Val(:pio_detailed_connectivity_voltage_level_at), lib, p, i)
    buses = map(0:Int(v.bus_count)-1) do j
        Int(_at(Csize_t, Val(:pio_detailed_connectivity_voltage_level_bus_at), lib, p, i, j))
    end
    VoltageLevel(_component_id(v.component),
                 _optional_component_id(v.substation, v.has_substation),
                 v.nominal_voltage_kv,
                 _optional(v.low_voltage_limit_kv, v.has_low_voltage_limit),
                 _optional(v.high_voltage_limit_kv, v.has_high_voltage_limit),
                 _str(v.topology_kind), buses)
end

_element(::Type{BusBreakerBus}, t::DetailsTable, i) = _with_details(t) do lib, p
    v = _at(PioBusBreakerBusView, Val(:pio_detailed_connectivity_bus_breaker_bus_at), lib, p, i)
    BusBreakerBus(_component_id(v.component), _component_id(v.voltage_level),
                  _optional(Int(v.calculated_bus_id), v.has_calculated_bus),
                  _optional(v.voltage_kv, v.has_voltage),
                  _optional(v.angle_degrees, v.has_angle))
end

_element(::Type{CalculatedBus}, t::DetailsTable, i) = _with_details(t) do lib, p
    v = _at(PioCalculatedBusView, Val(:pio_detailed_connectivity_calculated_bus_at), lib, p, i)
    nodes = map(0:Int(v.node_count)-1) do j
        _component_id(_at(PioComponentIdView, Val(:pio_detailed_connectivity_calculated_bus_node_at),
                          lib, p, i, j))
    end
    CalculatedBus(_component_id(v.voltage_level), Int(v.calculated_bus_id), nodes,
                  _optional(v.voltage_kv, v.has_voltage),
                  _optional(v.angle_degrees, v.has_angle))
end

_element(::Type{ConnectivityNode}, t::DetailsTable, i) = _with_details(t) do lib, p
    v = _at(PioConnectivityNodeView, Val(:pio_detailed_connectivity_node_at), lib, p, i)
    ConnectivityNode(_component_id(v.component), _component_id(v.voltage_level),
                     _optional(Int(v.node_number), v.has_node_number),
                     _optional(Int(v.calculated_bus_id), v.has_calculated_bus))
end

_element(::Type{BusbarSection}, t::DetailsTable, i) = _with_details(t) do lib, p
    v = _at(PioBusbarSectionView, Val(:pio_detailed_connectivity_busbar_section_at), lib, p, i)
    BusbarSection(_component_id(v.component), _component_id(v.voltage_level), _component_id(v.node))
end

_element(::Type{Junction}, t::DetailsTable, i) = _with_details(t) do lib, p
    v = _at(PioJunctionView, Val(:pio_detailed_connectivity_junction_at), lib, p, i)
    Junction(_component_id(v.component))
end

_element(::Type{DetailedTerminal}, t::DetailsTable, i) = _with_details(t) do lib, p
    v = _at(PioDetailedTerminalView, Val(:pio_detailed_connectivity_terminal_at), lib, p, i)
    DetailedTerminal(_optional_component_id(v.component, v.has_component),
                     _component_id(v.equipment), Int(v.terminal),
                     _component_id(v.voltage_level),
                     _optional_component_id(v.bus, v.has_bus),
                     _optional_component_id(v.connectable_bus, v.has_connectable_bus),
                     _optional_component_id(v.node, v.has_node), v.connected,
                     _optional(v.active_power_mw, v.has_active_power),
                     _optional(v.reactive_power_mvar, v.has_reactive_power))
end

_element(::Type{TopologySwitch}, t::DetailsTable, i) = _with_details(t) do lib, p
    v = _at(PioTopologySwitchView, Val(:pio_detailed_connectivity_switch_at), lib, p, i)
    TopologySwitch(_component_id(v.component), _component_id(v.voltage_level), _str(v.kind),
                   TopologyEndpoint(_str(v.endpoint1_kind), _component_id(v.endpoint1)),
                   TopologyEndpoint(_str(v.endpoint2_kind), _component_id(v.endpoint2)),
                   v.open, v.retained)
end

_element(::Type{InternalConnection}, t::DetailsTable, i) = _with_details(t) do lib, p
    v = _at(PioInternalConnectionView, Val(:pio_detailed_connectivity_internal_connection_at), lib, p, i)
    InternalConnection(_component_id(v.voltage_level), _component_id(v.node1), _component_id(v.node2))
end

# One temporary limit of an operational limit group. `quantity` is the C token
# naming the limit kind: "current", "active_power", or "apparent_power".
function _temporary_limit(lib, p::Ptr{Cvoid}, i::Integer, quantity::String, j::Integer)
    v = GC.@preserve quantity _fill(PioTemporaryLimitView, lib) do out, err
        @capi lib :pio_detailed_connectivity_temporary_limit_at(p, Csize_t(i), pointer(quantity),
                                                                sizeof(quantity), Csize_t(j), out, err)
    end
    return TemporaryLimit(_str(v.name), v.value, Int(v.acceptable_duration_seconds), v.fictitious)
end

# The limits of one quantity. `present` is that quantity's `has_` flag, so an
# absent quantity reads nothing further.
function _loading_limits(lib, p::Ptr{Cvoid}, i::Integer, quantity::String, present::Bool,
                         limit::Float64, has_limit::Bool, name::PioStringView,
                         has_name::Bool, count::Integer)
    present || return nothing
    temporary = map(j -> _temporary_limit(lib, p, i, quantity, j), 0:count-1)
    return LoadingLimits(_optional(limit, has_limit), _optional_str(name, has_name), temporary)
end

_element(::Type{OperationalLimitGroup}, t::DetailsTable, i) = _with_details(t) do lib, p
    v = _at(PioOperationalLimitGroupView, Val(:pio_detailed_connectivity_operational_limit_group_at),
            lib, p, i)
    OperationalLimitGroup(
        _component_id(v.equipment), Int(v.terminal), _str(v.id), v.selected,
        _string_properties(Val(:pio_detailed_connectivity_operational_limit_group_property_at),
                           lib, p, i, Int(v.property_count)),
        _loading_limits(lib, p, i, "current", v.has_current_limits,
                        v.current_permanent_limit_a, v.has_current_permanent_limit,
                        v.current_permanent_limit_name, v.has_current_permanent_limit_name,
                        Int(v.current_temporary_limit_count)),
        _loading_limits(lib, p, i, "active_power", v.has_active_power_limits,
                        v.active_power_permanent_limit_mw, v.has_active_power_permanent_limit,
                        v.active_power_permanent_limit_name, v.has_active_power_permanent_limit_name,
                        Int(v.active_power_temporary_limit_count)),
        _loading_limits(lib, p, i, "apparent_power", v.has_apparent_power_limits,
                        v.apparent_power_permanent_limit_mva, v.has_apparent_power_permanent_limit,
                        v.apparent_power_permanent_limit_name, v.has_apparent_power_permanent_limit_name,
                        Int(v.apparent_power_temporary_limit_count)))
end

_element(::Type{TapChanger}, t::DetailsTable, i) = _with_details(t) do lib, p
    v = _at(PioTapChangerView, Val(:pio_detailed_connectivity_tap_changer_at), lib, p, i)
    steps = map(0:Int(v.step_count)-1) do j
        s = _at(PioTapChangerStepView, Val(:pio_detailed_connectivity_tap_changer_step_at), lib, p, i, j)
        TapChangerStep(Int(s.position), s.ratio_pu, s.phase_shift_degrees,
                       s.resistance_deviation_percent, s.reactance_deviation_percent,
                       s.conductance_deviation_percent, s.susceptance_deviation_percent)
    end
    TapChanger(_optional_component_id(v.component, v.has_component), _component_id(v.transformer),
               Int(v.winding), _str(v.kind),
               _optional(Int(v.tap_position), v.has_tap_position),
               _optional(Int(v.solved_tap_position), v.has_solved_tap_position),
               Int(v.low_tap_position),
               _optional(Int(v.neutral_tap_position), v.has_neutral_tap_position),
               _optional(Int(v.normal_tap_position), v.has_normal_tap_position),
               _optional(v.voltage_step_increment_percent, v.has_voltage_step_increment_percent),
               v.load_tap_changing_capabilities, v.regulating,
               _optional_str(v.regulation_mode, v.has_regulation_mode),
               _optional(v.regulation_value, v.has_regulation_value),
               _optional(v.target_deadband, v.has_target_deadband),
               _terminal_reference(v.regulation_terminal, v.has_regulation_terminal), steps)
end

_element(::Type{EquipmentReactiveLimits}, t::DetailsTable, i) = _with_details(t) do lib, p
    v = _at(PioEquipmentReactiveLimitsView,
            Val(:pio_detailed_connectivity_equipment_reactive_limits_at), lib, p, i)
    limits = _reactive_limits(v.limits, true, lib, p, i,
                              Val(:pio_detailed_connectivity_equipment_reactive_limit_property_at),
                              Val(:pio_detailed_connectivity_equipment_reactive_capability_point_at),
                              Val(:pio_detailed_connectivity_equipment_reactive_capability_point_property_at))
    EquipmentReactiveLimits(_component_id(v.equipment), limits)
end

_element(::Type{BoundaryLine}, t::DetailsTable, i) = _with_details(t) do lib, p
    v = _at(PioBoundaryLineView, Val(:pio_detailed_connectivity_boundary_line_at), lib, p, i)
    generation = if v.has_generation
        g = v.generation
        limits = _reactive_limits(g.reactive_limits, g.has_reactive_limits, lib, p, i,
                                  Val(:pio_detailed_connectivity_boundary_line_reactive_limit_property_at),
                                  Val(:pio_detailed_connectivity_boundary_line_reactive_capability_point_at),
                                  Val(:pio_detailed_connectivity_boundary_line_reactive_capability_point_property_at))
        BoundaryLineGeneration(g.voltage_regulation_on,
                               _optional(g.minimum_active_power_mw, g.has_minimum_active_power),
                               _optional(g.maximum_active_power_mw, g.has_maximum_active_power),
                               _optional(g.target_active_power_mw, g.has_target_active_power),
                               _optional(g.target_reactive_power_mvar, g.has_target_reactive_power),
                               _optional(g.target_voltage_kv, g.has_target_voltage), limits)
    else
        nothing
    end
    BoundaryLine(_component_id(v.component), _component_id(v.voltage_level),
                 v.active_power_setpoint_mw, v.reactive_power_setpoint_mvar,
                 v.resistance_ohm, v.reactance_ohm, v.conductance_siemens, v.susceptance_siemens,
                 _optional_str(v.pairing_key, v.has_pairing_key), generation,
                 _optional_component_id(v.calculation_load, v.has_calculation_load),
                 _optional_component_id(v.calculation_generator, v.has_calculation_generator))
end

_element(::Type{TieLine}, t::DetailsTable, i) = _with_details(t) do lib, p
    v = _at(PioTieLineView, Val(:pio_detailed_connectivity_tie_line_at), lib, p, i)
    TieLine(_component_id(v.component), _component_id(v.boundary_line1),
            _component_id(v.boundary_line2),
            _optional_component_id(v.calculation_branch, v.has_calculation_branch))
end

_element(::Type{DcConverterUnit}, t::DetailsTable, i) = _with_details(t) do lib, p
    v = _at(PioDcConverterUnitView, Val(:pio_detailed_connectivity_dc_converter_unit_at), lib, p, i)
    DcConverterUnit(_component_id(v.component),
                    _optional_component_id(v.substation, v.has_substation),
                    _str(v.operation_mode))
end

_dc_node(v::PioDcNodeView) =
    DcNode(_component_id(v.component), _str(v.kind),
           _optional(v.nominal_voltage_kv, v.has_nominal_voltage),
           _optional(v.voltage_kv, v.has_voltage),
           _optional_component_id(v.dc_converter_unit, v.has_dc_converter_unit),
           _optional_component_id(v.dc_topological_node, v.has_dc_topological_node))

_element(::Type{DcNode}, t::DetailsTable{:dc_topological_nodes}, i) = _with_details(t) do lib, p
    _dc_node(_at(PioDcNodeView, Val(:pio_detailed_connectivity_dc_topological_node_at), lib, p, i))
end

_element(::Type{DcNode}, t::DetailsTable{:dc_nodes}, i) = _with_details(t) do lib, p
    _dc_node(_at(PioDcNodeView, Val(:pio_detailed_connectivity_dc_node_at), lib, p, i))
end

function _dc_equipment(v::PioDcEquipmentView)
    terminals = [_dc_terminal(v.terminal1), _dc_terminal(v.terminal2)]
    return DcEquipment(_component_id(v.component),
                       _optional_component_id(v.equipment_container, v.has_equipment_container),
                       _str(v.kind), terminals[1:min(Int(v.terminal_count), 2)],
                       _optional(v.rated_dc_voltage_kv, v.has_rated_dc_voltage),
                       _optional(v.resistance_ohm, v.has_resistance),
                       _optional(v.inductance_h, v.has_inductance),
                       _optional(v.capacitance_f, v.has_capacitance),
                       _optional(v.length_km, v.has_length),
                       _optional_str(v.switch_kind, v.has_switch_kind),
                       _optional(v.open, v.has_open))
end

_element(::Type{DcEquipment}, t::DetailsTable{:dc_grounds}, i) = _with_details(t) do lib, p
    _dc_equipment(_at(PioDcEquipmentView, Val(:pio_detailed_connectivity_dc_ground_at), lib, p, i))
end

_element(::Type{DcEquipment}, t::DetailsTable{:dc_busbars}, i) = _with_details(t) do lib, p
    _dc_equipment(_at(PioDcEquipmentView, Val(:pio_detailed_connectivity_dc_busbar_at), lib, p, i))
end

_element(::Type{DcEquipment}, t::DetailsTable{:dc_lines}, i) = _with_details(t) do lib, p
    _dc_equipment(_at(PioDcEquipmentView, Val(:pio_detailed_connectivity_dc_line_at), lib, p, i))
end

_element(::Type{DcEquipment}, t::DetailsTable{:dc_series_devices}, i) = _with_details(t) do lib, p
    _dc_equipment(_at(PioDcEquipmentView, Val(:pio_detailed_connectivity_dc_series_device_at), lib, p, i))
end

_element(::Type{DcEquipment}, t::DetailsTable{:dc_switches}, i) = _with_details(t) do lib, p
    _dc_equipment(_at(PioDcEquipmentView, Val(:pio_detailed_connectivity_dc_switch_at), lib, p, i))
end

# One converter row. `segments` is the droop curve entry point of the table;
# `properties`, `points`, and `point_properties` are its reactive limit entry
# points, or `nothing` where the C ABI declares none.
function _ac_dc_converter(v::PioAcDcConverterView, lib, p::Ptr{Cvoid}, i::Integer,
                          segments, properties, points, point_properties)
    droop_curve = if v.has_droop_curve
        map(0:Int(v.droop_curve_segment_count)-1) do j
            s = _at(PioDroopCurveSegmentView, segments, lib, p, i, j)
            DroopCurveSegment(s.minimum_voltage_kv, s.maximum_voltage_kv, s.k)
        end
    else
        nothing
    end
    return AcDcConverter(_component_id(v.component), _str(v.kind),
                         _optional_component_id(v.dc_converter_unit, v.has_dc_converter_unit),
                         _dc_terminal(v.dc_terminal1), _dc_terminal(v.dc_terminal2),
                         _optional(v.base_apparent_power_mva, v.has_base_apparent_power),
                         _optional(v.minimum_active_power_mw, v.has_minimum_active_power),
                         _optional(v.maximum_active_power_mw, v.has_maximum_active_power),
                         _optional(v.minimum_dc_voltage_kv, v.has_minimum_dc_voltage),
                         _optional(v.maximum_dc_voltage_kv, v.has_maximum_dc_voltage),
                         _optional(v.rated_dc_voltage_kv, v.has_rated_dc_voltage),
                         _optional(v.valve_u0_kv, v.has_valve_u0),
                         _optional(Int(v.number_of_valves), v.has_number_of_valves),
                         _optional(v.idle_loss_mw, v.has_idle_loss),
                         _optional(v.switching_loss_mw_per_ampere, v.has_switching_loss),
                         _optional(v.resistive_loss_ohm, v.has_resistive_loss),
                         _optional_str(v.control_mode, v.has_control_mode),
                         _optional(v.active_power_at_pcc_mw, v.has_active_power_at_pcc),
                         _optional(v.reactive_power_at_pcc_mvar, v.has_reactive_power_at_pcc),
                         _optional(v.target_active_power_mw, v.has_target_active_power),
                         _optional(v.target_dc_voltage_kv, v.has_target_dc_voltage),
                         _terminal_reference(v.pcc_terminal, v.has_pcc_terminal), droop_curve,
                         _optional(v.droop, v.has_droop),
                         _optional(v.droop_compensation, v.has_droop_compensation),
                         _optional(v.q_share, v.has_q_share),
                         _optional(v.maximum_modulation_index, v.has_maximum_modulation_index),
                         _optional(v.maximum_valve_current_a, v.has_maximum_valve_current),
                         _optional(v.dc_current_a, v.has_dc_current),
                         _optional(v.ac_voltage_kv, v.has_ac_voltage),
                         _optional(v.dc_voltage_kv, v.has_dc_voltage),
                         _optional(v.voltage_regulator_on, v.has_voltage_regulator_on),
                         _optional(v.voltage_setpoint_kv, v.has_voltage_setpoint),
                         _optional(v.reactive_power_setpoint_mvar, v.has_reactive_power_setpoint),
                         _reactive_limits(v.reactive_limits, v.has_reactive_limits, lib, p, i,
                                          properties, points, point_properties),
                         _optional(v.pole_loss_active_power_mw, v.has_pole_loss_active_power),
                         _optional_str(v.reactive_model, v.has_reactive_model),
                         _optional(v.power_factor, v.has_power_factor),
                         _optional_str(v.operating_mode, v.has_operating_mode),
                         _optional(v.rated_dc_current_a, v.has_rated_dc_current),
                         _optional(v.minimum_alpha_degrees, v.has_minimum_alpha),
                         _optional(v.maximum_alpha_degrees, v.has_maximum_alpha),
                         _optional(v.minimum_gamma_degrees, v.has_minimum_gamma),
                         _optional(v.maximum_gamma_degrees, v.has_maximum_gamma),
                         _optional(v.target_alpha_degrees, v.has_target_alpha),
                         _optional(v.target_gamma_degrees, v.has_target_gamma),
                         _optional(v.target_dc_current_a, v.has_target_dc_current),
                         _optional(v.alpha_degrees, v.has_alpha),
                         _optional(v.gamma_degrees, v.has_gamma),
                         _optional(v.delta_degrees, v.has_delta),
                         _optional(v.uf_kv, v.has_uf), _optional(v.uv_kv, v.has_uv))
end

_element(::Type{AcDcConverter}, t::DetailsTable{:voltage_source_converters}, i) =
    _with_details(t) do lib, p
        v = _at(PioAcDcConverterView, Val(:pio_detailed_connectivity_voltage_source_converter_at),
                lib, p, i)
        _ac_dc_converter(v, lib, p, i,
                         Val(:pio_detailed_connectivity_voltage_source_converter_droop_curve_segment_at),
                         Val(:pio_detailed_connectivity_voltage_source_converter_reactive_limit_property_at),
                         Val(:pio_detailed_connectivity_voltage_source_converter_reactive_capability_point_at),
                         Val(:pio_detailed_connectivity_voltage_source_converter_reactive_capability_point_property_at))
    end

_element(::Type{AcDcConverter}, t::DetailsTable{:line_commutated_converters}, i) =
    _with_details(t) do lib, p
        v = _at(PioAcDcConverterView, Val(:pio_detailed_connectivity_line_commutated_converter_at),
                lib, p, i)
        _ac_dc_converter(v, lib, p, i,
                         Val(:pio_detailed_connectivity_line_commutated_converter_droop_curve_segment_at),
                         nothing, nothing, nothing)
    end
