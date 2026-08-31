# The public typed module: one parse call, one typed result, ordinary
# dispatch on the value type. `PioModule{T}` wraps the owned C module handle
# once; the typed `value` shares that native owner, so wrapping copies no
# network and parses nothing twice.

"""
    TimeSeries{T}

The type parameter family for a module whose value is an ordered sequence of
complete `T` values: `parse_file` on a supported PyPSA CSV folder with a
declared snapshot axis returns `PioModule{TimeSeries{BalancedNetwork}}`, and
a fixed network whose complete electrical state varies returns
`PioModule{TimeSeries{OperatingPoint{BalancedNetwork}}}`. Inspect the axis
with [`list_states`](@ref). Those balanced series support `length`,
integer indexing, `eachindex`, and iteration; each selected entry remains a
[`PioModule`](@ref), preserving its records. A
`TimeSeries{OperatingPoint{MulticonductorNetwork}}` has no collection
protocol until its terminal state has a lossless static representation.
"""
struct TimeSeries{T}
    handle::StoredModule
end

"""
    ScenarioSet{T}

The type parameter family for a module whose value is a set of named
alternatives: a GridFM Parquet dataset parses to
`PioModule{ScenarioSet{BalancedNetwork}}`. A scenario module supports
`keys`, `length`, `haskey`, and string indexing. Each selected scenario
remains a [`PioModule`](@ref), preserving its records.
"""
struct ScenarioSet{T}
    handle::StoredModule
end

"""
    OperatingPoint{N}

The element type of a complete electrical state sequence over a network
family `N`. It appears as a type parameter
(`TimeSeries{OperatingPoint{BalancedNetwork}}`), never as a standalone parse
result.
"""
struct OperatingPoint{N}
    handle::StoredModule
end

# One value wrapper per calculation family: the typed value of an instance
# or solution module. Each holds the module handle; the network inside is
# shared native data, reached through the module's own accessors.

"""
    DcPfInstance

The DC power flow calculation input parsed from a source that defines one.
"""
struct DcPfInstance
    handle::StoredModule
end

"""
    AcPfInstance

The AC power flow calculation input parsed from a source that defines one.
"""
struct AcPfInstance
    handle::StoredModule
end

"""
    DcOpfInstance

The DC optimal power flow calculation input parsed from a source that defines one.
"""
struct DcOpfInstance
    handle::StoredModule
end

"""
    AcOpfInstance

The AC optimal power flow calculation input parsed from a source that defines one.
"""
struct AcOpfInstance
    handle::StoredModule
end

"""
    McAcPfInstance

The multiconductor AC power flow calculation input parsed from a source that defines one.
"""
struct McAcPfInstance
    handle::StoredModule
end

"""
    McAcOpfInstance

The multiconductor AC optimal power flow calculation input: what a BMOPF JSON source parses to.
"""
struct McAcOpfInstance
    handle::StoredModule
end

"""
    AcScucInstance

The AC security constrained unit commitment input: what a DOE GO Challenge 3 JSON source parses to.
"""
struct AcScucInstance
    handle::StoredModule
end

"""
    DcPfSolution

A solved DC power flow: the instance plus its result values.
"""
struct DcPfSolution
    handle::StoredModule
end

"""
    AcPfSolution

A solved AC power flow: the instance plus its result values.
"""
struct AcPfSolution
    handle::StoredModule
end

"""
    DcOpfSolution

A solved DC optimal power flow: the instance plus its result values.
"""
struct DcOpfSolution
    handle::StoredModule
end

"""
    AcOpfSolution

A solved AC optimal power flow: what a DeepMind OPFData JSON source parses to.
"""
struct AcOpfSolution
    handle::StoredModule
end

"""
    McAcPfSolution

A solved multiconductor AC power flow: the instance plus its result values.
"""
struct McAcPfSolution
    handle::StoredModule
end

"""
    McAcOpfSolution

A solved multiconductor AC optimal power flow: the instance plus its result values.
"""
struct McAcOpfSolution
    handle::StoredModule
end

"""
    AcScucSolution

A solved AC security constrained unit commitment: the instance plus its result values.
"""
struct AcScucSolution
    handle::StoredModule
end

"""
    UnknownValue

The value of a module whose kind this PowerIO.jl release does not know: a
newer library parsed a value family added after this binding shipped. The
module still carries its diagnostics, writes its stored document, and names
the kind through [`kind`](@ref).
"""
struct UnknownValue
    kind::String
    handle::StoredModule
end

"""
    EmitResult

The result of [`emit`](@ref). `text` contains an in-memory text emission and
is `nothing` when a destination was supplied. `diagnostics` contains findings
from the emission itself; parse findings remain on the [`PioModule`](@ref).
"""
struct EmitResult
    text::Union{String,Nothing}
    diagnostics::Vector{Diagnostic}
end

"""
    PioModule{T}

One parsed module: the typed `value` of family `T` beside the records that
explain it (retained source, diagnostics, history). [`parse_file`](@ref)
detects the source format and value kind once and wraps the native owner;
nothing reparses, serializes, or copies a network to give the module its type.

```julia
using PowerIO
case = parse_file("switch.dss")
case isa PioModule{MulticonductorNetwork}  # true
case.value                                 # the multiconductor network
case.diagnostics                           # the reader's findings
emit(case, "dss", "copy.dss")              # byte exact same format echo
```

The type parameter drives ordinary dispatch: matrix, conversion, and
transformation methods accept the module whose value family they serve.
"""
struct PioModule{T}
    handle::StoredModule
    value::T
end

"""
    PioModule(value::BalancedNetwork)
    PioModule(value::MulticonductorNetwork)

Wrap an existing network value without serializing or reparsing it. Common
records and retained source remain attached, so a parsed value still emits a
byte exact same format echo. A value rebuilt with [`from_json`](@ref) gains the
ordinary module [`emit`](@ref) path.
"""
function PioModule(value::BalancedNetwork)
    h = _live_handle(value, "PioModule")
    lib = getfield(h, :lib)
    symbol = _preferred_symbol(
        :pio_balanced_network_to_module,
        :pio_module_of_balanced_network,
        lib,
    )
    ptr = GC.@preserve h _v6_call(lib) do err
        ccall(_library_symbol(lib, symbol), Ptr{Cvoid},
              (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), getfield(h, :ptr), err)
    end
    return _wrap_module(StoredModule(ptr, lib))
end

function PioModule(value::MulticonductorNetwork)
    h = _live_dist_handle(value, "PioModule")
    lib = getfield(h, :lib)
    symbol = _preferred_symbol(
        :pio_multiconductor_network_to_module,
        :pio_module_of_multiconductor_network,
        lib,
    )
    ptr = GC.@preserve h _v6_call(lib) do err
        ccall(_library_symbol(lib, symbol), Ptr{Cvoid},
              (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), getfield(h, :ptr), err)
    end
    return _wrap_module(StoredModule(ptr, lib))
end

function Base.getproperty(m::PioModule, name::Symbol)
    name === :diagnostics && return _module_diagnostics(m)
    return getfield(m, name)
end

function Base.propertynames(::PioModule, private::Bool=false)
    public = (:value, :diagnostics)
    return private ? (public..., :handle) : public
end

# The stable kind identifiers and the value they wrap. A kind string this
# table does not know wraps as `UnknownValue` so a newer library stays
# usable.
function _wrap_module(handle::StoredModule)
    k = module_kind(handle)
    if k == "balanced_network"
        return PioModule(handle, _module_balanced_network(handle))
    elseif k == "multiconductor_network"
        return PioModule(handle, _module_multiconductor_network(handle))
    elseif k == "balanced_network_time_series"
        return PioModule(handle, TimeSeries{BalancedNetwork}(handle))
    elseif k == "balanced_operating_point_time_series"
        return PioModule(handle, TimeSeries{OperatingPoint{BalancedNetwork}}(handle))
    elseif k == "multiconductor_operating_point_time_series"
        return PioModule(handle, TimeSeries{OperatingPoint{MulticonductorNetwork}}(handle))
    elseif k == "balanced_network_scenario_set"
        return PioModule(handle, ScenarioSet{BalancedNetwork}(handle))
    elseif k == "dc_pf_instance"
        return PioModule(handle, DcPfInstance(handle))
    elseif k == "ac_pf_instance"
        return PioModule(handle, AcPfInstance(handle))
    elseif k == "dc_opf_instance"
        return PioModule(handle, DcOpfInstance(handle))
    elseif k == "ac_opf_instance"
        return PioModule(handle, AcOpfInstance(handle))
    elseif k == "mc_ac_pf_instance"
        return PioModule(handle, McAcPfInstance(handle))
    elseif k == "mc_ac_opf_instance"
        return PioModule(handle, McAcOpfInstance(handle))
    elseif k == "ac_scuc_instance"
        return PioModule(handle, AcScucInstance(handle))
    elseif k == "dc_pf_solution"
        return PioModule(handle, DcPfSolution(handle))
    elseif k == "ac_pf_solution"
        return PioModule(handle, AcPfSolution(handle))
    elseif k == "dc_opf_solution"
        return PioModule(handle, DcOpfSolution(handle))
    elseif k == "ac_opf_solution"
        return PioModule(handle, AcOpfSolution(handle))
    elseif k == "mc_ac_pf_solution"
        return PioModule(handle, McAcPfSolution(handle))
    elseif k == "mc_ac_opf_solution"
        return PioModule(handle, McAcOpfSolution(handle))
    elseif k == "ac_scuc_solution"
        return PioModule(handle, AcScucSolution(handle))
    end
    return PioModule(handle, UnknownValue(k, handle))
end

"""
    parse_file(path; format=nothing) -> PioModule

Parse a file or directory path into a typed module of whichever built in value
family claims it. `format` pins an ambiguous or mislabeled input without
changing the returned abstraction. Use [`parse_text`](@ref) for in-memory text.
"""
function parse_file(path::AbstractString;
                    format::Union{AbstractString,Nothing}=nothing)
    return _wrap_module(parse_module(path; format))
end

"""
    parse_text(text; name="<memory>", format=nothing, include_root=nothing) -> PioModule

Parse in-memory case text into a typed module. `name` labels the source for
diagnostics and format detection; `format` pins an ambiguous source. In-memory
text does not resolve included files, so `include_root` must be `nothing`; put
an include based case on disk and use [`parse_file`](@ref).
"""
function parse_text(text::AbstractString;
                    name::AbstractString="<memory>",
                    format::Union{AbstractString,Nothing}=nothing,
                    include_root::Union{AbstractString,Nothing}=nothing)
    include_root === nothing || throw(ArgumentError(
        "PowerIO.parse_text: in-memory text cannot resolve included files; " *
        "write the case beneath include_root and call parse_file"))
    return _wrap_module(parse_module_str(text; name, format))
end

"""
    kind(m::PioModule) -> String

The value's permanent kind identifier (`"balanced_network"`,
`"ac_scuc_instance"`, ...): the same stable string every language binding
and the stored document use.
"""
kind(m::PioModule) = module_kind(getfield(m, :handle))
kind(v::UnknownValue) = getfield(v, :kind)

"""
    m.diagnostics -> Vector{Diagnostic}

The module's findings as native records: severity, stable code, message,
target, byte spans into the retained source, related record identities, and
suggested actions. A successful parse keeps its findings here; a failed one
throws [`PowerIOError`](@ref) carrying the same record shape.
"""
function _module_diagnostics(m::PioModule)
    handle = getfield(m, :handle)
    lib = getfield(handle, :lib)
    return GC.@preserve handle _diagnostics_of(lib) do _
        _v6_call(lib) do err
            ccall(_library_symbol(lib, :pio_module_diagnostics), Ptr{Cvoid},
                  (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), _module_ptr(handle), err)
        end
    end
end

"""
    emit(m::PioModule, format) -> EmitResult
    emit(m::PioModule, format, destination) -> EmitResult

Emit a module in `format` as text or to a file or directory destination. With
no destination, `result.text` contains the text. With a destination,
`result.text === nothing`. `result.diagnostics` contains the emission findings
in both cases. An unchanged module emitted to its source format reproduces the
retained source bytes.
"""
function emit(m::PioModule, format::AbstractString)
    handle = getfield(m, :handle)
    lib = getfield(handle, :lib)
    symbol = _preferred_symbol(:pio_module_emit_string, :pio_module_write_str, lib)
    out_diagnostics = Ref{Ptr{Cvoid}}(C_NULL)
    s = GC.@preserve handle _v6_call(lib) do err
        ccall(_library_symbol(lib, symbol), Cstring,
              (Ptr{Cvoid}, Cstring, Ref{Ptr{Cvoid}}, Ref{Ptr{Cvoid}}),
              _module_ptr(handle), format, out_diagnostics, err)
    end
    findings = _diagnostics_of(_ -> out_diagnostics[], lib)
    return EmitResult(_take_string(lib, s), findings)
end

function emit(m::PioModule, format::AbstractString, destination::AbstractString)
    handle = getfield(m, :handle)
    lib = getfield(handle, :lib)
    symbol = _preferred_symbol(:pio_module_emit_file, :pio_module_write_file, lib)
    out_diagnostics = Ref{Ptr{Cvoid}}(C_NULL)
    GC.@preserve handle _v6_call(lib) do err
        ccall(_library_symbol(lib, symbol), Cint,
              (Ptr{Cvoid}, Cstring, Cstring, Ref{Ptr{Cvoid}}, Ref{Ptr{Cvoid}}),
              _module_ptr(handle), format, destination, out_diagnostics, err)
    end
    return EmitResult(nothing, _diagnostics_of(_ -> out_diagnostics[], lib))
end

"""
    to_json(m::PioModule) -> String

The stored `.pio.json` document for a module. On a network value,
`to_json(m.value)` remains the model-only JSON transport.
"""
to_json(m::PioModule) = write_module(getfield(m, :handle))

"""
    from_json(PioModule, text) -> PioModule
    from_json(BalancedNetwork, text) -> BalancedNetwork

Read stored module JSON or balanced model JSON through explicit type dispatch.
The one argument `from_json(text)` balanced model form remains available.
"""
from_json(::Type{PioModule}, text::AbstractString) = _wrap_module(read_module(text))
from_json(::Type{BalancedNetwork}, text::AbstractString) = from_json(text)

"""
    inspect(m::PioModule)

Value inspection and supported operation discovery: counts, the source
format, and the operations the value supports, decoded from the module's
inspection report. `operations` names the concise Julia surface; C ABI
compatibility spellings are not exposed through this binding.
"""
function inspect(m::PioModule)
    raw = inspect_module(getfield(m, :handle))
    report = Dict{String,Any}(
        "kind" => raw.kind,
        "value" => raw.value,
        "records" => raw.records,
        "operations" => _public_operations(m),
    )
    haskey(raw, :source_format) && (report["source_format"] = raw.source_format)
    return JSON3.read(JSON3.write(report))
end

_public_operations(::PioModule) = ["inspect", "diagnostics", "emit"]
_public_operations(::PioModule{BalancedNetwork}) =
    ["inspect", "diagnostics", "emit", "to_normalized"]
_public_operations(::PioModule{MulticonductorNetwork}) =
    ["inspect", "diagnostics", "emit", "to_balanced_report", "to_balanced"]
_public_operations(::PioModule{TimeSeries{OperatingPoint{MulticonductorNetwork}}}) =
    ["inspect", "diagnostics", "emit"]
_public_operations(::PioModule{<:TimeSeries}) =
    ["inspect", "diagnostics", "emit", "list_states", "export_state"]
_public_operations(::PioModule{<:ScenarioSet}) =
    ["inspect", "diagnostics", "emit", "list_states", "export_state"]

"""
    source_format(m::PioModule) -> Union{String,Nothing}

The stable name of the format the module was parsed from, or `nothing` for a
module built in memory.
"""
function source_format(m::PioModule)
    report = inspect(m)
    fmt = get(report, :source_format, nothing)
    fmt === nothing && return nothing
    text = String(fmt)
    return isempty(text) ? nothing : text
end

"""
    list_states(m::PioModule)

List the time points or scenarios of a series or scenario set module.
Time point positions are one based, matching [`export_state`](@ref)'s `time`
keyword: the first time point has `position == 1`.
"""
function list_states(m::PioModule)
    raw = list_states(getfield(m, :handle))
    haskey(raw, :time_points) || return raw
    return _one_based_time_points(raw)
end

# Exportable series and scenario modules act like Julia collections without
# claiming an AbstractArray or AbstractDict subtype. Indexing keeps the
# selected module, including its diagnostics and history, rather than
# throwing that context away and returning only `.value`. Multiconductor
# operating point state has no lossless static materialization and therefore
# deliberately gets no collection protocol.
const _INDEXABLE_TIME_SERIES = Union{
    TimeSeries{BalancedNetwork},
    TimeSeries{OperatingPoint{BalancedNetwork}},
}

function Base.length(m::PioModule{T}) where {T<:_INDEXABLE_TIME_SERIES}
    return length(list_states(m).time_points)
end
Base.firstindex(::PioModule{T}) where {T<:_INDEXABLE_TIME_SERIES} = 1
Base.lastindex(m::PioModule{T}) where {T<:_INDEXABLE_TIME_SERIES} = length(m)
Base.eachindex(m::PioModule{T}) where {T<:_INDEXABLE_TIME_SERIES} = Base.OneTo(length(m))
Base.getindex(m::PioModule{T}, i::Integer) where {T<:_INDEXABLE_TIME_SERIES} =
    export_state(m; time=i)
function Base.iterate(m::PioModule{T},
                      state::Tuple{Int,Int}=(1, length(m))) where {T<:_INDEXABLE_TIME_SERIES}
    i, n = state
    i > n && return nothing
    return m[i], (i + 1, n)
end

function Base.keys(m::PioModule{T}) where {T<:ScenarioSet}
    return String[String(row.id) for row in list_states(m).scenarios]
end
Base.length(m::PioModule{T}) where {T<:ScenarioSet} =
    length(list_states(m).scenarios)
Base.haskey(m::PioModule{T}, id::AbstractString) where {T<:ScenarioSet} =
    any(==(String(id)), keys(m))
Base.getindex(m::PioModule{T}, id::AbstractString) where {T<:ScenarioSet} =
    export_state(m; scenario=id)

# The raw v6 report is zero based, matching the C ABI (`export_state`'s
# `time_position`); this wrapper and the public `export_state` method's `time`
# keyword are one
# based, matching every other Julia axis, so positions are bumped by one on
# the way out. Scenario entries carry no position, so they pass through
# `haskey(raw, :time_points)` above untouched.
function _one_based_time_points(raw)
    points = map(raw.time_points) do p
        entry = Dict{Symbol,Any}(pairs(p))
        entry[:position] += 1
        entry
    end
    entry = Dict{Symbol,Any}(pairs(raw))
    entry[:time_points] = points
    return JSON3.read(JSON3.write(entry))
end

function _require_complete_dc_branch_axis(data::_DcData, operation::AbstractString)
    missing = _dc_omitted(data)
    isempty(missing) && return data
    details = join(("$id ($reason)" for (id, reason) in missing), ", ")
    noun = length(missing) == 1 ? "branch was" : "branches were"
    throw(ArgumentError(
        "$operation cannot return the complete branch table axis because " *
        "$(length(missing)) $noun omitted: $details",
    ))
end

"""
    calc_incidence_matrix(m::PioModule{BalancedNetwork}; formula="series_susceptance")

Calculate the canonical DC incidence matrix `A` as branches by buses, with
`+1` at the from bus and `-1` at the to bus. The module, network value, and
path overloads use this orientation.
"""
calc_incidence_matrix(m::PioModule{BalancedNetwork};
                      formula::AbstractString="series_susceptance") = begin
    data = _dc_data(getfield(m, :handle); formula)
    _require_complete_dc_branch_axis(data, "calc_incidence_matrix")
    _dc_calc_incidence_matrix(data)
end

"""
    calc_bus_susceptance_matrix(m::PioModule{BalancedNetwork}; formula="series_susceptance")
    calc_bus_susceptance_matrix(path; format=nothing, formula="series_susceptance")

Calculate the canonical DC bus susceptance matrix
`B = A' * Diagonal(b) * A`. Phase
shift injections stay separate, so `B` remains symmetric.
"""
calc_bus_susceptance_matrix(m::PioModule{BalancedNetwork};
                            formula::AbstractString="series_susceptance") =
    _dc_calc_bus_susceptance_matrix(_dc_data(getfield(m, :handle); formula))

"""
    calc_branch_susceptance_matrix(m::PioModule{BalancedNetwork}; formula="series_susceptance")
    calc_branch_susceptance_matrix(path; format=nothing, formula="series_susceptance")

Calculate the canonical DC branch matrix `Bf = Diagonal(b) * A`, as branches
by buses.
"""
calc_branch_susceptance_matrix(m::PioModule{BalancedNetwork};
                               formula::AbstractString="series_susceptance") = begin
    data = _dc_data(getfield(m, :handle); formula)
    _require_complete_dc_branch_axis(data, "calc_branch_susceptance_matrix")
    _dc_calc_branch_susceptance_matrix(data)
end

"""
    calc_phase_shift_injection(m::PioModule{BalancedNetwork}; formula="series_susceptance")
    calc_phase_shift_injection(path; format=nothing, formula="series_susceptance")

Calculate `p_shift = A' * (b .* shift)` in canonical bus order. The phase
shift term stays separate from the symmetric bus susceptance matrix.
"""
calc_phase_shift_injection(m::PioModule{BalancedNetwork};
                           formula::AbstractString="series_susceptance") =
    copy(_dc_shift_injection(_dc_data(getfield(m, :handle); formula)))

"""
    calc_branch_flow_dc(m::PioModule{BalancedNetwork}, voltage_angles;
                        formula="series_susceptance")
    calc_branch_flow_dc(path, voltage_angles;
                        format=nothing, formula="series_susceptance")

Compute `p_branch = -Bf * voltage_angles + b .* shift` in canonical branch
order. Voltage angles are in radians.
"""
calc_branch_flow_dc(m::PioModule{BalancedNetwork},
                    voltage_angles::AbstractVector{<:Real};
                    formula::AbstractString="series_susceptance") = begin
    data = _dc_data(getfield(m, :handle); formula)
    _require_complete_dc_branch_axis(data, "calc_branch_flow_dc")
    _dc_calc_branch_flow(data, voltage_angles)
end

"""
    calc_bus_injection_dc(m::PioModule{BalancedNetwork}, voltage_angles;
                          formula="series_susceptance")
    calc_bus_injection_dc(path, voltage_angles;
                          format=nothing, formula="series_susceptance")

Compute `p_bus = -B * voltage_angles + p_shift` in canonical bus order.
Voltage angles are in radians.
"""
calc_bus_injection_dc(m::PioModule{BalancedNetwork},
                      voltage_angles::AbstractVector{<:Real};
                      formula::AbstractString="series_susceptance") =
    _dc_calc_bus_injection(
        _dc_data(getfield(m, :handle); formula),
        voltage_angles,
    )

# A bare live value uses the same named calculations without exposing the C
# handle that supplies their arrays.
calc_bus_susceptance_matrix(net::BalancedNetwork; kwargs...) =
    calc_bus_susceptance_matrix(PioModule(net); kwargs...)
calc_branch_susceptance_matrix(net::BalancedNetwork; kwargs...) =
    calc_branch_susceptance_matrix(PioModule(net); kwargs...)
calc_phase_shift_injection(net::BalancedNetwork; kwargs...) =
    calc_phase_shift_injection(PioModule(net); kwargs...)
calc_branch_flow_dc(net::BalancedNetwork, voltage_angles::AbstractVector{<:Real}; kwargs...) =
    calc_branch_flow_dc(PioModule(net), voltage_angles; kwargs...)
calc_bus_injection_dc(net::BalancedNetwork, voltage_angles::AbstractVector{<:Real}; kwargs...) =
    calc_bus_injection_dc(PioModule(net), voltage_angles; kwargs...)

# Julia's path convenience is consistent across every exported matrix and
# direct DC calculation. Parsing remains explicit in Rust, Python, and C.
calc_bus_susceptance_matrix(path::AbstractString;
                            format::Union{AbstractString,Nothing}=nothing,
                            formula::AbstractString="series_susceptance") =
    calc_bus_susceptance_matrix(parse_file(path; format); formula)
calc_branch_susceptance_matrix(path::AbstractString;
                               format::Union{AbstractString,Nothing}=nothing,
                               formula::AbstractString="series_susceptance") =
    calc_branch_susceptance_matrix(parse_file(path; format); formula)
calc_phase_shift_injection(path::AbstractString;
                           format::Union{AbstractString,Nothing}=nothing,
                           formula::AbstractString="series_susceptance") =
    calc_phase_shift_injection(parse_file(path; format); formula)
calc_branch_flow_dc(path::AbstractString, voltage_angles::AbstractVector{<:Real};
                    format::Union{AbstractString,Nothing}=nothing,
                    formula::AbstractString="series_susceptance") =
    calc_branch_flow_dc(parse_file(path; format), voltage_angles; formula)
calc_bus_injection_dc(path::AbstractString, voltage_angles::AbstractVector{<:Real};
                      format::Union{AbstractString,Nothing}=nothing,
                      formula::AbstractString="series_susceptance") =
    calc_bus_injection_dc(parse_file(path; format), voltage_angles; formula)

"""
    export_state(m::PioModule; time=nothing, scenario=nothing) -> PioModule

Select one time point (one based, matching every other Julia axis) or one
named scenario as an independent static module. The selection shares the
base network's native data; nothing reparses or copies numerical tables.

A `TimeSeries{OperatingPoint{MulticonductorNetwork}}` module refuses with
`REQUEST.STATE.UNBOUND_EXPORT`: a multiconductor operating point selects and
reads in place, and static materialization is not implemented yet.
"""
function export_state(m::PioModule;
                      time::Union{Integer,Nothing}=nothing,
                      scenario::Union{AbstractString,Nothing}=nothing)
    (time === nothing) == (scenario === nothing) &&
        error("PowerIO.export_state: pass exactly one of time and scenario")
    if time !== nothing
        time >= 1 || error("PowerIO.export_state: time is one based; got $time")
    end
    handle = try
        _export_state(getfield(m, :handle);
                      time_position=time === nothing ? nothing : time - 1,
                      scenario)
    catch err
        (time !== nothing && err isa PowerIOError && err.code == "REQUEST.STATE.OUT_OF_RANGE") ||
            rethrow()
        _rebase_out_of_range(err, time)
    end
    return _wrap_module(handle)
end

# `err`'s message names the zero-based `time_position` this function passed
# to `_export_state`, not the one-based `time` the caller passed to us;
# restate it in the caller's own terms. The code is unchanged so callers
# still branch on it.
function _rebase_out_of_range(err::PowerIOError, time::Integer)
    axis = match(r"outside the (\d+) point axis", err.message)
    message = axis === nothing ?
        "time = $time is outside the time point axis" :
        "time = $time (the $(axis[1]) point axis accepts 1:$(axis[1]))"
    throw(PowerIOError(err.code, message, err.diagnostics))
end

"""
    to_balanced(m::PioModule{MulticonductorNetwork}; base_mva=100.0) -> PioModule{BalancedNetwork}

Build the positive sequence balanced equivalent of a multiconductor value.
The pass appends its findings and one Transform history entry;
the source descriptors carry over, but not the retained bytes, so a later
emission in the original format cannot echo the source exactly.
[`to_balanced_report`](@ref) reports the losses first without transforming.
"""
to_balanced(m::PioModule{MulticonductorNetwork}; base_mva::Real=100.0) =
    _wrap_module(_to_balanced_module(getfield(m, :handle); base_mva))

"""
    to_balanced_report(m::PioModule{MulticonductorNetwork}; base_mva=100.0)

Report the assumptions, losses, and blocking findings for [`to_balanced`](@ref)
without building the balanced equivalent.
"""
to_balanced_report(m::PioModule{MulticonductorNetwork}; base_mva::Real=100.0) =
    _to_balanced_report(getfield(m, :handle); base_mva)

function Base.show(io::IO, m::PioModule{T}) where {T}
    print(io, "PioModule{", T, "}")
    fmt = try
        source_format(m)
    catch
        nothing
    end
    fmt === nothing || print(io, " from ", fmt)
    n = try
        length(m.diagnostics)
    catch
        0
    end
    n == 0 || print(io, ", ", n, n == 1 ? " finding" : " findings")
end

function Base.show(io::IO, ::MIME"text/plain", m::PioModule{T}) where {T}
    show(io, m)
    report = try
        inspect(m)
    catch
        nothing
    end
    report === nothing && return
    values = get(report, :value, nothing)
    if values isa JSON3.Object && !isempty(values)
        print(io, "\n  ", join(("$(v) $(k)" for (k, v) in pairs(values)), ", "))
    end
    records = get(report, :records, nothing)
    records isa JSON3.Object || return
    nonzero = [(k, v) for (k, v) in pairs(records) if v isa Integer && v > 0]
    isempty(nonzero) || print(io, "\n  ", join(("$(v) $(k)" for (k, v) in nonzero), ", "))
end

# ---- descriptive records: history and sources -------------------------------

"""
    ModuleHistoryEntry

One structured, descriptive operation in a module's history: `id`, `kind`
(`"upgrade"`, `"transform"`, `"repair"`; a plain parse contributes no
entry), `name`, and the stated `assumptions` and `losses`. History
describes; it does not replay.
"""
struct ModuleHistoryEntry
    id::String
    kind::String
    name::String
    assumptions::Vector{String}
    losses::Vector{String}
end

"""
    ModuleSource

One source a module was compiled from: module local `id`, display `name`,
`byte_length`, and the optional stated `format`.
"""
struct ModuleSource
    id::String
    name::String
    byte_length::Int
    format::Union{String,Nothing}
end

# The stored document is the wire; decoding records from it reads exactly
# what `to_json` states, no whole network re-serialization beyond that
# wire.
_stored_document(m::PioModule) = JSON3.read(to_json(m))

# An explicit JSON null reads like an absent key: the capi document writes
# "format": null where the DTO omits the key.
function _record_string(row, key)
    value = get(row, key, nothing)
    return value === nothing ? nothing : String(value)
end

"""
    history(m::PioModule) -> Vector{ModuleHistoryEntry}

The module's descriptive history, decoded from the stored document.
"""
function history(m::PioModule)
    rows = get(_stored_document(m), :history, nothing)
    rows === nothing && return ModuleHistoryEntry[]
    return [ModuleHistoryEntry(
                String(row.id), String(row.kind), String(row.name),
                haskey(row, :assumptions) ? String.(row.assumptions) : String[],
                haskey(row, :losses) ? String.(row.losses) : String[],
            ) for row in rows]
end

"""
    module_sources(m::PioModule) -> Vector{ModuleSource}

The sources the module was compiled from, decoded from the stored document.
The explicit name avoids confusion with distribution voltage source elements.
"""
function module_sources(m::PioModule)
    rows = get(_stored_document(m), :sources, nothing)
    rows === nothing && return ModuleSource[]
    return [ModuleSource(String(row.id), String(row.name), Int(row.byte_length),
                         _record_string(row, :format)) for row in rows]
end

# Read-only module forwarding. The value and module share the same native
# allocation, so these methods add Julia dispatch convenience without copying
# tables or changing ownership.
for f in (:buses, :branches, :generators, :loads, :shunts, :storage, :hvdc,
          :switches,
          :n_buses, :n_branches, :n_generators, :n_switches,
          :base_mva, :base_frequency, :network_name, :reference_bus_id,
          :reference_bus_positions, :n_islands, :is_radial)
    @eval $f(m::PioModule{BalancedNetwork}) = $f(getfield(m, :value))
end

for f in (:buses, :lines, :linecodes, :switches, :transformers, :loads,
          :generators, :ibrs, :control_profiles, :shunts, :capacitors,
          :voltage_sources, :untyped, :n_buses, :n_generators,
          :base_frequency, :network_name)
    @eval $f(m::PioModule{MulticonductorNetwork}) = $f(getfield(m, :value))
end

to_normalized(m::PioModule{BalancedNetwork}; kwargs...) =
    to_normalized(getfield(m, :value); kwargs...)
to_dense(m::PioModule{BalancedNetwork}) = to_dense(getfield(m, :value))
to_arrow(m::PioModule{BalancedNetwork}, table::Symbol; kwargs...) =
    to_arrow(getfield(m, :value), table; kwargs...)
to_graph(m::PioModule{BalancedNetwork}) = to_graph(getfield(m, :value))
to_graph(m::PioModule{MulticonductorNetwork}) = to_graph(getfield(m, :value))
to_powermodels(m::PioModule{BalancedNetwork}) = to_powermodels(getfield(m, :value))
to_powerdata(m::PioModule{BalancedNetwork};
             filtered::Union{Bool,_DefaultPowerdataFilter}=_DEFAULT_POWERDATA_FILTER,
             T::Type{<:Real}=Float64) =
    to_powerdata(m, T; filtered)
to_powerdata(m::PioModule{BalancedNetwork}, ::Type{T};
             filtered::Union{Bool,_DefaultPowerdataFilter}=_DEFAULT_POWERDATA_FILTER) where {T<:Real} =
    to_powerdata(getfield(m, :value), T, Val(:live); filtered)
to_powerdata(m::PioModule{BalancedNetwork}, ::Type{T}, live::Val{:live};
             filtered::Union{Bool,_DefaultPowerdataFilter}=_DEFAULT_POWERDATA_FILTER) where {T<:Real} =
    to_powerdata(getfield(m, :value), T, live; filtered)

to_ac_power_data(m::PioModule{BalancedNetwork};
                 filtered::Union{Bool,_DefaultPowerdataFilter}=_DEFAULT_POWERDATA_FILTER,
                 T::Type{<:Real}=Float64) =
    to_ac_power_data(m, T; filtered)
function to_ac_power_data(m::PioModule{BalancedNetwork}, ::Type{T};
                          filtered::Union{Bool,_DefaultPowerdataFilter}=_DEFAULT_POWERDATA_FILTER) where {T<:Real}
    pd = to_powerdata(m, T; filtered)
    return _to_ac_power_data_output(pd, T)
end
function to_ac_power_data(m::PioModule{BalancedNetwork}, ::Type{T}, live::Val{:live};
                          filtered::Union{Bool,_DefaultPowerdataFilter}=_DEFAULT_POWERDATA_FILTER) where {T<:Real}
    pd = to_powerdata(m, T, live; filtered)
    return _to_ac_power_data_output(pd, T)
end

for f in (:calc_admittance_matrix, :calc_bprime_matrix,
          :calc_bdoubleprime_matrix)
    @eval $f(m::PioModule{BalancedNetwork}) = $f(getfield(m, :value))
end
