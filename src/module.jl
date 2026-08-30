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
with [`state_inventory`](@ref). Those balanced series support `length`,
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

function Base.getproperty(m::PioModule, name::Symbol)
    name === :diagnostics && return diagnostics(m)
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

function _parse_file_format(format::Union{AbstractString,Nothing}, from)
    format !== nothing && from !== nothing && throw(ArgumentError(
        "parse_file accepts either format or from, not both"))
    selected = format === nothing ? from : format
    return selected === nothing ? nothing : String(selected)
end

"""
    parse_file(path; format=nothing) -> PioModule
    parse_file(io::IO; name="<memory>", format=nothing) -> PioModule

Parse a path or stream into a typed module of whichever built in value family
claims it. A path can name a file or directory format profile. Stream input is
read once; `name` labels it and supplies an extension for format detection.
`format` pins an ambiguous or mislabeled input without changing the returned
abstraction.
"""
function parse_file(path::AbstractString;
                    format::Union{AbstractString,Nothing}=nothing,
                    from=nothing)
    return _wrap_module(parse_module(path; format=_parse_file_format(format, from)))
end

function parse_file(io::IO;
                    name::AbstractString="<memory>",
                    format::Union{AbstractString,Nothing}=nothing,
                    from=nothing)
    return parse_bytes(io; name, format=_parse_file_format(format, from))
end

# Quiet compatibility for the released positional stream format.
parse_file(io::IO, format::AbstractString; name::AbstractString="<memory>") =
    parse_file(io; name, format)

# Quiet compatibility for consumers that used the pre-0.10 type marker.
# The marker narrows the parsed value and returns it, preserving the old
# return type. New code dispatches on the PioModule that parse_file(source)
# returns instead.
const _COMPAT_NETWORK_VALUE = Union{BalancedNetwork,MulticonductorNetwork}

function parse_file(::Type{T}, path::AbstractString; from=nothing) where {T<:_COMPAT_NETWORK_VALUE}
    m = parse_file(path; format=from === nothing ? nothing : String(from))
    m isa PioModule{T} || error(
        "PowerIO.parse_file: $(repr(path)) parsed as $(kind(m)), not $(T)")
    return m.value
end

function parse_file(::Type{T}, io::IO;
                    from=nothing,
                    name::AbstractString="<memory>") where {T<:_COMPAT_NETWORK_VALUE}
    m = parse_file(io; name, format=from === nothing ? nothing : String(from))
    m isa PioModule{T} || error(
        "PowerIO.parse_file: $(repr(name)) parsed as $(kind(m)), not $(T)")
    return m.value
end

"""
    parse_bytes(bytes; name="<memory>", format=nothing) -> PioModule
    parse_bytes(io::IO; name="<memory>", format=nothing) -> PioModule

Compatibility entry point for a byte buffer or stream. `name` labels the buffer for diagnostics
and format detection from its extension; the default `"<memory>"` has none,
so an ambiguous source needs either an explicit `format` or a `name` ending
in a recognized extension (e.g. `name="case.m"`).
"""
parse_bytes(bytes::AbstractVector{UInt8};
            name::AbstractString="<memory>",
            format::Union{AbstractString,Nothing}=nothing) =
    _wrap_module(parse_module_bytes(bytes; name, format))
parse_bytes(io::IO; kwargs...) = parse_bytes(read(io); kwargs...)

"""
    kind(m::PioModule) -> String

The value's permanent kind identifier (`"balanced_network"`,
`"ac_scuc_instance"`, ...): the same stable string every language binding
and the stored document use.
"""
kind(m::PioModule) = module_kind(getfield(m, :handle))
kind(v::UnknownValue) = getfield(v, :kind)

"""
    diagnostics(m::PioModule) -> Vector{Diagnostic}

The module's findings as native records: severity, stable code, message,
target, byte spans into the retained source, related record identities, and
suggested actions. A successful parse keeps its findings here; a failed one
throws [`PowerIOError`](@ref) carrying the same record shape.
"""
function diagnostics(m::PioModule)
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
    write_str(m::PioModule; format) -> String

Compatibility convenience that returns only the text from
`emit(m, format)`. Writing an
unchanged parsed module back to its own source format returns the retained
source bytes exactly; any other target serializes the typed value and
reports what it cannot represent through the module's returned findings
(read them with [`write_report_str`](@ref) when they matter).
"""
write_str(m::PioModule; format::AbstractString) = first(write_report_str(m; format))

"""
    write_report_str(m::PioModule; format) -> (String, Vector{Diagnostic})

Compatibility spelling of `emit(m, format)`.
"""
function write_report_str(m::PioModule; format::AbstractString)
    handle = getfield(m, :handle)
    lib = getfield(handle, :lib)
    out_diagnostics = Ref{Ptr{Cvoid}}(C_NULL)
    s = GC.@preserve handle _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_write_str), Cstring,
              (Ptr{Cvoid}, Cstring, Ref{Ptr{Cvoid}}, Ref{Ptr{Cvoid}}),
              _module_ptr(handle), format, out_diagnostics, err)
    end
    findings = _diagnostics_of(_ -> out_diagnostics[], lib)
    return _take_string(lib, s), findings
end

"""
    write_file(m::PioModule, path; format=nothing) -> Vector{Diagnostic}

Compatibility spelling of `emit(m, format, path)`. Write the module to `path`
as the named target format, returning the
writer's findings. With no `format`, the module's own source format is the
target, which for an unchanged parsed module reproduces the source bytes
exactly. Directory formats (PyPSA CSV) write the folder at `path`. The
destination must not already exist.
"""
function write_file(m::PioModule, path::AbstractString;
                    format::Union{AbstractString,Nothing}=nothing)
    handle = getfield(m, :handle)
    lib = getfield(handle, :lib)
    target = format === nothing ? source_format(m) : String(format)
    target === nothing && error(
        "PowerIO.write_file: the module was built in memory and has no source \
         format; pass the target with format=")
    out_diagnostics = Ref{Ptr{Cvoid}}(C_NULL)
    GC.@preserve handle _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_write_file), Cint,
              (Ptr{Cvoid}, Cstring, Cstring, Ref{Ptr{Cvoid}}, Ref{Ptr{Cvoid}}),
              _module_ptr(handle), target, path, out_diagnostics, err)
    end
    return _diagnostics_of(_ -> out_diagnostics[], lib)
end

"""
    write_json(m::PioModule) -> String

The stored `.pio.json` version 1 document for any value kind.
"""
write_json(m::PioModule) = write_module(getfield(m, :handle))

"""
    emit(m::PioModule, format) -> (String, Vector{Diagnostic})
    emit(m::PioModule, format, destination) -> Vector{Diagnostic}

Emit a module in `format` as text or to a destination. With no destination,
the result contains the text and writer findings. File and directory
destinations follow the same rules as [`write_file`](@ref). The argument order
matches the Rust and Python surfaces: value, target format, then destination.
"""
emit(m::PioModule, format::AbstractString) = write_report_str(m; format)
emit(m::PioModule, format::AbstractString, destination::AbstractString) =
    write_file(m, destination; format)

"""
    to_json(m::PioModule) -> String

The stored `.pio.json` document for a module. On a network value,
`to_json(m.value)` remains the model-only JSON transport.
"""
to_json(m::PioModule) = write_json(m)

"""
    from_json(PioModule, text) -> PioModule
    from_json(BalancedNetwork, text) -> BalancedNetwork

Read stored module JSON or balanced model JSON through explicit type dispatch.
The one argument `from_json(text)` balanced model form remains available.
"""
from_json(::Type{PioModule}, text::AbstractString) = _wrap_module(read_module(text))
from_json(::Type{BalancedNetwork}, text::AbstractString) = from_json(text)

"""
    to_format(m::PioModule, format) -> (String, Vector{Diagnostic})

Compatibility positional spelling of `emit(m, format)`.
"""
to_format(m::PioModule, format::AbstractString) = write_report_str(m; format)

"""
    inspect(m::PioModule)

Value inspection and supported operation discovery: counts, the source
format, and the operations the value supports, decoded from the module's
inspection report.
"""
inspect(m::PioModule) = inspect_module(getfield(m, :handle))

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
    state_inventory(m::PioModule)

The time point or scenario inventory of a series or scenario set module.
Time point positions are one based, matching [`select_state`](@ref)'s `time`
keyword: the first time point has `position == 1`.
"""
function state_inventory(m::PioModule)
    raw = state_inventory(getfield(m, :handle))
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
    return length(state_inventory(m).time_points)
end
Base.firstindex(::PioModule{T}) where {T<:_INDEXABLE_TIME_SERIES} = 1
Base.lastindex(m::PioModule{T}) where {T<:_INDEXABLE_TIME_SERIES} = length(m)
Base.eachindex(m::PioModule{T}) where {T<:_INDEXABLE_TIME_SERIES} = Base.OneTo(length(m))
Base.getindex(m::PioModule{T}, i::Integer) where {T<:_INDEXABLE_TIME_SERIES} =
    select_state(m; time=i)
function Base.iterate(m::PioModule{T},
                      state::Tuple{Int,Int}=(1, length(m))) where {T<:_INDEXABLE_TIME_SERIES}
    i, n = state
    i > n && return nothing
    return m[i], (i + 1, n)
end

function Base.keys(m::PioModule{T}) where {T<:ScenarioSet}
    return String[String(row.id) for row in state_inventory(m).scenarios]
end
Base.length(m::PioModule{T}) where {T<:ScenarioSet} =
    length(state_inventory(m).scenarios)
Base.haskey(m::PioModule{T}, id::AbstractString) where {T<:ScenarioSet} =
    any(==(String(id)), keys(m))
Base.getindex(m::PioModule{T}, id::AbstractString) where {T<:ScenarioSet} =
    select_state(m; scenario=id)

# The raw v6 report is zero based, matching the C ABI (`export_state`'s
# `time_position`); this wrapper and `select_state`'s `time` keyword are one
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

"""
    dc_data(m::PioModule; formula="series_susceptance") -> DcData

The module's DC branch data as independently owned spans; see [`DcData`](@ref).
"""
dc_data(m::PioModule; formula::AbstractString="series_susceptance") =
    dc_data(getfield(m, :handle); formula)

function _require_complete_dc_branch_axis(data::DcData, operation::AbstractString)
    missing = omitted(data)
    isempty(missing) && return data
    details = join(("$id ($reason)" for (id, reason) in missing), ", ")
    noun = length(missing) == 1 ? "branch was" : "branches were"
    throw(ArgumentError(
        "$operation cannot return the complete branch table axis because " *
        "$(length(missing)) $noun omitted: $details; inspect dc_data(module) " *
        "for branch_ids and omitted rows",
    ))
end

"""
    calc_incidence_matrix(m::PioModule{BalancedNetwork}; formula="series_susceptance")

Calculate the canonical DC incidence matrix `A` as branches by buses, with
`+1` at the from bus and `-1` at the to bus.

The `BalancedNetwork` and path overloads retain their 0.10 bus by branch
orientation until 1.0. Parse the source first and pass its `PioModule` for the
canonical orientation.
"""
calc_incidence_matrix(m::PioModule{BalancedNetwork};
                      formula::AbstractString="series_susceptance") = begin
    data = dc_data(m; formula)
    _require_complete_dc_branch_axis(data, "calc_incidence_matrix")
    incidence_matrix(data)
end

"""
    calc_bus_susceptance_matrix(m::PioModule{BalancedNetwork}; formula="series_susceptance")

Calculate the canonical DC bus susceptance matrix
`B = A' * Diagonal(b) * A`. Phase
shift injections stay separate, so `B` remains symmetric.
"""
calc_bus_susceptance_matrix(m::PioModule{BalancedNetwork};
                            formula::AbstractString="series_susceptance") =
    susceptance_laplacian(dc_data(m; formula))

"""
    calc_branch_susceptance_matrix(m::PioModule{BalancedNetwork}; formula="series_susceptance")

Calculate the canonical DC branch matrix `Bf = Diagonal(b) * A`, as branches
by buses.
"""
calc_branch_susceptance_matrix(m::PioModule{BalancedNetwork};
                               formula::AbstractString="series_susceptance") = begin
    data = dc_data(m; formula)
    _require_complete_dc_branch_axis(data, "calc_branch_susceptance_matrix")
    flow_matrix(data)
end

"""
    calc_phase_shift_injection(m::PioModule{BalancedNetwork}; formula="series_susceptance")

Calculate `p_shift = A' * (b .* shift)` in canonical bus order. The phase
shift term stays separate from the symmetric bus susceptance matrix.
"""
calc_phase_shift_injection(m::PioModule{BalancedNetwork};
                           formula::AbstractString="series_susceptance") =
    copy(shift_injection(dc_data(m; formula)))

"""
    calc_branch_flow_dc(m::PioModule{BalancedNetwork}, voltage_angles;
                        formula="series_susceptance")

Compute `p_branch = -Bf * voltage_angles + b .* shift` in canonical branch
order. Voltage angles are in radians.
"""
calc_branch_flow_dc(m::PioModule{BalancedNetwork},
                    voltage_angles::AbstractVector{<:Real};
                    formula::AbstractString="series_susceptance") = begin
    data = dc_data(m; formula)
    _require_complete_dc_branch_axis(data, "calc_branch_flow_dc")
    branch_flow(data, voltage_angles)
end

"""
    select_state(m::PioModule; time=nothing, scenario=nothing) -> PioModule

Select one time point (one based, matching every other Julia axis) or one
named scenario as an independent static module. The selection shares the
base network's native data; nothing reparses or copies numerical tables.

A `TimeSeries{OperatingPoint{MulticonductorNetwork}}` module refuses with
`REQUEST.STATE.UNBOUND_EXPORT`: a multiconductor operating point selects and
reads in place, and static materialization is not implemented yet.
"""
function select_state(m::PioModule;
                      time::Union{Integer,Nothing}=nothing,
                      scenario::Union{AbstractString,Nothing}=nothing)
    (time === nothing) == (scenario === nothing) &&
        error("PowerIO.select_state: pass exactly one of time and scenario")
    if time !== nothing
        time >= 1 || error("PowerIO.select_state: time is one based; got $time")
    end
    handle = try
        export_state(getfield(m, :handle);
                     time_position=time === nothing ? nothing : time - 1,
                     scenario)
    catch err
        (time !== nothing && err isa PowerIOCError && err.code == "REQUEST.STATE.OUT_OF_RANGE") ||
            rethrow()
        _rebase_out_of_range(err, time)
    end
    return _wrap_module(handle)
end

# `err`'s message names the zero-based `time_position` this function passed
# to `export_state`, not the one-based `time` the caller passed to us;
# restate it in the caller's own terms. The code is unchanged so callers
# still branch on it.
function _rebase_out_of_range(err::PowerIOCError, time::Integer)
    axis = match(r"outside the (\d+) point axis", err.message)
    message = axis === nothing ?
        "time = $time is outside the time point axis" :
        "time = $time (the $(axis[1]) point axis accepts 1:$(axis[1]))"
    throw(PowerIOCError(err.code, message, err.diagnostics))
end

"""
    to_balanced(m::PioModule{MulticonductorNetwork}; base_mva=100.0) -> PioModule{BalancedNetwork}

Build the positive sequence balanced equivalent of a multiconductor value.
The pass appends its findings and one Transform history entry;
the source descriptors carry over, but not the retained bytes, so a later
write in the original format cannot echo the source exactly.
[`to_balanced_report`](@ref) reports the losses first without transforming.
"""
to_balanced(m::PioModule{MulticonductorNetwork}; base_mva::Real=100.0) =
    _wrap_module(lower_module_to_balanced(getfield(m, :handle); base_mva))

"""
    to_balanced_report(m::PioModule{MulticonductorNetwork}; base_mva=100.0)

Report the assumptions, losses, and blocking findings for [`to_balanced`](@ref)
without building the balanced equivalent.
"""
to_balanced_report(m::PioModule{MulticonductorNetwork}; base_mva::Real=100.0) =
    lowering_readiness(getfield(m, :handle); base_mva)

function lower_to_balanced(m::PioModule{MulticonductorNetwork}; base_mva::Real=100.0)
    return to_balanced(m; base_mva)
end

function lowering_readiness(m::PioModule{MulticonductorNetwork}; base_mva::Real=100.0)
    return to_balanced_report(m; base_mva)
end

function Base.show(io::IO, m::PioModule{T}) where {T}
    print(io, "PioModule{", T, "}")
    fmt = try
        source_format(m)
    catch
        nothing
    end
    fmt === nothing || print(io, " from ", fmt)
    n = try
        length(diagnostics(m))
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
# what `write_json` states, no whole network re-serialization beyond that
# wire.
_stored_document(m::PioModule) = JSON3.read(write_json(m))

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
[`sources`](@ref) remains a compatibility alias; `module_sources` avoids
confusion with distribution voltage source elements.
"""
function module_sources(m::PioModule)
    rows = get(_stored_document(m), :sources, nothing)
    rows === nothing && return ModuleSource[]
    return [ModuleSource(String(row.id), String(row.name), Int(row.byte_length),
                         _record_string(row, :format)) for row in rows]
end

"""Compatibility alias for [`module_sources`](@ref)."""
sources(m::PioModule) = module_sources(m)

# Read-only module forwarding. The value and module share the same native
# allocation, so these methods add Julia dispatch convenience without copying
# tables or changing ownership.
for f in (:buses, :branches, :generators, :loads, :shunts, :storage, :hvdc,
          :switches, :warnings,
          :n_buses, :n_branches, :n_generators, :n_gens, :n_switches,
          :base_mva, :base_frequency, :network_name, :reference_bus_id,
          :reference_bus_positions, :reference_bus_indices, :n_islands,
          :n_components, :is_radial)
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
to_matpower(m::PioModule{BalancedNetwork}) = to_matpower(getfield(m, :value))
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

parse_ac_power_data(m::PioModule{BalancedNetwork}; from=nothing,
                    filtered::Union{Bool,_DefaultPowerdataFilter}=_DEFAULT_POWERDATA_FILTER,
                    T::Type{<:Real}=Float64) =
    parse_ac_power_data(m, T; from, filtered)
function parse_ac_power_data(m::PioModule{BalancedNetwork}, ::Type{T}; from=nothing,
                             filtered::Union{Bool,_DefaultPowerdataFilter}=_DEFAULT_POWERDATA_FILTER) where {T<:Real}
    pd = to_powerdata(m, T; filtered)
    return _parse_ac_power_data_output(pd, T)
end
function parse_ac_power_data(m::PioModule{BalancedNetwork}, ::Type{T}, live::Val{:live};
                             from=nothing,
                             filtered::Union{Bool,_DefaultPowerdataFilter}=_DEFAULT_POWERDATA_FILTER) where {T<:Real}
    pd = to_powerdata(m, T, live; filtered)
    return _parse_ac_power_data_output(pd, T)
end

for f in (:calc_admittance_matrix, :calc_susceptance_matrix,
          :calc_bprime_matrix,
          :calc_bdoubleprime_matrix)
    @eval $f(m::PioModule{BalancedNetwork}) = $f(getfield(m, :value))
end
