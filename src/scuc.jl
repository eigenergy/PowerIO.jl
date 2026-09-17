# AC SCUC instance inputs: the scheduling data an `AcScucInstance` carries,
# read eagerly into immutable records.
#
# Every record repeats the C view's field names with their units. Rows are
# 1-based and keep source order. Times are hours, powers and energies per
# unit, and phase shifts radians. An absent optional is `nothing`.

using .LibPowerIO: PioScucActiveReservePeriodView, PioScucActiveReserveZoneView,
    PioScucBranchSwitchingCostView, PioScucContingencyComponentView, PioScucContingencyView,
    PioScucDevicePeriodView, PioScucDeviceView, PioScucDimensionsView,
    PioScucEnergyCostBlockView, PioScucEnergyRequirementView, PioScucInitialCommitmentView,
    PioScucRampLimitsView, PioScucReactiveCapabilityView, PioScucReactiveReservePeriodView,
    PioScucReactiveReserveZoneView, PioScucReserveCostsView, PioScucReserveLimitsView,
    PioScucShuntView, PioScucStartupCostAdjustmentView, PioScucStartupLimitView,
    PioScucTransformerControlView, PioScucViolationCostView

# --- records ---------------------------------------------------------------

"""
    ScucRampLimits

Ramp rates of one dispatchable device in per unit per hour: `up_pu_per_hour`
and `down_pu_per_hour` while the device stays on, `startup_pu_per_hour` and
`shutdown_pu_per_hour` across a commitment change.
"""
struct ScucRampLimits
    up_pu_per_hour::Float64
    down_pu_per_hour::Float64
    startup_pu_per_hour::Float64
    shutdown_pu_per_hour::Float64
end

"""
    ScucReserveLimits

The per unit reserve a device can offer in one interval, by reserve product:
regulation, synchronized and nonsynchronized reserve, and ramping reserve
online and offline in each direction.
"""
struct ScucReserveLimits
    regulation_up_pu::Float64
    regulation_down_pu::Float64
    synchronized_pu::Float64
    nonsynchronized_pu::Float64
    ramping_up_online_pu::Float64
    ramping_down_online_pu::Float64
    ramping_up_offline_pu::Float64
    ramping_down_offline_pu::Float64
end

"""
    ScucInitialCommitment

How long a device has already been on or off when the horizon starts, in
hours. Exactly one of the two is positive: the other records the state the
device is not in.
"""
struct ScucInitialCommitment
    accumulated_up_time_hours::Float64
    accumulated_down_time_hours::Float64
end

"""
    ScucReactiveCapability

The reactive capability of one device as a function of its active power.
`kind` selects which fields the input states:

- `"none"`: no coupling, every other field is `nothing`.
- `"linear"`: `reactive_power_at_zero_active_power_pu` and `slope`.
- `"bounded"`: the `_min_pu` and `_max_pu` intercepts and `slope_min` and
  `slope_max`.

A `kind` this release does not model reports `"unknown"` with no fields set.
"""
struct ScucReactiveCapability
    kind::String
    reactive_power_at_zero_active_power_pu::Union{Float64,Nothing}
    reactive_power_at_zero_active_power_min_pu::Union{Float64,Nothing}
    reactive_power_at_zero_active_power_max_pu::Union{Float64,Nothing}
    slope::Union{Float64,Nothing}
    slope_min::Union{Float64,Nothing}
    slope_max::Union{Float64,Nothing}
end

"""
    ScucStartupCostAdjustment

One startup cost tier: `cost` applies when the device has been off for at
most `maximum_down_time_hours`.
"""
struct ScucStartupCostAdjustment
    cost::Float64
    maximum_down_time_hours::Float64
end

"""
    ScucStartupLimit

At most `maximum_startups` starts of one device between `start_time_hours`
and `end_time_hours`.
"""
struct ScucStartupLimit
    start_time_hours::Float64
    end_time_hours::Float64
    maximum_startups::Int
end

"""
    ScucEnergyRequirement

An energy bound of `energy_pu` on one device between `start_time_hours` and
`end_time_hours`. A device carries these separately as upper and as lower
bounds.
"""
struct ScucEnergyRequirement
    start_time_hours::Float64
    end_time_hours::Float64
    energy_pu::Float64
end

"""
    ScucReserveCosts

What one device charges for each reserve product in one interval, per unit of
reserve provided.
"""
struct ScucReserveCosts
    regulation_up::Float64
    regulation_down::Float64
    synchronized::Float64
    nonsynchronized::Float64
    ramping_up_online::Float64
    ramping_down_online::Float64
    ramping_up_offline::Float64
    ramping_down_offline::Float64
    reactive_up::Float64
    reactive_down::Float64
end

"""
    ScucEnergyCostBlock

One block of a piecewise linear energy cost curve: `block_size_pu` of active
power priced at `marginal_cost` per unit.
"""
struct ScucEnergyCostBlock
    marginal_cost::Float64
    block_size_pu::Float64
end

"""
    ScucDevicePeriod

One device in one interval: the commitment status bounds `on_status_min` and
`on_status_max`, the active and reactive power bounds in per unit, the
`energy_cost_blocks` that price its output, and its `reserve_costs`.

`on_status_min == on_status_max` fixes the commitment for that interval.
"""
struct ScucDevicePeriod
    on_status_min::Bool
    on_status_max::Bool
    active_power_min_pu::Float64
    active_power_max_pu::Float64
    reactive_power_min_pu::Float64
    reactive_power_max_pu::Float64
    energy_cost_blocks::Vector{ScucEnergyCostBlock}
    reserve_costs::ScucReserveCosts
end

"""
    ScucDevice

One simple dispatchable device. `kind` is `"producer"` or `"consumer"`.
`on_cost`, `startup_cost`, and `shutdown_cost` price commitment;
`minimum_up_time_hours` and `minimum_down_time_hours` bound how long a
commitment change holds. `periods` carries one [`ScucDevicePeriod`](@ref) per
interval, in chronological order.
"""
struct ScucDevice
    id::ComponentId
    kind::String
    initial_on_status::Bool
    on_cost::Float64
    startup_cost::Float64
    shutdown_cost::Float64
    minimum_up_time_hours::Float64
    minimum_down_time_hours::Float64
    ramp_limits::ScucRampLimits
    reserve_limits::ScucReserveLimits
    initial_commitment::ScucInitialCommitment
    reactive_capability::ScucReactiveCapability
    periods::Vector{ScucDevicePeriod}
    startup_cost_adjustments::Vector{ScucStartupCostAdjustment}
    startup_limits::Vector{ScucStartupLimit}
    energy_upper_bounds::Vector{ScucEnergyRequirement}
    energy_lower_bounds::Vector{ScucEnergyRequirement}
end

"""
    ScucShunt

One switchable shunt: the admittance of a single step in per unit and the
step range `step_min` to `step_max` with its `initial_step`.
"""
struct ScucShunt
    id::ComponentId
    conductance_per_step_pu::Float64
    susceptance_per_step_pu::Float64
    step_min::Int
    step_max::Int
    initial_step::Int
end

"""
    ScucBranchSwitchingCost

What connecting or disconnecting one branch costs.
"""
struct ScucBranchSwitchingCost
    id::ComponentId
    connection_cost::Float64
    disconnection_cost::Float64
end

"""
    ScucTransformerControl

The controllable range of one transformer: its tap ratio bounds and its phase
shift bounds in radians.
"""
struct ScucTransformerControl
    id::ComponentId
    tap_ratio_min::Float64
    tap_ratio_max::Float64
    phase_shift_min_radians::Float64
    phase_shift_max_radians::Float64
end

"""
    ScucActiveReserveZone

One active power reserve zone over `buses`. The requirement fractions scale
the zone's regulation, synchronized, and nonsynchronized requirements from
its load and largest unit; the violation costs price a shortfall of each
product. `ramping_up_requirement_pu` and `ramping_down_requirement_pu` state
the ramping requirement per interval, in chronological order.
"""
struct ScucActiveReserveZone
    id::ComponentId
    buses::Vector{ComponentId}
    regulation_up_requirement_fraction::Float64
    regulation_down_requirement_fraction::Float64
    synchronized_requirement_fraction::Float64
    nonsynchronized_requirement_fraction::Float64
    regulation_up_violation_cost::Float64
    regulation_down_violation_cost::Float64
    synchronized_violation_cost::Float64
    nonsynchronized_violation_cost::Float64
    ramping_up_violation_cost::Float64
    ramping_down_violation_cost::Float64
    ramping_up_requirement_pu::Vector{Float64}
    ramping_down_requirement_pu::Vector{Float64}
end

"""
    ScucReactiveReserveZone

One reactive power reserve zone over `buses`: the cost of falling short in
each direction and the per unit requirement per interval, in chronological
order.
"""
struct ScucReactiveReserveZone
    id::ComponentId
    buses::Vector{ComponentId}
    reactive_up_violation_cost::Float64
    reactive_down_violation_cost::Float64
    reactive_up_requirement_pu::Vector{Float64}
    reactive_down_requirement_pu::Vector{Float64}
end

"""
    ScucContingency

One named contingency: the `components` it takes out of service.
"""
struct ScucContingency
    id::ComponentId
    components::Vector{ComponentId}
end

"""
    ScucViolationCosts

The four penalty prices every AC SCUC instance states: active and reactive
power balance, branch thermal limits, and device energy requirements.
"""
struct ScucViolationCosts
    active_power_balance::Float64
    reactive_power_balance::Float64
    branch_thermal_limit::Float64
    energy_requirement::Float64
end

"""
    ScucInputs

The scheduling inputs of one [`AcScucInstance`](@ref), read through
`instance.inputs`.

- `dimensions`: a `NamedTuple` of collection sizes, such as
  `dimensions.period_count` and `dimensions.device_count`.
- `interval_durations`: the length of each interval in hours, in
  chronological order.
- `devices`, `shunts`, `branch_switching_costs`, `transformer_controls`,
  `active_reserve_zones`, `reactive_reserve_zones`, `contingencies`: the
  input tables in source order.
- `violation_costs`: the instance wide penalty prices.

The tables are plain vectors, so `filter`, `Dict`, and indexing all work. A
lookup by source identity is a `Dict` over the table, as in
`Dict(d.id.local_id => d for d in inputs.devices)`.
"""
struct ScucInputs
    dimensions::NamedTuple
    interval_durations::Vector{Float64}
    devices::Vector{ScucDevice}
    shunts::Vector{ScucShunt}
    branch_switching_costs::Vector{ScucBranchSwitchingCost}
    transformer_controls::Vector{ScucTransformerControl}
    active_reserve_zones::Vector{ScucActiveReserveZone}
    reactive_reserve_zones::Vector{ScucReactiveReserveZone}
    contingencies::Vector{ScucContingency}
    violation_costs::ScucViolationCosts
end

Base.show(io::IO, inputs::ScucInputs) =
    print(io, "ScucInputs(", length(inputs.devices), " devices over ",
          length(inputs.interval_durations), " intervals)")

# --- decoding --------------------------------------------------------------

# A `size_t f(instance, ...)` count taking one or two zero based indices.
_scuc_count(entry, lib, p::Ptr{Cvoid}, i::Integer) =
    Int(@capi lib entry(p, Csize_t(i)))
_scuc_count(entry, lib, p::Ptr{Cvoid}, i::Integer, j::Integer) =
    Int(@capi lib entry(p, Csize_t(i), Csize_t(j)))

_scuc_ramp_limits(v::PioScucRampLimitsView) =
    ScucRampLimits(v.up_pu_per_hour, v.down_pu_per_hour, v.startup_pu_per_hour,
                   v.shutdown_pu_per_hour)

_scuc_reserve_limits(v::PioScucReserveLimitsView) =
    ScucReserveLimits(v.regulation_up_pu, v.regulation_down_pu, v.synchronized_pu,
                      v.nonsynchronized_pu, v.ramping_up_online_pu, v.ramping_down_online_pu,
                      v.ramping_up_offline_pu, v.ramping_down_offline_pu)

_scuc_initial_commitment(v::PioScucInitialCommitmentView) =
    ScucInitialCommitment(v.accumulated_up_time_hours, v.accumulated_down_time_hours)

# The C view always carries all six numbers; `kind` states which of them the
# input holds. The rest read back as `nothing`.
function _scuc_reactive_capability(v::PioScucReactiveCapabilityView)
    kind = _str(v.kind)
    linear = kind == "linear"
    bounded = kind == "bounded"
    return ScucReactiveCapability(kind,
                                  _optional(v.reactive_power_at_zero_active_power_pu, linear),
                                  _optional(v.reactive_power_at_zero_active_power_min_pu, bounded),
                                  _optional(v.reactive_power_at_zero_active_power_max_pu, bounded),
                                  _optional(v.slope, linear),
                                  _optional(v.slope_min, bounded),
                                  _optional(v.slope_max, bounded))
end

_scuc_reserve_costs(v::PioScucReserveCostsView) =
    ScucReserveCosts(v.regulation_up, v.regulation_down, v.synchronized, v.nonsynchronized,
                     v.ramping_up_online, v.ramping_down_online, v.ramping_up_offline,
                     v.ramping_down_offline, v.reactive_up, v.reactive_down)

_scuc_energy_requirement(v::PioScucEnergyRequirementView) =
    ScucEnergyRequirement(v.start_time_hours, v.end_time_hours, v.energy_pu)

function _scuc_device_period(lib, p::Ptr{Cvoid}, i::Integer, j::Integer)
    v = _at(PioScucDevicePeriodView, Val(:pio_ac_scuc_instance_device_period_at), lib, p, i, j)
    n = _scuc_count(Val(:pio_ac_scuc_instance_device_energy_cost_block_count), lib, p, i, j)
    blocks = map(0:n-1) do k
        b = _at(PioScucEnergyCostBlockView,
                Val(:pio_ac_scuc_instance_device_energy_cost_block_at), lib, p, i, j, k)
        ScucEnergyCostBlock(b.marginal_cost, b.block_size_pu)
    end
    return ScucDevicePeriod(v.on_status_min, v.on_status_max, v.active_power_min_pu,
                            v.active_power_max_pu, v.reactive_power_min_pu,
                            v.reactive_power_max_pu, blocks,
                            _scuc_reserve_costs(v.reserve_costs))
end

function _scuc_device(lib, p::Ptr{Cvoid}, i::Integer)
    v = _at(PioScucDeviceView, Val(:pio_ac_scuc_instance_device_at), lib, p, i)
    periods = [_scuc_device_period(lib, p, i, j) for j in 0:Int(v.period_count)-1]
    adjustments = map(0:_scuc_count(Val(:pio_ac_scuc_instance_device_startup_cost_adjustment_count),
                                    lib, p, i)-1) do j
        a = _at(PioScucStartupCostAdjustmentView,
                Val(:pio_ac_scuc_instance_device_startup_cost_adjustment_at), lib, p, i, j)
        ScucStartupCostAdjustment(a.cost, a.maximum_down_time_hours)
    end
    limits = map(0:_scuc_count(Val(:pio_ac_scuc_instance_device_startup_limit_count),
                               lib, p, i)-1) do j
        l = _at(PioScucStartupLimitView, Val(:pio_ac_scuc_instance_device_startup_limit_at),
                lib, p, i, j)
        ScucStartupLimit(l.start_time_hours, l.end_time_hours, Int(l.maximum_startups))
    end
    upper = map(0:_scuc_count(Val(:pio_ac_scuc_instance_device_energy_upper_bound_count),
                              lib, p, i)-1) do j
        _scuc_energy_requirement(_at(PioScucEnergyRequirementView,
                                     Val(:pio_ac_scuc_instance_device_energy_upper_bound_at),
                                     lib, p, i, j))
    end
    lower = map(0:_scuc_count(Val(:pio_ac_scuc_instance_device_energy_lower_bound_count),
                              lib, p, i)-1) do j
        _scuc_energy_requirement(_at(PioScucEnergyRequirementView,
                                     Val(:pio_ac_scuc_instance_device_energy_lower_bound_at),
                                     lib, p, i, j))
    end
    return ScucDevice(_component_id(v.id), _str(v.kind), v.initial_on_status, v.on_cost,
                      v.startup_cost, v.shutdown_cost, v.minimum_up_time_hours,
                      v.minimum_down_time_hours, _scuc_ramp_limits(v.ramp_limits),
                      _scuc_reserve_limits(v.reserve_limits),
                      _scuc_initial_commitment(v.initial_commitment),
                      _scuc_reactive_capability(v.reactive_capability), periods, adjustments,
                      limits, upper, lower)
end

function _scuc_active_reserve_zone(lib, p::Ptr{Cvoid}, i::Integer)
    v = _at(PioScucActiveReserveZoneView, Val(:pio_ac_scuc_instance_active_reserve_zone_at),
            lib, p, i)
    buses = map(0:Int(v.bus_count)-1) do j
        _component_id(_at(PioComponentIdView,
                          Val(:pio_ac_scuc_instance_active_reserve_zone_bus_at), lib, p, i, j))
    end
    n = Int(v.period_count)
    up = Vector{Float64}(undef, n)
    down = Vector{Float64}(undef, n)
    for j in 1:n
        period = _at(PioScucActiveReservePeriodView,
                     Val(:pio_ac_scuc_instance_active_reserve_zone_period_at), lib, p, i, j - 1)
        up[j] = period.ramping_up_requirement_pu
        down[j] = period.ramping_down_requirement_pu
    end
    return ScucActiveReserveZone(_component_id(v.id), buses,
                                 v.regulation_up_requirement_fraction,
                                 v.regulation_down_requirement_fraction,
                                 v.synchronized_requirement_fraction,
                                 v.nonsynchronized_requirement_fraction,
                                 v.regulation_up_violation_cost, v.regulation_down_violation_cost,
                                 v.synchronized_violation_cost, v.nonsynchronized_violation_cost,
                                 v.ramping_up_violation_cost, v.ramping_down_violation_cost,
                                 up, down)
end

function _scuc_reactive_reserve_zone(lib, p::Ptr{Cvoid}, i::Integer)
    v = _at(PioScucReactiveReserveZoneView, Val(:pio_ac_scuc_instance_reactive_reserve_zone_at),
            lib, p, i)
    buses = map(0:Int(v.bus_count)-1) do j
        _component_id(_at(PioComponentIdView,
                          Val(:pio_ac_scuc_instance_reactive_reserve_zone_bus_at), lib, p, i, j))
    end
    n = Int(v.period_count)
    up = Vector{Float64}(undef, n)
    down = Vector{Float64}(undef, n)
    for j in 1:n
        period = _at(PioScucReactiveReservePeriodView,
                     Val(:pio_ac_scuc_instance_reactive_reserve_zone_period_at), lib, p, i, j - 1)
        up[j] = period.reactive_up_requirement_pu
        down[j] = period.reactive_down_requirement_pu
    end
    return ScucReactiveReserveZone(_component_id(v.id), buses, v.reactive_up_violation_cost,
                                   v.reactive_down_violation_cost, up, down)
end

function _scuc_contingency(lib, p::Ptr{Cvoid}, i::Integer)
    v = _at(PioScucContingencyView, Val(:pio_ac_scuc_instance_contingency_at), lib, p, i)
    components = map(0:Int(v.component_count)-1) do j
        c = _at(PioScucContingencyComponentView,
                Val(:pio_ac_scuc_instance_contingency_component_at), lib, p, i, j)
        _component_id(c.id)
    end
    return ScucContingency(_component_id(v.id), components)
end

"""
    instance.inputs

The scheduling inputs of an [`AcScucInstance`](@ref) as a [`ScucInputs`](@ref)
record. Every table is read from the library on access.
"""
function _scuc_inputs(instance::AcScucInstance)
    return _with_handle(instance) do lib, p
        dims = _fill(PioScucDimensionsView, lib) do out, err
            @capi lib :pio_ac_scuc_instance_dimensions(p, out, err)
        end
        names = fieldnames(PioScucDimensionsView)
        dimensions = NamedTuple{names}(map(f -> Int(getfield(dims, f)), names))
        durations = _f64s(@capi lib :pio_ac_scuc_instance_interval_durations(p))
        costs = _fill(PioScucViolationCostView, lib) do out, err
            @capi lib :pio_ac_scuc_instance_violation_costs(p, out, err)
        end
        devices = [_scuc_device(lib, p, i)
                   for i in 0:_count(Val(:pio_ac_scuc_instance_device_count), lib, p)-1]
        shunts = map(0:_count(Val(:pio_ac_scuc_instance_shunt_count), lib, p)-1) do i
            v = _at(PioScucShuntView, Val(:pio_ac_scuc_instance_shunt_at), lib, p, i)
            ScucShunt(_component_id(v.id), v.conductance_per_step_pu, v.susceptance_per_step_pu,
                      Int(v.step_min), Int(v.step_max), Int(v.initial_step))
        end
        switching = map(0:_count(Val(:pio_ac_scuc_instance_branch_switching_cost_count),
                                 lib, p)-1) do i
            v = _at(PioScucBranchSwitchingCostView,
                    Val(:pio_ac_scuc_instance_branch_switching_cost_at), lib, p, i)
            ScucBranchSwitchingCost(_component_id(v.id), v.connection_cost, v.disconnection_cost)
        end
        controls = map(0:_count(Val(:pio_ac_scuc_instance_transformer_control_count),
                                lib, p)-1) do i
            v = _at(PioScucTransformerControlView,
                    Val(:pio_ac_scuc_instance_transformer_control_at), lib, p, i)
            ScucTransformerControl(_component_id(v.id), v.tap_ratio_min, v.tap_ratio_max,
                                   v.phase_shift_min_radians, v.phase_shift_max_radians)
        end
        active = [_scuc_active_reserve_zone(lib, p, i)
                  for i in 0:_count(Val(:pio_ac_scuc_instance_active_reserve_zone_count), lib, p)-1]
        reactive = [_scuc_reactive_reserve_zone(lib, p, i)
                    for i in 0:_count(Val(:pio_ac_scuc_instance_reactive_reserve_zone_count),
                                      lib, p)-1]
        contingencies = [_scuc_contingency(lib, p, i)
                         for i in 0:_count(Val(:pio_ac_scuc_instance_contingency_count), lib, p)-1]
        return ScucInputs(dimensions, durations, devices, shunts, switching, controls, active,
                          reactive, contingencies,
                          ScucViolationCosts(costs.active_power_balance,
                                             costs.reactive_power_balance,
                                             costs.branch_thermal_limit,
                                             costs.energy_requirement))
    end
end
