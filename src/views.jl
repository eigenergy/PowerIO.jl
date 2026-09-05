# Mirrors of the C ABI 7 view structs in `powerio-capi/include/powerio.h`.
#
# Each struct repeats the C declaration field for field, in order, with the
# C type mapped to its Julia counterpart: `size_t` is `Csize_t`, `bool` is
# `Bool`, `double` is `Float64`, `int32_t` is `Int32`, `uint32_t` is `UInt32`,
# `uint8_t` is `UInt8`, `int64_t` is `Int64`, `uint64_t` is `UInt64`. Nested
# views are embedded by value. A field order change in the header must be
# mirrored here; the numeric checks in the test suite catch a mismatch because a
# misaligned struct reads garbage.
#
# Every string is a borrowed (pointer, length) span that is not NUL terminated.
# Every borrowed span is valid while the owning handle is alive; the
# conversion helpers below copy into Julia values before the handle can be
# released.

struct PioStringView
    data::Ptr{UInt8}
    len::Csize_t
end

struct PioSizeView
    data::Ptr{Csize_t}
    len::Csize_t
end

struct PioF64View
    data::Ptr{Float64}
    len::Csize_t
end

struct PioByteView
    data::Ptr{UInt8}
    len::Csize_t
end

struct PioComponentIdView
    component_type::PioStringView
    local_id::PioStringView
end

struct PioTerminalReferenceView
    equipment::PioComponentIdView
    terminal::UInt8
end

struct PioDiagnosticSpanView
    source::PioStringView
    byte_start::UInt64
    byte_end::UInt64
end

struct PioSourceSpanView
    source::PioStringView
    byte_start::UInt64
    byte_end::UInt64
end

# --- module records ------------------------------------------------------

struct PioModuleProducerView
    name::PioStringView
    version::PioStringView
end

struct PioModuleSourceView
    id::PioStringView
    name::PioStringView
    byte_length::UInt64
    format::PioStringView
    has_format::Bool
    digest_algorithm::PioStringView
    digest::PioStringView
    has_digest::Bool
end

struct PioModuleSourceMapEntryView
    target::PioStringView
    relation::PioStringView
    span_count::Csize_t
end

struct PioModuleHistoryEntryView
    id::PioStringView
    kind::PioStringView
    name::PioStringView
    input_type::PioStringView
    has_input_type::Bool
    output_type::PioStringView
    has_output_type::Bool
    parameter_count::Csize_t
    assumption_count::Csize_t
    loss_count::Csize_t
end

struct PioModuleHistoryParameterView
    name::PioStringView
    value_kind::PioStringView
end

struct PioModuleExtensionView
    namespace::PioStringView
    value_kind::PioStringView
end

struct PioJsonValueView
    kind::PioStringView
    boolean_value::Bool
    number_kind::PioStringView
    signed_integer_value::Int64
    unsigned_integer_value::UInt64
    floating_point_value::Float64
    string_value::PioStringView
    element_count::Csize_t
end

struct PioJsonObjectEntryView
    key::PioStringView
    value_kind::PioStringView
end

# --- balanced network -----------------------------------------------------

struct PioBalancedGeoView
    has_geo::Bool
    space::PioStringView
    crs::PioStringView
    has_crs::Bool
    kind::PioStringView
    has_kind::Bool
    has_canvas::Bool
    canvas_width::Float64
    has_canvas_width::Bool
    canvas_height::Float64
    has_canvas_height::Bool
    canvas_units::PioStringView
    has_canvas_units::Bool
end

struct PioBalancedLocationView
    x::Float64
    y::Float64
    kind::PioStringView
    has_kind::Bool
end

struct PioBalancedBusView
    component_id::PioStringView
    has_component_id::Bool
    id::Csize_t
    bus_type::PioStringView
    vm_pu::Float64
    va_degrees::Float64
    base_kv::Float64
    vmax_pu::Float64
    vmin_pu::Float64
    has_emergency_voltage_limits::Bool
    emergency_vmax_pu::Float64
    emergency_vmin_pu::Float64
    area::Csize_t
    zone::Csize_t
    name::PioStringView
    has_name::Bool
    location::PioBalancedLocationView
    has_location::Bool
end

struct PioBalancedLoadVoltageModelView
    kind::PioStringView
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
    nominal_voltage_pu::Float64
    has_nominal_voltage::Bool
    load_type::Int32
    has_load_type::Bool
    scaling::Float64
    has_scaling::Bool
end

struct PioBalancedLoadView
    component_id::PioStringView
    has_component_id::Bool
    bus_id::Csize_t
    p_mw::Float64
    q_mvar::Float64
    in_service::Bool
    voltage_model::PioBalancedLoadVoltageModelView
end

struct PioBalancedShuntView
    component_id::PioStringView
    has_component_id::Bool
    bus_id::Csize_t
    conductance_mw::Float64
    susceptance_mvar::Float64
    in_service::Bool
    section_count::UInt32
    has_section_count::Bool
    has_control::Bool
    control_mode::PioStringView
    control_vmax_pu::Float64
    control_vmin_pu::Float64
    control_bus_id::Csize_t
    has_control_bus::Bool
    control_reactive_range_percent::Float64
    control_block_count::Csize_t
end

struct PioShuntBlockView
    steps::UInt32
    conductance_mw::Float64
    susceptance_mvar::Float64
end

struct PioBalancedStaticVarCompensatorView
    component_id::PioStringView
    has_component_id::Bool
    bus_id::Csize_t
    minimum_susceptance_siemens::Float64
    maximum_susceptance_siemens::Float64
    voltage_setpoint_kv::Float64
    reactive_power_setpoint_mvar::Float64
    regulation_mode::PioStringView
    regulating::Bool
    regulating_terminal::PioTerminalReferenceView
    has_regulating_terminal::Bool
    active_power_mw::Float64
    reactive_power_mvar::Float64
    in_service::Bool
end

struct PioTransformerControlView
    mode::PioStringView
    enabled::Bool
    controlled_bus_id::Csize_t
    has_controlled_bus::Bool
    controlled_bus_on_winding_side::Bool
    regulating_terminal::PioTerminalReferenceView
    has_regulating_terminal::Bool
    tap_min::Float64
    tap_max::Float64
    band_min::Float64
    band_max::Float64
    tap_position_count::UInt32
    mva_base::Float64
    winding_connection_angle::Float64
    has_winding_connection_angle::Bool
end

struct PioBalancedBranchView
    component_id::PioStringView
    has_component_id::Bool
    name::PioStringView
    has_name::Bool
    from_bus_id::Csize_t
    to_bus_id::Csize_t
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
    additional_rating_count::Csize_t
    has_current_ratings::Bool
    current_rating_a::Float64
    current_rating_b::Float64
    current_rating_c::Float64
    tap_ratio::Float64
    effective_tap_ratio::Float64
    phase_shift_degrees::Float64
    in_service::Bool
    angle_min_degrees::Float64
    angle_max_degrees::Float64
    control::PioTransformerControlView
    has_control::Bool
    route_point_count::Csize_t
    has_route::Bool
end

struct PioBranchRatingView
    name::PioStringView
    rate_mva::Float64
end

struct PioGeneratorCostView
    model::UInt8
    startup::Float64
    shutdown::Float64
    ncost::Csize_t
    coefficients::PioF64View
end

struct PioActivePowerControlView
    participate::Bool
    droop_percent::Float64
    has_droop_percent::Bool
    participation_factor::Float64
    has_participation_factor::Bool
    minimum_target_active_power_mw::Float64
    has_minimum_target_active_power::Bool
    maximum_target_active_power_mw::Float64
    has_maximum_target_active_power::Bool
end

struct PioBalancedGeneratorView
    component_id::PioStringView
    has_component_id::Bool
    bus_id::Csize_t
    energy_source::PioStringView
    active_power_mw::Float64
    reactive_power_mvar::Float64
    active_power_max_mw::Float64
    active_power_min_mw::Float64
    reactive_power_max_mvar::Float64
    reactive_power_min_mvar::Float64
    voltage_setpoint_pu::Float64
    machine_base_mva::Float64
    in_service::Bool
    has_cost::Bool
    cost::PioGeneratorCostView
    regulated_bus_id::Csize_t
    has_regulated_bus::Bool
    capability_count::Csize_t
    active_power_control::PioActivePowerControlView
    has_active_power_control::Bool
    voltage_regulation_on::Bool
    regulating_terminal::PioTerminalReferenceView
    has_regulating_terminal::Bool
end

struct PioGeneratorCapabilityView
    name::PioStringView
    value::Float64
    has_value::Bool
end

struct PioBalancedStorageView
    component_id::PioStringView
    has_component_id::Bool
    bus_id::Csize_t
    active_power_mw::Float64
    reactive_power_mvar::Float64
    energy_mwh::Float64
    energy_rating_mwh::Float64
    charge_rating_mw::Float64
    discharge_rating_mw::Float64
    charge_efficiency::Float64
    discharge_efficiency::Float64
    thermal_rating_mva::Float64
    current_rating::Float64
    has_current_rating::Bool
    reactive_power_min_mvar::Float64
    reactive_power_max_mvar::Float64
    resistance_pu::Float64
    reactance_pu::Float64
    active_power_loss_mw::Float64
    reactive_power_loss_mvar::Float64
    in_service::Bool
    active_power_control::PioActivePowerControlView
    has_active_power_control::Bool
end

struct PioBalancedSwitchView
    component_id::PioStringView
    has_component_id::Bool
    from_bus_id::Csize_t
    to_bus_id::Csize_t
    closed::Bool
    thermal_rating_mva::Float64
    has_thermal_rating::Bool
    current_rating_a::Float64
    has_current_rating::Bool
    from_active_power_mw::Float64
    has_from_active_power::Bool
    from_reactive_power_mvar::Float64
    has_from_reactive_power::Bool
    to_active_power_mw::Float64
    has_to_active_power::Bool
    to_reactive_power_mvar::Float64
    has_to_reactive_power::Bool
end

struct PioBalancedHvdcConverterView
    component::PioComponentIdView
    kind::PioStringView
    loss_factor_percent::Float64
    voltage_regulator_on::Bool
    has_voltage_regulator_on::Bool
    voltage_setpoint_kv::Float64
    has_voltage_setpoint::Bool
    reactive_power_setpoint_mvar::Float64
    has_reactive_power_setpoint::Bool
    power_factor::Float64
    has_power_factor::Bool
    regulating_terminal::PioTerminalReferenceView
    has_regulating_terminal::Bool
end

struct PioBalancedHvdcView
    component_id::PioStringView
    has_component_id::Bool
    from_bus_id::Csize_t
    to_bus_id::Csize_t
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
    resistance_ohm::Float64
    has_resistance::Bool
    nominal_voltage_kv::Float64
    has_nominal_voltage::Bool
    converters_mode::PioStringView
    has_converters_mode::Bool
    converter1::PioBalancedHvdcConverterView
    has_converter1::Bool
    converter2::PioBalancedHvdcConverterView
    has_converter2::Bool
    cost::PioGeneratorCostView
    has_cost::Bool
end

struct PioBalancedThreeWindingTransformerView
    component_id::PioStringView
    has_component_id::Bool
    name::PioStringView
    has_name::Bool
    winding_count::Csize_t
    impedance_count::Csize_t
    star_voltage_magnitude_pu::Float64
    star_voltage_angle_degrees::Float64
    magnetizing_conductance_pu::Float64
    magnetizing_susceptance_pu::Float64
    in_service::Bool
end

struct PioThreeWindingTransformerWindingView
    bus_id::Csize_t
    tap_ratio::Float64
    phase_shift_degrees::Float64
    nominal_voltage_kv::Float64
    rating_a_mva::Float64
    rating_b_mva::Float64
    rating_c_mva::Float64
    control::PioTransformerControlView
    has_control::Bool
end

struct PioThreeWindingTransformerImpedanceView
    resistance_pu::Float64
    reactance_pu::Float64
    base_mva::Float64
end

struct PioBalancedAreaView
    number::Csize_t
    slack_bus_id::Csize_t
    has_slack_bus::Bool
    net_interchange_mw::Float64
    tolerance_mw::Float64
    name::PioStringView
    has_name::Bool
    component_id::PioStringView
    has_component_id::Bool
    area_type::PioStringView
    has_area_type::Bool
end

struct PioDetailedConnectivityCountsView
    omitted_fields::Csize_t
    component_metadata::Csize_t
    subnetworks::Csize_t
    substations::Csize_t
    voltage_levels::Csize_t
    bus_breaker_buses::Csize_t
    calculated_buses::Csize_t
    connectivity_nodes::Csize_t
    busbar_sections::Csize_t
    junctions::Csize_t
    terminals::Csize_t
    switches::Csize_t
    internal_connections::Csize_t
    operational_limit_groups::Csize_t
    tap_changers::Csize_t
    equipment_reactive_limits::Csize_t
    boundary_lines::Csize_t
    tie_lines::Csize_t
    dc_converter_units::Csize_t
    dc_topological_nodes::Csize_t
    dc_nodes::Csize_t
    dc_grounds::Csize_t
    dc_busbars::Csize_t
    dc_lines::Csize_t
    dc_series_devices::Csize_t
    dc_switches::Csize_t
    voltage_source_converters::Csize_t
    line_commutated_converters::Csize_t
end

# --- multiconductor network -----------------------------------------------

struct PioMulticonductorGeoView
    has_geo::Bool
    space::PioStringView
    crs::PioStringView
    has_crs::Bool
    kind::PioStringView
    has_kind::Bool
    has_canvas::Bool
    canvas_width::Float64
    has_canvas_width::Bool
    canvas_height::Float64
    has_canvas_height::Bool
    canvas_units::PioStringView
    has_canvas_units::Bool
end

struct PioMulticonductorNetworkCountsView
    buses::Csize_t
    line_codes::Csize_t
    lines::Csize_t
    switches::Csize_t
    transformers::Csize_t
    loads::Csize_t
    generators::Csize_t
    inverter_based_resources::Csize_t
    control_profiles::Csize_t
    shunts::Csize_t
    capacitors::Csize_t
    voltage_sources::Csize_t
    untyped_objects::Csize_t
    commands::Csize_t
    options::Csize_t
end

struct PioMulticonductorLocationView
    x::Float64
    y::Float64
    kind::PioStringView
    has_kind::Bool
end

struct PioMulticonductorBusView
    id::PioStringView
    terminal_count::Csize_t
    grounded_terminal_count::Csize_t
    voltage_min_v::Float64
    has_voltage_min::Bool
    voltage_max_v::Float64
    has_voltage_max::Bool
    phase_to_ground_voltage_min_v::PioF64View
    has_phase_to_ground_voltage_min::Bool
    phase_to_ground_voltage_max_v::PioF64View
    has_phase_to_ground_voltage_max::Bool
    phase_to_neutral_voltage_min_v::PioF64View
    has_phase_to_neutral_voltage_min::Bool
    phase_to_neutral_voltage_max_v::PioF64View
    has_phase_to_neutral_voltage_max::Bool
    phase_to_phase_voltage_min_v::PioF64View
    has_phase_to_phase_voltage_min::Bool
    phase_to_phase_voltage_max_v::PioF64View
    has_phase_to_phase_voltage_max::Bool
    positive_sequence_voltage_min_v::Float64
    has_positive_sequence_voltage_min::Bool
    positive_sequence_voltage_max_v::Float64
    has_positive_sequence_voltage_max::Bool
    negative_sequence_voltage_max_v::Float64
    has_negative_sequence_voltage_max::Bool
    zero_sequence_voltage_max_v::Float64
    has_zero_sequence_voltage_max::Bool
    neutral_to_ground_voltage_max_v::Float64
    has_neutral_to_ground_voltage_max::Bool
    location::PioMulticonductorLocationView
    has_location::Bool
end

struct PioMulticonductorLineCodeView
    name::PioStringView
    conductor_count::Csize_t
    resistance_matrix_row_count::Csize_t
    reactance_matrix_row_count::Csize_t
    conductance_from_matrix_row_count::Csize_t
    susceptance_from_matrix_row_count::Csize_t
    conductance_to_matrix_row_count::Csize_t
    susceptance_to_matrix_row_count::Csize_t
    current_limit_a::PioF64View
    has_current_limit::Bool
    apparent_power_limit_va::PioF64View
    has_apparent_power_limit::Bool
    source::PioStringView
    has_source::Bool
end

struct PioMulticonductorLineView
    name::PioStringView
    bus_from::PioStringView
    bus_to::PioStringView
    terminal_map_from_count::Csize_t
    terminal_map_to_count::Csize_t
    line_code::PioStringView
    length_m::Float64
    route_point_count::Csize_t
    has_route::Bool
    current_limit_a::PioF64View
    has_current_limit::Bool
    apparent_power_limit_va::PioF64View
    has_apparent_power_limit::Bool
end

struct PioMulticonductorSwitchView
    name::PioStringView
    bus_from::PioStringView
    bus_to::PioStringView
    terminal_map_from_count::Csize_t
    terminal_map_to_count::Csize_t
    open::Bool
    current_limit_a::PioF64View
    has_current_limit::Bool
end

struct PioMulticonductorTransformerView
    name::PioStringView
    winding_count::Csize_t
    short_circuit_reactance_percent::PioF64View
    phase_count::Csize_t
end

struct PioMulticonductorTransformerWindingView
    bus::PioStringView
    terminal_map_count::Csize_t
    connection::PioStringView
    rated_voltage_v::Float64
    apparent_power_rating_va::Float64
    resistance_percent::Float64
    tap::Float64
    neutral_resistance_ohm::Float64
    has_neutral_resistance::Bool
    neutral_reactance_ohm::Float64
    has_neutral_reactance::Bool
end

struct PioMulticonductorLoadView
    name::PioStringView
    bus::PioStringView
    terminal_map_count::Csize_t
    configuration::PioStringView
    active_power_nominal_w::PioF64View
    reactive_power_nominal_var::PioF64View
    voltage_model::PioStringView
    nominal_voltage_v::PioF64View
    active_power_constant_impedance::PioF64View
    active_power_constant_current::PioF64View
    active_power_constant_power::PioF64View
    reactive_power_constant_impedance::PioF64View
    reactive_power_constant_current::PioF64View
    reactive_power_constant_power::PioF64View
    active_power_exponent::PioF64View
    reactive_power_exponent::PioF64View
end

struct PioMulticonductorGeneratorView
    name::PioStringView
    bus::PioStringView
    terminal_map_count::Csize_t
    configuration::PioStringView
    active_power_nominal_w::PioF64View
    reactive_power_nominal_var::PioF64View
    active_power_min_w::PioF64View
    has_active_power_min::Bool
    active_power_max_w::PioF64View
    has_active_power_max::Bool
    reactive_power_min_var::PioF64View
    has_reactive_power_min::Bool
    reactive_power_max_var::PioF64View
    has_reactive_power_max::Bool
    active_power_dispatch_cost_per_kwh::PioF64View
    has_active_power_dispatch_cost::Bool
    apparent_power_limit_va::PioF64View
    has_apparent_power_limit::Bool
    current_limit_a::PioF64View
    has_current_limit::Bool
end

struct PioInverterBasedResourceView
    name::PioStringView
    bus::PioStringView
    terminal_map_count::Csize_t
    topology::PioStringView
    prime_mover::PioStringView
    apparent_power_limit_va::PioF64View
    current_limit_a::PioF64View
    has_current_limit::Bool
    active_power_available_w::Float64
    has_active_power_available::Bool
    active_power_min_w::PioF64View
    has_active_power_min::Bool
    active_power_max_w::PioF64View
    has_active_power_max::Bool
    reactive_power_min_var::PioF64View
    has_reactive_power_min::Bool
    reactive_power_max_var::PioF64View
    has_reactive_power_max::Bool
    control_profile::PioStringView
    has_control_profile::Bool
    voltage_aggregation::PioStringView
    has_voltage_aggregation::Bool
end

struct PioControlProfileView
    name::PioStringView
    has_power_factor::Bool
    power_factor::Float64
    has_volt_var::Bool
    volt_var_voltage_reference::PioStringView
    has_volt_var_voltage_reference::Bool
    volt_var_breakpoints::PioF64View
    volt_var_reactive_power_limits::PioF64View
    volt_var_reactive_power_unit::PioStringView
    has_volt_var_reactive_power_unit::Bool
    volt_var_reactive_power_reference::PioStringView
    has_volt_var_reactive_power_reference::Bool
    volt_var_active_power_min_for_reactive_power_w::Float64
    has_volt_var_active_power_min_for_reactive_power::Bool
    volt_var_active_power_min_for_max_reactive_power_w::Float64
    has_volt_var_active_power_min_for_max_reactive_power::Bool
    has_volt_watt::Bool
    volt_watt_voltage_reference::PioStringView
    has_volt_watt_voltage_reference::Bool
    volt_watt_breakpoints::PioF64View
    volt_watt_active_power_limits::PioF64View
    volt_watt_active_power_unit::PioStringView
    has_volt_watt_active_power_unit::Bool
    volt_watt_active_power_reference::PioStringView
    has_volt_watt_active_power_reference::Bool
end

struct PioMulticonductorShuntView
    name::PioStringView
    bus::PioStringView
    terminal_map_count::Csize_t
    conductance_matrix_row_count::Csize_t
    susceptance_matrix_row_count::Csize_t
end

struct PioMulticonductorCapacitorView
    name::PioStringView
    bus::PioStringView
    terminal_map_count::Csize_t
    configuration::PioStringView
    rated_reactive_power_var::Float64
    nominal_voltage_v::Float64
end

struct PioVoltageSourceView
    name::PioStringView
    bus::PioStringView
    terminal_map_count::Csize_t
    voltage_magnitude_v::PioF64View
    voltage_angle_rad::PioF64View
end

struct PioMulticonductorUntypedObjectView
    class_name::PioStringView
    name::PioStringView
    property_count::Csize_t
end

struct PioMulticonductorUntypedPropertyView
    name::PioStringView
    has_name::Bool
    value::PioStringView
end

struct PioMulticonductorCommandView
    verb::PioStringView
    args::PioStringView
end

struct PioStringPropertyView
    name::PioStringView
    value::PioStringView
end

# --- conversions ----------------------------------------------------------

# Copy a borrowed string span into an owned `String`. An empty span is "".
function _str(v::PioStringView)
    (v.data == C_NULL || v.len == 0) && return ""
    return unsafe_string(v.data, Int(v.len))
end

# `nothing` when the presence flag is false, the copied string otherwise.
_optional_str(v::PioStringView, present::Bool) = present ? _str(v) : nothing

_optional(value, present::Bool) = present ? value : nothing

# Copy a borrowed double span into an owned vector.
function _f64s(v::PioF64View)
    (v.data == C_NULL || v.len == 0) && return Float64[]
    return copy(unsafe_wrap(Vector{Float64}, v.data, Int(v.len)))
end

_optional_f64s(v::PioF64View, present::Bool) = present ? _f64s(v) : nothing

# Copy a borrowed size span into an owned `Vector{Int}`.
function _sizes(v::PioSizeView)
    (v.data == C_NULL || v.len == 0) && return Int[]
    return Int.(unsafe_wrap(Vector{Csize_t}, v.data, Int(v.len)))
end

# Copy a borrowed byte span into an owned vector.
function _bytes(v::PioByteView)
    (v.data == C_NULL || v.len == 0) && return UInt8[]
    return copy(unsafe_wrap(Vector{UInt8}, v.data, Int(v.len)))
end
