# Typed updates: quantities with explicit units, update constructors, and
# `apply_updates!`.

# --- quantities -----------------------------------------------------------------

"""
    ActivePower(; watts) or ActivePower(; megawatts)

Active power with an explicit unit.
"""
struct ActivePower
    value::Float64
    unit::Symbol
    function ActivePower(; watts=nothing, megawatts=nothing)
        (watts === nothing) == (megawatts === nothing) &&
            throw(ArgumentError("ActivePower takes exactly one of watts or megawatts"))
        return watts === nothing ? new(Float64(megawatts), :megawatts) : new(Float64(watts), :watts)
    end
end

"""
    ReactivePower(; vars) or ReactivePower(; megavars)

Reactive power with an explicit unit.
"""
struct ReactivePower
    value::Float64
    unit::Symbol
    function ReactivePower(; vars=nothing, megavars=nothing)
        (vars === nothing) == (megavars === nothing) &&
            throw(ArgumentError("ReactivePower takes exactly one of vars or megavars"))
        return vars === nothing ? new(Float64(megavars), :megavars) : new(Float64(vars), :vars)
    end
end

"""
    ApparentPower(; volt_amperes) or ApparentPower(; megavolt_amperes)

Apparent power with an explicit unit.
"""
struct ApparentPower
    value::Float64
    unit::Symbol
    function ApparentPower(; volt_amperes=nothing, megavolt_amperes=nothing)
        (volt_amperes === nothing) == (megavolt_amperes === nothing) &&
            throw(ArgumentError("ApparentPower takes exactly one of volt_amperes or megavolt_amperes"))
        return volt_amperes === nothing ? new(Float64(megavolt_amperes), :megavolt_amperes) :
                                          new(Float64(volt_amperes), :volt_amperes)
    end
end

Base.show(io::IO, p::ActivePower) = print(io, "ActivePower(", p.unit, "=", p.value, ")")
Base.show(io::IO, p::ReactivePower) = print(io, "ReactivePower(", p.unit, "=", p.value, ")")
Base.show(io::IO, p::ApparentPower) = print(io, "ApparentPower(", p.unit, "=", p.value, ")")

function _quantity_handle(lib, p::ActivePower)
    ptr = p.unit === :watts ? @capi(lib, :pio_active_power_from_watts(p.value)) :
                              @capi(lib, :pio_active_power_from_megawatts(p.value))
    return ActivePowerHandle(ptr, lib)
end

function _quantity_handle(lib, p::ReactivePower)
    ptr = p.unit === :vars ? @capi(lib, :pio_reactive_power_from_vars(p.value)) :
                             @capi(lib, :pio_reactive_power_from_megavars(p.value))
    return ReactivePowerHandle(ptr, lib)
end

function _quantity_handle(lib, p::ApparentPower)
    ptr = p.unit === :volt_amperes ?
          @capi(lib, :pio_apparent_power_from_volt_amperes(p.value)) :
          @capi(lib, :pio_apparent_power_from_megavolt_amperes(p.value))
    return ApparentPowerHandle(ptr, lib)
end

function _component_handle(lib, id::ComponentId)
    ptr = _checked(lib) do err
        @capi lib :pio_component_id_new(id.component_type, sizeof(id.component_type), id.local_id,
                                        sizeof(id.local_id), err)
    end
    return ComponentIdHandle(ptr, lib)
end

# --- updates ----------------------------------------------------------------------

"""
    OperatingPointUpdate

One change to operating data: a load or generator setpoint, a service status,
a transformer tap or phase shift, or a switch position. Construct one with
[`set_load_active_power`](@ref) and the other `set_*` functions, then apply a
batch with [`apply_updates!`](@ref).
"""
struct OperatingPointUpdate
    handle::OperatingPointUpdateHandle
    description::String
end

"""
    NetworkUpdate

One change to network data. `set_branch_thermal_rating` is the network update
in this release.
"""
struct NetworkUpdate
    handle::NetworkUpdateHandle
    description::String
end

Base.show(io::IO, u::OperatingPointUpdate) = print(io, "OperatingPointUpdate(", u.description, ")")
Base.show(io::IO, u::NetworkUpdate) = print(io, "NetworkUpdate(", u.description, ")")

const _NO_TERMINAL = ""

# Build an operating point update whose C constructor takes a component, an
# optional terminal, and a quantity handle.
function _power_update(entry, id::ComponentId, power, terminal, description)
    lib = _checked_lib()
    component = _component_handle(lib, id)
    quantity = _quantity_handle(lib, power)
    term = terminal === nothing ? _NO_TERMINAL : String(terminal)
    ptr = @with_handles component quantity term _checked(lib) do err
        @capi lib entry(_ptr(component), terminal === nothing ? C_NULL : pointer(term),
                      terminal === nothing ? Csize_t(0) : Csize_t(sizeof(term)), _ptr(quantity), err)
    end
    release!(component)
    release!(quantity)
    return ptr, lib
end

# Build an operating point update whose C constructor takes a component and
# one `double` or one `bool`.
function _scalar_update(entry, id::ComponentId, value::Float64)
    lib = _checked_lib()
    component = _component_handle(lib, id)
    ptr = @with_handles component _checked(lib) do err
        @capi lib entry(_ptr(component), value, err)
    end
    release!(component)
    return ptr, lib
end
function _scalar_update(entry, id::ComponentId, value::Bool)
    lib = _checked_lib()
    component = _component_handle(lib, id)
    ptr = @with_handles component _checked(lib) do err
        @capi lib entry(_ptr(component), value, err)
    end
    release!(component)
    return ptr, lib
end

_describe(id::ComponentId) = id.component_type * " " * id.local_id

"""
    set_load_active_power(id::ComponentId, power::ActivePower; terminal=nothing)

An update that sets a load's active power. `terminal` selects one terminal
of a multiconductor load.
"""
function set_load_active_power(id::ComponentId, power::ActivePower; terminal=nothing)
    ptr, lib = _power_update(Val(:pio_operating_point_update_set_load_active_power), id, power, terminal, "")
    return OperatingPointUpdate(OperatingPointUpdateHandle(ptr, lib), "$(_describe(id)) active power $power")
end

"""
    set_load_reactive_power(id::ComponentId, power::ReactivePower; terminal=nothing)

An update that sets a load's reactive power.
"""
function set_load_reactive_power(id::ComponentId, power::ReactivePower; terminal=nothing)
    ptr, lib = _power_update(Val(:pio_operating_point_update_set_load_reactive_power), id, power, terminal, "")
    return OperatingPointUpdate(OperatingPointUpdateHandle(ptr, lib), "$(_describe(id)) reactive power $power")
end

"""
    set_generator_active_power(id::ComponentId, power::ActivePower; terminal=nothing)

An update that sets a generator's active power setpoint.
"""
function set_generator_active_power(id::ComponentId, power::ActivePower; terminal=nothing)
    ptr, lib = _power_update(Val(:pio_operating_point_update_set_generator_active_power), id, power, terminal, "")
    return OperatingPointUpdate(OperatingPointUpdateHandle(ptr, lib), "$(_describe(id)) active power $power")
end

"""
    set_generator_reactive_power(id::ComponentId, power::ReactivePower; terminal=nothing)

An update that sets a generator's reactive power setpoint.
"""
function set_generator_reactive_power(id::ComponentId, power::ReactivePower; terminal=nothing)
    ptr, lib = _power_update(Val(:pio_operating_point_update_set_generator_reactive_power), id, power, terminal, "")
    return OperatingPointUpdate(OperatingPointUpdateHandle(ptr, lib), "$(_describe(id)) reactive power $power")
end

"""
    set_generator_voltage_magnitude(id::ComponentId, vm_pu::Real)

An update that sets a generator's voltage setpoint in per unit.
"""
function set_generator_voltage_magnitude(id::ComponentId, vm_pu::Real)
    ptr, lib = _scalar_update(Val(:pio_operating_point_update_set_generator_voltage_magnitude), id, Float64(vm_pu))
    return OperatingPointUpdate(OperatingPointUpdateHandle(ptr, lib), "$(_describe(id)) voltage $vm_pu pu")
end

"""
    set_generator_in_service(id::ComponentId, in_service::Bool)

An update that sets a generator's service status.
"""
function set_generator_in_service(id::ComponentId, in_service::Bool)
    ptr, lib = _scalar_update(Val(:pio_operating_point_update_set_generator_in_service), id, in_service)
    return OperatingPointUpdate(OperatingPointUpdateHandle(ptr, lib), "$(_describe(id)) in service $in_service")
end

"""
    set_branch_in_service(id::ComponentId, in_service::Bool)

An update that sets a branch's service status.
"""
function set_branch_in_service(id::ComponentId, in_service::Bool)
    ptr, lib = _scalar_update(Val(:pio_operating_point_update_set_branch_in_service), id, in_service)
    return OperatingPointUpdate(OperatingPointUpdateHandle(ptr, lib), "$(_describe(id)) in service $in_service")
end

"""
    set_transformer_tap_ratio(id::ComponentId, tap_ratio::Real)

An update that sets a transformer branch's tap ratio.
"""
function set_transformer_tap_ratio(id::ComponentId, tap_ratio::Real)
    ptr, lib = _scalar_update(Val(:pio_operating_point_update_set_transformer_tap_ratio), id, Float64(tap_ratio))
    return OperatingPointUpdate(OperatingPointUpdateHandle(ptr, lib), "$(_describe(id)) tap ratio $tap_ratio")
end

"""
    set_transformer_phase_shift_degrees(id::ComponentId, degrees::Real)

An update that sets a transformer branch's phase shift.
"""
function set_transformer_phase_shift_degrees(id::ComponentId, degrees::Real)
    ptr, lib = _scalar_update(Val(:pio_operating_point_update_set_transformer_phase_shift_degrees), id, Float64(degrees))
    return OperatingPointUpdate(OperatingPointUpdateHandle(ptr, lib), "$(_describe(id)) phase shift $degrees deg")
end

"""
    set_switch_closed(id::ComponentId, closed::Bool)

An update that sets a switch position.
"""
function set_switch_closed(id::ComponentId, closed::Bool)
    ptr, lib = _scalar_update(Val(:pio_operating_point_update_set_switch_closed), id, closed)
    return OperatingPointUpdate(OperatingPointUpdateHandle(ptr, lib), "$(_describe(id)) closed $closed")
end

"""
    set_branch_thermal_rating(id::ComponentId, rating::ApparentPower; terminal=nothing)

A network update that sets a branch's thermal rating.
"""
function set_branch_thermal_rating(id::ComponentId, rating::ApparentPower; terminal=nothing)
    ptr, lib = _power_update(Val(:pio_network_update_set_branch_thermal_rating), id, rating, terminal, "")
    return NetworkUpdate(NetworkUpdateHandle(ptr, lib), "$(_describe(id)) thermal rating $rating")
end

# --- apply -----------------------------------------------------------------------

"""
    UpdateChange(component_id, field, terminal)

One change an applied batch made: the component, the field name such as
`"load_active_power"` or `"branch_thermal_rating"`, and the terminal when the
change targeted one.
"""
struct UpdateChange
    component_id::ComponentId
    field::String
    terminal::Union{String,Nothing}
end

"""
    UpdateReport

What [`apply_updates!`](@ref) changed: `changes::Vector{UpdateChange}` and
`connectivity_changed`, true when a service status or switch change altered
the energized topology. `length(report)` is the number of changes.
"""
struct UpdateReport
    changes::Vector{UpdateChange}
    connectivity_changed::Bool
end

Base.length(r::UpdateReport) = length(r.changes)
Base.isempty(r::UpdateReport) = isempty(r.changes)
Base.iterate(r::UpdateReport, state...) = iterate(r.changes, state...)
Base.getindex(r::UpdateReport, i::Integer) = r.changes[i]

function _calculation_update(lib, u::OperatingPointUpdate)
    h = u.handle
    _require_library(lib, h)
    ptr = @with_handles h _checked(lib) do err
        @capi lib :pio_calculation_update_from_operating_point(_ptr(h), err)
    end
    return CalculationUpdateHandle(ptr, lib)
end
function _calculation_update(lib, u::NetworkUpdate)
    h = u.handle
    _require_library(lib, h)
    ptr = @with_handles h _checked(lib) do err
        @capi lib :pio_calculation_update_from_network(_ptr(h), err)
    end
    return CalculationUpdateHandle(ptr, lib)
end
_calculation_update(lib, u) = throw(ArgumentError(
    "PowerIO.apply_updates!: updates must be OperatingPointUpdate or NetworkUpdate values, got $(typeof(u))"))

"""
    apply_updates!(m::PioModule, updates) -> UpdateReport

Validate the whole batch of [`OperatingPointUpdate`](@ref) and
[`NetworkUpdate`](@ref) values, then apply it atomically. A failed batch
throws [`PowerIOError`](@ref) and leaves the module unchanged. On success
`m.value` is refreshed; values obtained before the call keep the pre-update
data.

Calls sharing the module handle are synchronized through mutation and value
refresh. Values already obtained from `m` retain their pre-update data and
remain independently readable.
"""
function apply_updates!(m::PioModule, updates)
    lib = _lib_of(m)
    inputs = collect(updates)
    handles = CalculationUpdateHandle[]
    try
        for u in inputs
            push!(handles, _calculation_update(lib, u))
        end
        mh = _handle(m)
        return @with_handles mh handles begin
            ptrs = Ptr{Cvoid}[_ptr(h) for h in handles]
            report_ptr = GC.@preserve ptrs _checked(lib) do err
                @capi lib :pio_apply_updates(_ptr(mh), ptrs, length(ptrs), err)
            end
            setfield!(m, :value, _module_value(lib, mh))
            _update_report(lib, report_ptr)
        end
    finally
        foreach(release!, handles)
    end
end

function _update_report(lib, ptr::Ptr)
    h = UpdateReportHandle(ptr, lib)
    report = @with_handles h begin
        p = _ptr(h)
        n = Int(@capi lib :pio_update_report_len(p))
        connectivity = @capi lib :pio_update_report_connectivity_changed(p)
        changes = map(1:n) do k
            cptr = _checked(lib) do err
                @capi lib :pio_update_report_change(p, Csize_t(k - 1), err)
            end
            change = UpdateChangeHandle(cptr, lib)
            out = @with_handles change begin
                cp = _ptr(change)
                id = ComponentIdHandle(@capi(lib, :pio_update_change_component_id(cp)), lib)
                component = @with_handles id ComponentId(
                    _str(@capi lib :pio_component_id_type(_ptr(id))),
                    _str(@capi lib :pio_component_id_local_id(_ptr(id))))
                release!(id)
                field = _str(@capi lib :pio_update_change_field(cp))
                terminal = _str(@capi lib :pio_update_change_terminal(cp))
                UpdateChange(component, field, isempty(terminal) ? nothing : terminal)
            end
            release!(change)
            out
        end
        UpdateReport(changes, connectivity)
    end
    release!(h)
    return report
end
