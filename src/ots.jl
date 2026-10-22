# Typed AC optimal transmission switching. No typed read serializes the module.

"""
    BranchSelection(:all)
    BranchSelection(:none)
    BranchSelection(["branch-id", ...])

Select physical switching candidates. `:all` includes initially open branches.
Identity lists reject duplicates and unknown identities during construction.
"""
struct BranchSelection
    select::Symbol
    identities::Vector{String}
    function BranchSelection(select::Symbol, identities::Vector{String}=String[])
        select in (:all, :none, :only) || throw(ArgumentError("unknown branch selection $select"))
        select === :only || isempty(identities) || throw(ArgumentError("identities require :only"))
        new(select, copy(identities))
    end
end
BranchSelection(ids::AbstractVector{<:AbstractString}) = BranchSelection(:only, String.(ids))

"""Transition-only opening and closing costs for one physical branch identity."""
struct BranchSwitchingCost
    id::String
    open_cost::Float64
    close_cost::Float64
end

"""
Explicit from/to terminal current magnitudes in per unit on system MVA and each
terminal's nominal voltage base. `nothing` is unbounded, not zero. Legacy source
current ratings are never implicitly interpreted as per unit.
"""
struct BranchCurrentLimit
    id::String
    from_pu::Union{Float64,Nothing}
    to_pu::Union{Float64,Nothing}
end

"""
    AcOtsOptions(; switchable=BranchSelection(:all), switching_costs=[],
                  islanding=:forbidden, max_open=nothing, max_switched=nothing,
                  current_limits=:skip, stated_current_limits=[])

Explicit OTS options. `max_open` counts all final-open physical rows;
`max_switched` counts changes from initial status. Islanding is `:forbidden` or
`:allowed`; allowed islands do not imply load shedding. Current policy is
`:skip`, `:stated`, or `:derive_from_rate_a`. Derived current bounds are necessary
bounds from active MVA and voltage constraints, not equivalent MVA constraints.
Low-level `AcOtsInstance` construction preserves the base objective; costs enter
the total only when `branch_switching_cost` is selected. The convenience
`to_ac_ots_instance` conversion selects this term automatically.
"""
Base.@kwdef struct AcOtsOptions
    switchable::BranchSelection = BranchSelection(:all)
    switching_costs::Vector{BranchSwitchingCost} = BranchSwitchingCost[]
    islanding::Symbol = :forbidden
    max_open::Union{Int,Nothing} = nothing
    max_switched::Union{Int,Nothing} = nothing
    current_limits::Symbol = :skip
    stated_current_limits::Vector{BranchCurrentLimit} = BranchCurrentLimit[]
end

_ots_string(s::String) = PioStringView(pointer(s), sizeof(s))
_ots_optional(x) = something(x, 0.0)

function _with_ots_options(f, options::AcOtsOptions)
    options.islanding in (:forbidden, :allowed) || throw(ArgumentError("unknown islanding policy"))
    options.current_limits in (:skip, :stated, :derive_from_rate_a) || throw(ArgumentError("unknown current limit policy"))
    for (name, value) in ((:max_open, options.max_open), (:max_switched, options.max_switched))
        value === nothing || value >= 0 || throw(ArgumentError("$name must be nonnegative"))
    end
    names = String[String(options.switchable.select), String(options.islanding), String(options.current_limits)]
    append!(names, options.switchable.identities)
    append!(names, (c.id for c in options.switching_costs))
    append!(names, (c.id for c in options.stated_current_limits))
    # Preserve every string owner, not only the arrays of pointer-containing records.
    GC.@preserve names options begin
        ids = _ots_string.(options.switchable.identities)
        costs = [LibPowerIO.PioBranchSwitchingCost(_ots_string(c.id), c.open_cost, c.close_cost) for c in options.switching_costs]
        limits = [LibPowerIO.PioBranchCurrentLimit(_ots_string(c.id), _ots_optional(c.from_pu), _ots_optional(c.to_pu), c.from_pu !== nothing, c.to_pu !== nothing) for c in options.stated_current_limits]
        GC.@preserve ids costs limits begin
            raw = LibPowerIO.PioAcOtsOptions(_ots_string(names[1]), pointer(ids), length(ids),
                pointer(costs), length(costs), _ots_string(names[2]),
                something(options.max_open, 0), options.max_open !== nothing,
                something(options.max_switched, 0), options.max_switched !== nothing,
                _ots_string(names[3]), pointer(limits), length(limits))
            f(Ref(raw))
        end
    end
end

function _create_ac_ots_instance(base::AcOpfInstance, options::AcOtsOptions)
    _with_ots_options(options) do raw
        _with_handle(base) do lib, p
            ptr = _checked(lib) do err
                @capi lib :pio_ac_ots_instance_create(p, raw, err)
            end
            _wrap_module(lib, ptr)
        end
    end
end
"""
    to_ac_ots_instance(module::PioModule; options=nothing)

Construct from a balanced network or AC OPF module, or reconfigure an existing
AC OTS module. With no explicit options, select initially closed branches and
include the switching objective term. Explicit options also add that term once,
while retaining other objective terms and the module provenance.
"""
function to_ac_ots_instance(m::PioModule; options::Union{AcOtsOptions,Nothing}=nothing)
    lib = _lib_of(m)
    h = _handle(m)
    if options === nothing
        ptr = @with_handles h _checked(lib) do err
            @capi lib :pio_module_to_ac_ots_instance(_ptr(h), err)
        end
        return _wrap_module(lib, ptr)
    end
    _with_ots_options(options) do raw
        ptr = @with_handles h _checked(lib) do err
            @capi lib :pio_module_to_ac_ots_instance_with_options(_ptr(h), raw, err)
        end
        _wrap_module(lib, ptr)
    end
end

"""
    AcOtsInstance(base::AcOpfInstance, options=AcOtsOptions())

Construct from an explicit base AC OPF specification. Explicit default options
select all physical rows, unlike `to_ac_ots_instance(network_module)`, which
selects only initially in-service rows. The base objective is preserved exactly;
switching costs enter the total only if its switching objective term is selected.
No optimizer or formulation is supplied.
"""
AcOtsInstance(base::AcOpfInstance, options::AcOtsOptions=AcOtsOptions()) = _create_ac_ots_instance(base, options).value

struct _OtsBranches <: AbstractVector{NamedTuple}
    instance::AcOtsInstance
end
Base.IndexStyle(::Type{_OtsBranches}) = IndexLinear()
function _ots_options_view(instance::AcOtsInstance)
    _with_handle(instance) do lib, p
        _fill(LibPowerIO.PioAcOtsOptionsView, lib) do out, err
            @capi lib :pio_ac_ots_instance_options(p, out, err)
        end
    end
end
Base.size(rows::_OtsBranches) = (Int(_ots_options_view(rows.instance).branch_count),)
function Base.getindex(rows::_OtsBranches, i::Int)
    checkbounds(rows, i)
    _with_handle(rows.instance) do lib, p
        v = _fill(LibPowerIO.PioAcOtsBranchView, lib) do out, err
            @capi lib :pio_ac_ots_instance_branch_at(p, Csize_t(i - 1), out, err)
        end
        (id=_str(v.id), initial_closed=v.initial_closed, switchable=v.switchable,
         cost=v.has_switching_cost ? BranchSwitchingCost(_str(v.id), v.open_cost, v.close_cost) : nothing,
         stated_current=BranchCurrentLimit(_str(v.id), v.has_stated_from_pu ? v.stated_from_pu : nothing,
                                          v.has_stated_to_pu ? v.stated_to_pu : nothing),
         current=BranchCurrentLimit(_str(v.id), v.has_current_from_pu ? v.current_from_pu : nothing,
                                   v.has_current_to_pu ? v.current_to_pu : nothing))
    end
end

function Base.getproperty(instance::AcOtsInstance, name::Symbol)
    name === :branches && return _OtsBranches(instance)
    name === :branch_order && return [row.id for row in instance.branches]
    name === :initial_closed && return [row.initial_closed for row in instance.branches]
    name === :switchable_mask && return [row.switchable for row in instance.branches]
    if name === :options
        v = _ots_options_view(instance)
        rows = collect(instance.branches)
        select = Symbol(_str(v.switchable))
        selection = BranchSelection(select, select === :only ? [r.id for r in rows if r.switchable] : String[])
        return AcOtsOptions(switchable=selection, islanding=Symbol(_str(v.islanding)),
            max_open=v.has_max_open ? Int(v.max_open) : nothing,
            max_switched=v.has_max_switched ? Int(v.max_switched) : nothing,
            current_limits=Symbol(_str(v.current_limits)),
            switching_costs=BranchSwitchingCost[r.cost for r in rows if r.cost !== nothing],
            stated_current_limits=BranchCurrentLimit[r.stated_current for r in rows if
                r.stated_current.from_pu !== nothing || r.stated_current.to_pu !== nothing])
    end
    invoke(Base.getproperty, Tuple{CalculationInstance,Symbol}, instance, name)
end
Base.propertynames(::AcOtsInstance, private::Bool=false) =
    private ? (:network, :options, :branches, :branch_order, :initial_closed, :switchable_mask, :handle) :
              (:network, :options, :branches, :branch_order, :initial_closed, :switchable_mask)

function _ots_topology(states::AbstractVector{Bool})
    UInt8.(states)
end

"""Validate fixed rows, switching budgets and final AC connectivity; return transition cost."""
function switching_cost(instance::AcOtsInstance, states::AbstractVector{Bool})
    closed = _ots_topology(states)
    GC.@preserve closed _with_handle(instance) do lib, p
        out = Ref{Float64}(0)
        _checked(lib) do err
            @capi lib :pio_ac_ots_instance_validate_topology(p, closed, length(closed), out, err)
        end
        out[]
    end
end
"""Validate a complete physical branch status vector. Does not certify AC feasibility."""
validate_topology(instance::AcOtsInstance, states::AbstractVector{Bool}) = (switching_cost(instance, states); nothing)

"""Fix final branch states and return an AC OPF module with policy-loss diagnostics."""
function fix_topology(instance::AcOtsInstance, states::AbstractVector{Bool})
    closed = _ots_topology(states)
    GC.@preserve closed _with_handle(instance) do lib, p
        ptr = _checked(lib) do err
            @capi lib :pio_ac_ots_instance_fix_topology(p, closed, length(closed), err)
        end
        _wrap_module(lib, ptr)
    end
end

"""
    AcOtsSolution(instance, branch_closed, ac_solution)

Attach an AC OPF result computed on `fix_topology(instance, branch_closed)`.
Construction checks exact problem correspondence, finite values and zero flows
on open branches, not AC residuals or optimality. The result's `.network` is the
original candidate-complete network; materialize explicitly for solved emission.
"""
function AcOtsSolution(instance::AcOtsInstance, states::AbstractVector{Bool}, ac::AcOpfSolution)
    closed = _ots_topology(states)
    h, ah = getfield(instance, :handle), getfield(ac, :handle)
    lib = _lib_of(instance)
    GC.@preserve closed @with_handles h ah begin
        ptr = _checked(lib) do err
            @capi lib :pio_ac_ots_solution_create(_ptr(h), closed, length(closed), _ptr(ah), err)
        end
        _wrap_module(lib, ptr).value
    end
end

function _ots_solution_view(solution::AcOtsSolution)
    _with_handle(solution) do lib, p
        _fill(LibPowerIO.PioAcOtsSolutionView, lib) do out, err
            @capi lib :pio_ac_ots_solution_summary(p, out, err)
        end
    end
end
function Base.getproperty(solution::AcOtsSolution, name::Symbol)
    if name === :branch_closed
        _with_handle(solution) do lib, p
            n = Int(_ots_solution_view(solution).branch_count)
            [begin
                out = Ref{Bool}(false)
                _checked(lib) do err
                    @capi lib :pio_ac_ots_solution_branch_closed_at(p, Csize_t(i), out, err)
                end
                out[]
            end for i in 0:n-1]
        end
    elseif name in (:branches_open, :branches_switched, :switching_cost)
        getproperty(_ots_solution_view(solution), name)
    else
        invoke(Base.getproperty, Tuple{CalculationSolution,Symbol}, solution, name)
    end
end
Base.propertynames(::AcOtsSolution, private::Bool=false) =
    private ? (:instance, :network, :termination, :objective, :branch_closed, :branches_open, :branches_switched, :switching_cost, :handle) :
              (:instance, :network, :termination, :objective, :branch_closed, :branches_open, :branches_switched, :switching_cost)

"""Materialize final topology and AC values into a balanced network module for grid emission."""
function materialize_ac_ots_solution(solution::AcOtsSolution)
    _with_handle(solution) do lib, p
        ptr = _checked(lib) do err
            @capi lib :pio_ac_ots_solution_materialize(p, err)
        end
        _wrap_module(lib, ptr)
    end
end
