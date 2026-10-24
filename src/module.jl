# `PioModule{T}`: one typed value with its diagnostics and records, and the
# `parse` and `deserialize` operations that produce it.

"""
    PioModule{T}

One typed value together with the records that describe how it was produced.

- `m.value::T`: the value. Dispatch on `PioModule{BalancedNetwork}`,
  `PioModule{MulticonductorNetwork}`, `PioModule{TimeSeries{...}}`, and the
  other concrete parameters.
- `m.type_name::String`: the library's structural type name for that value,
  such as `"powerio.BalancedNetwork"`. It also names a type this release does
  not bind, where `m.value` is an [`UnknownValue`](@ref).
- `m.diagnostics::Vector{Diagnostic}`: the findings stored on the module.
- `m.producer::Producer`: the program that produced the module.
- `m.sources::Vector{ModuleSource}`: the sources it was read from.
- `m.history::Vector{HistoryEntry}`: the operations applied so far.

[`parse`](@ref) and [`deserialize`](@ref) return modules. [`emit`](@ref) and
[`serialize`](@ref) consume them. [`apply_updates!`](@ref) changes the value in
place and refreshes `m.value`; access through the shared handle is synchronized.
"""
mutable struct PioModule{T}
    handle::ModuleHandle
    value::T
end

"""
    Producer(name, version)

The program identity recorded with a module.
"""
struct Producer
    name::String
    version::String
end

"""
    ModuleSource

One source recorded with a module: its `id`, `name`, `byte_length`, the
`format` token when the reader recorded one, and the `digest_algorithm` and
`digest` when a digest was recorded.
"""
struct ModuleSource
    id::String
    name::String
    byte_length::UInt64
    format::Union{String,Nothing}
    digest_algorithm::Union{String,Nothing}
    digest::Union{String,Nothing}
end

"""
    HistoryEntry

One operation recorded in module history: its `id`, `kind`, `name`, the
`input_type` and `output_type` structural names when recorded, the named
`parameters` as a `Dict{String,String}` of parameter name to value kind, and
the `assumptions` and `losses` the operation declared.
"""
struct HistoryEntry
    id::String
    kind::String
    name::String
    input_type::Union{String,Nothing}
    output_type::Union{String,Nothing}
    parameters::Dict{String,String}
    assumptions::Vector{String}
    losses::Vector{String}
end

function Base.getproperty(m::PioModule, name::Symbol)
    name === :value && return _with_handles(getfield(m, :handle)) do
        getfield(m, :value)
    end
    name === :type_name && return _module_type_name(m)
    name === :diagnostics && return _module_diagnostics(m)
    name === :producer && return _module_producer(m)
    name === :sources && return _module_sources(m)
    name === :history && return _module_history(m)
    return getfield(m, name)
end

Base.propertynames(::PioModule, private::Bool=false) =
    private ? (:value, :type_name, :diagnostics, :producer, :sources, :history, :handle) :
              (:value, :type_name, :diagnostics, :producer, :sources, :history)

_lib_of(m::PioModule) = getfield(getfield(m, :handle), :lib)
_handle(m::PioModule) = getfield(m, :handle)

# --- sources ---------------------------------------------------------------

function _source_open(lib::AbstractString, path::AbstractString)
    path = String(path)
    ptr = _checked(lib) do err
        @capi lib :pio_source_open(path, sizeof(path), err)
    end
    return SourceHandle(ptr, lib)
end

function _source_from_memory(lib::AbstractString, name::AbstractString, bytes::AbstractVector{UInt8};
                             named_buffers::Union{AbstractDict,Nothing}=nothing)
    name = String(name)
    data = bytes isa Vector{UInt8} ? bytes : Vector{UInt8}(bytes)
    ptr = if named_buffers === nothing
        @with_handles data name _checked(lib) do err
            @capi lib :pio_source_from_memory(name, sizeof(name), pointer(data), length(data), err)
        end
    else
        names = String[]
        buffers = Vector{UInt8}[]
        for (key, value) in named_buffers
            key isa AbstractString || throw(ArgumentError("named buffer names must be strings"))
            value isa AbstractVector{UInt8} || throw(ArgumentError("named buffers must contain byte vectors"))
            push!(names, String(key))
            push!(buffers, Vector{UInt8}(value))
        end
        @with_handles data name names buffers begin
            views = [PioNamedBufferView(PioStringView(pointer(n), sizeof(n)),
                                       PioByteView(pointer(b), length(b)))
                     for (n, b) in zip(names, buffers)]
            @with_handles views _checked(lib) do err
                @capi lib :pio_source_from_memory_with_buffers(
                    name, sizeof(name), pointer(data), length(data), pointer(views), length(views), err)
            end
        end
    end
    return SourceHandle(ptr, lib)
end

# The source name of an open stream, for format detection and diagnostics.
function _stream_name(io::IO)
    if io isa IOStream
        raw = io.name
        m = match(r"^<file (.*)>$", raw)
        return m === nothing ? raw : String(m.captures[1])
    end
    return "<memory>"
end

# Wrap a module pointer, resolving the value type from its structural name.
function _wrap_module(lib::AbstractString, ptr::Ptr)
    handle = ModuleHandle(ptr, lib)
    return PioModule(handle, _module_value(lib, handle))
end

# Wrap a module pointer whose value the caller expects to be a `V`. For a
# concrete `V` the type is a static parameter, so the wrapped module is a
# concrete `PioModule{V}` and nothing is chosen at run time: the form
# `juliac --trim=safe` can compile (`isconcretetype(V)` folds at compile time).
# A family such as `TimeSeries`, `CalculationInstance`, or `Any` resolves the
# value type at run time and checks that it belongs to `V`. Either way a value
# of another type is an `ArgumentError` naming what `origin` holds, and the
# module is released at once rather than at finalization.
function _wrap_module(::Type{V}, lib::AbstractString, ptr::Ptr, origin::AbstractString) where {V}
    isconcretetype(V) || return _expect_value(V, _wrap_module(lib, ptr), origin)
    handle = ModuleHandle(ptr, lib)
    vptr = @with_handles handle @capi lib :pio_module_value(_ptr(handle))
    value = try
        _wrap_value(V, lib, ValueHandle(vptr, lib), handle, origin)
    catch
        release!(handle)
        rethrow()
    end
    return PioModule{V}(handle, value)
end

function _expect_value(::Type{V}, m::PioModule, origin::AbstractString) where {V}
    getfield(m, :value) isa V && return m
    name = _module_type_name(m)
    release!(_handle(m))
    throw(ArgumentError("PowerIO: expected a " * string(V) * " from " * origin * ", found a " * name))
end

function _module_value(lib::AbstractString, handle::ModuleHandle)
    vptr = @with_handles handle @capi lib :pio_module_value(_ptr(handle))
    return _wrap_value(lib, ValueHandle(vptr, lib), handle)
end

"""
    SincalReadOptions(; variant=nothing, snapshot_hours=nothing, acquired_tables=nothing,
                      assume_inactive_source_controls=false)

Explicit conductor-resolved SINCAL selection. `variant` is a native ID;
`snapshot_hours` selects a daily snapshot. `acquired_tables` is a relative
companion name for explicitly acquired Access records. Parsing retains the
original MDB and verifies its length/hash; it never runs an acquisition tool.
Use with `parse(...; format="sincal-multiconductor", sincal_multiconductor=...)`.
`assume_inactive_source_controls=true` opts into experimental schema-11.5 NULL
source-control defaults. Every applied assumption emits a diagnostic.
"""
struct SincalReadOptions
    variant::Union{Int64,Nothing}
    snapshot_hours::Union{Float64,Nothing}
    acquired_tables::Union{String,Nothing}
    assume_inactive_source_controls::Bool
end

function SincalReadOptions(; variant::Union{Integer,Nothing}=nothing,
                          snapshot_hours::Union{Real,Nothing}=nothing,
                          acquired_tables::Union{AbstractString,Nothing}=nothing,
                          assume_inactive_source_controls::Bool=false)
    variant isa Bool && throw(ArgumentError("variant must be an integer ID, not Bool"))
    snapshot_hours isa Bool && throw(ArgumentError("snapshot_hours must be a number, not Bool"))
    return SincalReadOptions(variant === nothing ? nothing : Int64(variant),
        snapshot_hours === nothing ? nothing : Float64(snapshot_hours),
        acquired_tables === nothing ? nothing : String(acquired_tables),
        assume_inactive_source_controls)
end

"""
    SincalBalancedReadOptions(; variant=nothing, snapshot_hours=nothing, acquired_tables=nothing)

Explicit balanced SINCAL selection. Use with `format="sincal-balanced"` and
`sincal_balanced=...`. The optional Access companion is verified against the
original MDB; parsing never runs an external acquisition tool.
"""
struct SincalBalancedReadOptions
    variant::Union{Int64,Nothing}
    snapshot_hours::Union{Float64,Nothing}
    acquired_tables::Union{String,Nothing}
end

function SincalBalancedReadOptions(; variant::Union{Integer,Nothing}=nothing,
                          snapshot_hours::Union{Real,Nothing}=nothing,
                          acquired_tables::Union{AbstractString,Nothing}=nothing)
    variant isa Bool && throw(ArgumentError("variant must be an integer ID, not Bool"))
    snapshot_hours isa Bool && throw(ArgumentError("snapshot_hours must be a number, not Bool"))
    return SincalBalancedReadOptions(variant === nothing ? nothing : Int64(variant),
        snapshot_hours === nothing ? nothing : Float64(snapshot_hours),
        acquired_tables === nothing ? nothing : String(acquired_tables))
end

_optional_input_view(s) = s === nothing ? PioStringView(C_NULL, 0) : PioStringView(pointer(s), sizeof(s))

function _parse_source(::Type{V}, lib::AbstractString, source::SourceHandle, format, origin::AbstractString;
                       sincal_multiconductor::Union{SincalReadOptions,Nothing}=nothing,
                       sincal_balanced::Union{SincalBalancedReadOptions,Nothing}=nothing,
                       acquisition_root::Union{AbstractString,Nothing}=nothing) where {V}
    fmt = format === nothing ? "" : String(format)
    try
        ptr = if sincal_multiconductor === nothing && sincal_balanced === nothing && acquisition_root === nothing
            @with_handles source fmt _checked(lib) do err
                @capi lib :pio_parse(_ptr(source), format === nothing ? C_NULL : pointer(fmt), sizeof(fmt), err)
            end
        else
            root = acquisition_root === nothing ? nothing : String(acquisition_root)
            choice = sincal_multiconductor === nothing ? SincalReadOptions() : sincal_multiconductor
            tables = choice.acquired_tables
            balanced = sincal_balanced === nothing ? SincalBalancedReadOptions() : sincal_balanced
            balanced_tables = balanced.acquired_tables
            @with_handles source fmt root tables balanced_tables begin
                selected = Ref(PioSincalReadOptions(choice.variant !== nothing,
                    something(choice.variant, Int64(0)), choice.snapshot_hours !== nothing,
                    something(choice.snapshot_hours, 0.0), _optional_input_view(tables), choice.assume_inactive_source_controls))
                selected_balanced = Ref(PioSincalBalancedReadOptions(balanced.variant !== nothing,
                    something(balanced.variant, Int64(0)), balanced.snapshot_hours !== nothing,
                    something(balanced.snapshot_hours, 0.0), _optional_input_view(balanced_tables)))
                @with_handles selected selected_balanced begin
                    options = Ref(PioParseOptions(_optional_input_view(root),
                        sincal_multiconductor === nothing ? C_NULL : Base.unsafe_convert(Ptr{PioSincalReadOptions}, selected),
                        sincal_balanced === nothing ? C_NULL : Base.unsafe_convert(Ptr{PioSincalBalancedReadOptions}, selected_balanced)))
                    @with_handles options _checked(lib) do err
                        @capi lib :pio_parse_with_options(_ptr(source),
                            format === nothing ? C_NULL : pointer(fmt), sizeof(fmt), options, err)
                    end
                end
            end
        end
        return _wrap_module(V, lib, ptr, origin)
    finally
        release!(source)
    end
end

# The value types a source can be parsed as by name: `parse(BalancedNetwork, path)`.
const _ParsedValue = Union{BalancedNetwork,MulticonductorNetwork,ContingencySet,SubsystemSet,
                           MonitoredSet,GeoLayer,CalculationInstance,CalculationSolution,
                           TimeSeries,ScenarioSet,OperatingPoint}

# What `parse` and `deserialize` read: a path, a stream, or bytes in memory.
const _Source = Union{AbstractString,IO,AbstractVector{UInt8}}

# A module type names one value type, so `PioModule{V}` asks for a concrete `V`
# (`isconcretetype` folds at compile time; nothing is checked at run time).
function _module_value_type(::Type{V}) where {V}
    isconcretetype(V) ||
        throw(ArgumentError("PowerIO: no source holds a PioModule{" * string(V) * "}; ask for the value, " *
                            string(V) * ", to accept any member"))
    return V
end

"""
    parse(path::AbstractString; format=nothing) -> PioModule
    parse(io::IO; format=nothing, name=nothing) -> PioModule
    parse(bytes::AbstractVector{UInt8}; format=nothing, name="<memory>") -> PioModule

Parse one grid exchange source into a typed module. A string is a path to a
file or directory. An `IO` or byte vector is read in memory; `name` supplies
the source name for format detection and diagnostics (an open file stream
uses its path). `format` is a canonical format token such as `"matpower"`,
`"psse"`, or `"dss"`; when omitted, the source name and content select the
format.

The value type follows the source: MATPOWER, PSS/E, XIIDM, CGMES, and the
other balanced formats give `PioModule{BalancedNetwork}`; OpenDSS, PMD JSON,
and BMOPF give `PioModule{MulticonductorNetwork}`; PyPSA and GridFM folders
give time series and scenario sets; GO Challenge 3 and OPFData give
calculation instances and solutions.

Explicit `sincal_multiconductor=SincalReadOptions(...)` requires the matching
`format="sincal-multiconductor"`. Balanced inputs use
`sincal_balanced=SincalBalancedReadOptions(...)` and `format="sincal-balanced"`.
Path inputs may widen their acquisition root
with `acquisition_root`; memory inputs receive `named_buffers` and never read
companions from disk. C/Julia options do not change the returned network family.

These methods extend `Base.parse` so the bare name works after `using PowerIO`.
Parse failures throw [`PowerIOError`](@ref).

    parse(V, source; kwargs...) -> V
    parse(PioModule{V}, source; kwargs...) -> PioModule{V}

The same, for a source whose value type the caller knows. As with
`parse(T, str)` in Base, the result is a `V`: `parse(BalancedNetwork,
"case14.m")` is the network and `parse(AcScucInstance, path)` the instance,
each keeping its module's data alive. Ask for `PioModule{V}` to keep the module
itself, for [`emit`](@ref), [`apply_updates!`](@ref), or its records;
`parse(PioModule, source)` is the untyped form. For a concrete `V` both results
are inferred, where the untyped form's is not, so these are the forms to call
from code compiled with `juliac --trim=safe`.

`V` may also name a family, such as `TimeSeries` or `CalculationInstance`: the
value type is then resolved at run time and must belong to it. A module type
names one value type, so `PioModule{V}` takes a concrete `V`. A source that
holds another kind of value is an `ArgumentError` naming what it holds.
"""
Base.parse(source::_Source; kwargs...) = _parse(Any, source; kwargs...)
Base.parse(::Type{PioModule}, source::_Source; kwargs...) = _parse(Any, source; kwargs...)
Base.parse(::Type{PioModule{V}}, source::_Source; kwargs...) where {V<:_ParsedValue} =
    _parse(_module_value_type(V), source; kwargs...)
Base.parse(::Type{V}, source::_Source; kwargs...) where {V<:_ParsedValue} =
    getfield(_parse(V, source; kwargs...), :value)

function _parse(::Type{V}, path::AbstractString; format::Union{AbstractString,Nothing}=nothing,
                sincal_multiconductor::Union{SincalReadOptions,Nothing}=nothing,
                sincal_balanced::Union{SincalBalancedReadOptions,Nothing}=nothing,
                acquisition_root::Union{AbstractString,Nothing}=nothing,
                named_buffers::Union{AbstractDict,Nothing}=nothing) where {V}
    named_buffers === nothing || throw(ArgumentError("named_buffers applies only to memory/IO sources"))
    lib = _checked_lib()
    path = String(path)
    return _parse_source(V, lib, _source_open(lib, path), format, path; sincal_multiconductor, sincal_balanced, acquisition_root)
end

function _parse(::Type{V}, io::IO; format::Union{AbstractString,Nothing}=nothing,
                name::Union{AbstractString,Nothing}=nothing,
                sincal_multiconductor::Union{SincalReadOptions,Nothing}=nothing,
                sincal_balanced::Union{SincalBalancedReadOptions,Nothing}=nothing,
                named_buffers::Union{AbstractDict,Nothing}=nothing,
                acquisition_root::Union{AbstractString,Nothing}=nothing) where {V}
    acquisition_root === nothing || throw(ArgumentError("acquisition_root applies only to path sources"))
    lib = _checked_lib()
    source_name = name === nothing ? _stream_name(io) : String(name)
    return _parse_source(V, lib, _source_from_memory(lib, source_name, read(io); named_buffers), format, source_name;
                         sincal_multiconductor, sincal_balanced)
end

function _parse(::Type{V}, bytes::AbstractVector{UInt8}; format::Union{AbstractString,Nothing}=nothing,
                name::AbstractString="<memory>",
                sincal_multiconductor::Union{SincalReadOptions,Nothing}=nothing,
                sincal_balanced::Union{SincalBalancedReadOptions,Nothing}=nothing,
                named_buffers::Union{AbstractDict,Nothing}=nothing,
                acquisition_root::Union{AbstractString,Nothing}=nothing) where {V}
    acquisition_root === nothing || throw(ArgumentError("acquisition_root applies only to path sources"))
    lib = _checked_lib()
    return _parse_source(V, lib, _source_from_memory(lib, name, bytes; named_buffers), format, String(name);
                         sincal_multiconductor, sincal_balanced)
end

"""
    deserialize(path::AbstractString) -> PioModule
    deserialize(io::IO) -> PioModule
    deserialize(bytes::AbstractVector{UInt8}) -> PioModule
    deserialize(V, source) -> V
    deserialize(PioModule{V}, source) -> PioModule{V}

Read one PowerIO IR document written by [`serialize`](@ref): `"schema":
"pio-ir"` and integer generation `"version": 2`. The `producer` record names
the PowerIO release that wrote it independently. This release reads generation
2 and refuses other generations, naming the version it found. A structural type
requires a reader that implements it. PowerIO IR is
not a grid exchange format; [`parse`](@ref) does not accept it.

The value type may be named as with [`parse`](@ref): `deserialize(BalancedNetwork,
path)` is the network, `deserialize(PioModule{BalancedNetwork}, path)` its
module, each inferred, and a document that holds another kind of value is an
`ArgumentError`.
"""
deserialize(source::_Source) = _deserialize(Any, source)
deserialize(::Type{PioModule}, source::_Source) = _deserialize(Any, source)
deserialize(::Type{PioModule{V}}, source::_Source) where {V<:_ParsedValue} =
    _deserialize(_module_value_type(V), source)
deserialize(::Type{V}, source::_Source) where {V<:_ParsedValue} = getfield(_deserialize(V, source), :value)

_deserialize(::Type{V}, io::IO) where {V} = _deserialize(V, read(io))
function _deserialize(::Type{V}, path::AbstractString) where {V}
    lib = _checked_lib()
    path = String(path)
    return _deserialize_source(V, lib, _source_open(lib, path), path)
end
function _deserialize(::Type{V}, bytes::AbstractVector{UInt8}) where {V}
    lib = _checked_lib()
    name = "module.pio.json"
    return _deserialize_source(V, lib, _source_from_memory(lib, name, bytes), name)
end

function _deserialize_source(::Type{V}, lib::AbstractString, source::SourceHandle, origin::AbstractString) where {V}
    ptr = try
        @with_handles source _checked(lib) do err
            @capi lib :pio_module_deserialize(_ptr(source), err)
        end
    finally
        release!(source)
    end
    return _wrap_module(V, lib, ptr, origin)
end

# --- records ---------------------------------------------------------------

# The structural type name the library reports for the module's current value.
# Reading it from the module rather than from `m.value` keeps it correct after
# `apply_updates!` and for a value type this release does not bind.
function _module_type_name(m::PioModule)
    lib = _lib_of(m)
    h = _handle(m)
    return @with_handles h begin
        value = ValueHandle(@capi(lib, :pio_module_value(_ptr(h))), lib)
        name = _value_type_name(lib, value)
        release!(value)
        name
    end
end

function _module_diagnostics(m::PioModule)
    lib = _lib_of(m)
    h = _handle(m)
    ptr = @with_handles h @capi lib :pio_module_diagnostics(_ptr(h))
    return _diagnostics(lib, ptr)
end

function _module_producer(m::PioModule)
    lib = _lib_of(m)
    h = _handle(m)
    return @with_handles h begin
        view = _fill(PioModuleProducerView, lib) do out, err
            @capi lib :pio_module_producer(_ptr(h), out, err)
        end
        Producer(_str(view.name), _str(view.version))
    end
end

function _module_sources(m::PioModule)
    lib = _lib_of(m)
    h = _handle(m)
    return @with_handles h begin
        p = _ptr(h)
        n = Int(@capi lib :pio_module_source_count(p))
        map(1:n) do k
            v = _fill(PioModuleSourceView, lib) do out, err
                @capi lib :pio_module_source_at(p, Csize_t(k - 1), out, err)
            end
            ModuleSource(_str(v.id), _str(v.name), v.byte_length,
                         _optional_str(v.format, v.has_format),
                         _optional_str(v.digest_algorithm, v.has_digest),
                         _optional_str(v.digest, v.has_digest))
        end
    end
end

function _module_history(m::PioModule)
    lib = _lib_of(m)
    h = _handle(m)
    return @with_handles h begin
        p = _ptr(h)
        n = Int(@capi lib :pio_module_history_count(p))
        map(1:n) do k
            i = Csize_t(k - 1)
            v = _fill(PioModuleHistoryEntryView, lib) do out, err
                @capi lib :pio_module_history_at(p, i, out, err)
            end
            parameters = Dict{String,String}()
            for j in 1:Int(v.parameter_count)
                param = _fill(PioModuleHistoryParameterView, lib) do out, err
                    @capi lib :pio_module_history_parameter_at(p, i, Csize_t(j - 1), out, err)
                end
                parameters[_str(param.name)] = _str(param.value_kind)
            end
            assumptions = [_str(_checked(lib) do err
                @capi lib :pio_module_history_assumption_at(p, i, Csize_t(j - 1), err)
            end) for j in 1:Int(v.assumption_count)]
            losses = [_str(_checked(lib) do err
                @capi lib :pio_module_history_loss_at(p, i, Csize_t(j - 1), err)
            end) for j in 1:Int(v.loss_count)]
            HistoryEntry(_str(v.id), _str(v.kind), _str(v.name),
                         _optional_str(v.input_type, v.has_input_type),
                         _optional_str(v.output_type, v.has_output_type),
                         parameters, assumptions, losses)
        end
    end
end

# --- display ---------------------------------------------------------------

function Base.show(io::IO, m::PioModule{T}) where {T}
    print(io, "PioModule{", T, "}")
    if !get(io, :compact, false)
        n = try
            length(m.diagnostics)
        catch
            nothing
        end
        n === nothing || print(io, " with ", n, " diagnostic", n == 1 ? "" : "s")
    end
end
