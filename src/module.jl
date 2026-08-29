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
with [`state_inventory`](@ref) and select one entry with
[`select_state`](@ref).
"""
struct TimeSeries{T}
    handle::StoredModule
end

"""
    ScenarioSet{T}

The type parameter family for a module whose value is a set of named
alternatives: a GridFM Parquet dataset parses to
`PioModule{ScenarioSet{BalancedNetwork}}`. Scenario identifiers come from
[`state_inventory`](@ref); [`select_state`](@ref) selects one.
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
explain it (retained source, diagnostics, history). [`parse_file`](@ref) and
[`parse_bytes`](@ref) detect the source format and value kind once and wrap
the native owner; nothing reparses, serializes, or copies a network to give
the module its type.

```julia
using PowerIO
case = parse_file("switch.dss")
case isa PioModule{MulticonductorNetwork}  # true
case.value                                 # the multiconductor network
diagnostics(case)                          # the reader's findings
write_file(case, "copy.dss")               # byte exact same format echo
```

The type parameter drives ordinary dispatch: matrix, conversion, and
transformation methods accept the module whose value family they serve.
"""
struct PioModule{T}
    handle::StoredModule
    value::T
end

Base.propertynames(::PioModule) = (:value,)

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

Parse the case at `path` into a typed module of whichever built in value
family claims it. The path can name a file or a directory format profile (a
PyPSA CSV folder, a GridFM Parquet dataset). The format and value kind are
detected from the name and content; `format` selects a parser explicitly for
ambiguous or mislabeled input without changing the returned abstraction.

```julia
case = parse_file("case9.m")      # PioModule{BalancedNetwork}
feeder = parse_file("switch.dss") # PioModule{MulticonductorNetwork}
scuc = parse_file("scenario.json") # e.g. PioModule{AcScucInstance}
```
"""
parse_file(path::AbstractString; format::Union{AbstractString,Nothing}=nothing) =
    _wrap_module(parse_module(path; format))

"""
    parse_bytes(bytes; name="<memory>", format=nothing) -> PioModule
    parse_bytes(io::IO; name="<memory>", format=nothing) -> PioModule

Parse an in-memory source into a typed module: the only way to read a binary
format without a file, and the byte carrier behind stream input (an `IO`
reads once and parses the bytes). `name` labels the buffer for diagnostics
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
throws [`PowerIOCError`](@ref) carrying the same record shape.
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

Write the module as the named target format and return the text. Writing an
unchanged parsed module back to its own source format returns the retained
source bytes exactly; any other target serializes the typed value and
reports what it cannot represent through the module's returned findings
(read them with [`write_report_str`](@ref) when they matter).
"""
write_str(m::PioModule; format::AbstractString) = first(write_report_str(m; format))

"""
    write_report_str(m::PioModule; format) -> (String, Vector{Diagnostic})

[`write_str`](@ref) plus the writer's findings.
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

Write the module to `path` as the named target format, returning the
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
    lower_to_balanced(m::PioModule{MulticonductorNetwork}; base_mva=100.0) -> PioModule{BalancedNetwork}

The explicit lossy lowering from the multiconductor value to its balanced
equivalent. The pass appends its findings and one Transform history entry;
the source descriptors carry over, but not the retained bytes, so a later
write in the original format cannot echo the source exactly.
[`lowering_readiness`](@ref) reports the losses first without transforming.
"""
lower_to_balanced(m::PioModule{MulticonductorNetwork}; base_mva::Real=100.0) =
    _wrap_module(lower_module_to_balanced(getfield(m, :handle); base_mva))

"""
    lowering_readiness(m::PioModule{MulticonductorNetwork}; base_mva=100.0)

The readiness report of the balanced lowering: the inspect half of the
transformation.
"""
lowering_readiness(m::PioModule{MulticonductorNetwork}; base_mva::Real=100.0) =
    lowering_readiness(getfield(m, :handle); base_mva)

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
