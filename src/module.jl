# `PioModule{T}`: one typed value with its diagnostics and records, and the
# `parse` and `deserialize` operations that produce it.

"""
    PioModule{T}

One typed value together with the records that describe how it was produced.

- `m.value::T`: the value. Dispatch on `PioModule{BalancedNetwork}`,
  `PioModule{MulticonductorNetwork}`, `PioModule{TimeSeries{...}}`, and the
  other concrete parameters.
- `m.diagnostics::Vector{Diagnostic}`: the findings stored on the module.
- `m.producer::Producer`: the program that produced the module.
- `m.sources::Vector{ModuleSource}`: the sources it was read from.
- `m.history::Vector{HistoryEntry}`: the operations applied so far.

[`parse`](@ref) and [`deserialize`](@ref) return modules. [`emit`](@ref) and
[`serialize`](@ref) consume them. [`apply_updates!`](@ref) changes the value in
place and refreshes `m.value`.
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
    name === :diagnostics && return _module_diagnostics(m)
    name === :producer && return _module_producer(m)
    name === :sources && return _module_sources(m)
    name === :history && return _module_history(m)
    return getfield(m, name)
end

Base.propertynames(::PioModule, private::Bool=false) =
    private ? (:value, :diagnostics, :producer, :sources, :history, :handle) :
              (:value, :diagnostics, :producer, :sources, :history)

_lib_of(m::PioModule) = getfield(getfield(m, :handle), :lib)
_handle(m::PioModule) = getfield(m, :handle)

# --- sources ---------------------------------------------------------------

function _source_open(lib::AbstractString, path::AbstractString)
    path = String(path)
    ptr = _checked(lib) do err
        ccall(_library_symbol(lib, :pio_source_open), Ptr{Cvoid},
              (Ptr{UInt8}, Csize_t, Ref{Ptr{Cvoid}}), path, sizeof(path), err)
    end
    return SourceHandle(ptr, lib)
end

function _source_from_memory(lib::AbstractString, name::AbstractString, bytes::AbstractVector{UInt8})
    name = String(name)
    data = bytes isa Vector{UInt8} ? bytes : Vector{UInt8}(bytes)
    ptr = GC.@preserve data _checked(lib) do err
        ccall(_library_symbol(lib, :pio_source_from_memory), Ptr{Cvoid},
              (Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t, Ref{Ptr{Cvoid}}),
              name, sizeof(name), pointer(data), length(data), err)
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
function _wrap_module(lib::AbstractString, ptr::Ptr{Cvoid})
    handle = ModuleHandle(ptr, lib)
    return PioModule(handle, _module_value(lib, handle))
end

function _module_value(lib::AbstractString, handle::ModuleHandle)
    vptr = GC.@preserve handle ccall(_library_symbol(lib, :pio_module_value), Ptr{Cvoid},
                                     (Ptr{Cvoid},), _ptr(handle))
    return _wrap_value(lib, ValueHandle(vptr, lib), handle)
end

function _parse_source(lib::AbstractString, source::SourceHandle, format)
    fmt = format === nothing ? "" : String(format)
    ptr = GC.@preserve source _checked(lib) do err
        ccall(_library_symbol(lib, :pio_parse), Ptr{Cvoid},
              (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ref{Ptr{Cvoid}}),
              _ptr(source), format === nothing ? C_NULL : pointer(fmt), sizeof(fmt), err)
    end
    release!(source)
    return _wrap_module(lib, ptr)
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

These methods extend `Base.parse` so the bare name works after `using PowerIO`.
Parse failures throw [`PowerIOError`](@ref).
"""
function Base.parse(path::AbstractString; format::Union{AbstractString,Nothing}=nothing)
    lib = _checked_lib()
    return _parse_source(lib, _source_open(lib, path), format)
end

function Base.parse(io::IO; format::Union{AbstractString,Nothing}=nothing,
                    name::Union{AbstractString,Nothing}=nothing)
    lib = _checked_lib()
    source_name = name === nothing ? _stream_name(io) : String(name)
    return _parse_source(lib, _source_from_memory(lib, source_name, read(io)), format)
end

function Base.parse(bytes::AbstractVector{UInt8}; format::Union{AbstractString,Nothing}=nothing,
                    name::AbstractString="<memory>")
    lib = _checked_lib()
    return _parse_source(lib, _source_from_memory(lib, name, bytes), format)
end

"""
    deserialize(path::AbstractString) -> PioModule
    deserialize(io::IO) -> PioModule
    deserialize(bytes::AbstractVector{UInt8}) -> PioModule

Read one PowerIO IR document (`"schema": "powerio.module"`, `"version": 1`)
written by [`serialize`](@ref). PowerIO IR is not a grid exchange format;
[`parse`](@ref) does not accept it.
"""
function deserialize(path::AbstractString)
    lib = _checked_lib()
    return _deserialize_source(lib, _source_open(lib, path))
end
deserialize(io::IO) = deserialize(read(io))
function deserialize(bytes::AbstractVector{UInt8})
    lib = _checked_lib()
    return _deserialize_source(lib, _source_from_memory(lib, "module.pio.json", bytes))
end

function _deserialize_source(lib::AbstractString, source::SourceHandle)
    ptr = GC.@preserve source _checked(lib) do err
        ccall(_library_symbol(lib, :pio_module_deserialize), Ptr{Cvoid},
              (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), _ptr(source), err)
    end
    release!(source)
    return _wrap_module(lib, ptr)
end

# --- records ---------------------------------------------------------------

function _module_diagnostics(m::PioModule)
    lib = _lib_of(m)
    h = _handle(m)
    ptr = GC.@preserve h ccall(_library_symbol(lib, :pio_module_diagnostics), Ptr{Cvoid},
                               (Ptr{Cvoid},), _ptr(h))
    return _diagnostics(lib, ptr)
end

function _module_producer(m::PioModule)
    lib = _lib_of(m)
    h = _handle(m)
    view = GC.@preserve h _fill(PioModuleProducerView, lib) do out, err
        ccall(_library_symbol(lib, :pio_module_producer), Bool,
              (Ptr{Cvoid}, Ref{PioModuleProducerView}, Ref{Ptr{Cvoid}}), _ptr(h), out, err)
    end
    return Producer(_str(view.name), _str(view.version))
end

function _module_sources(m::PioModule)
    lib = _lib_of(m)
    h = _handle(m)
    return GC.@preserve h begin
        p = _ptr(h)
        n = Int(ccall(_library_symbol(lib, :pio_module_source_count), Csize_t, (Ptr{Cvoid},), p))
        map(1:n) do k
            v = _fill(PioModuleSourceView, lib) do out, err
                ccall(_library_symbol(lib, :pio_module_source_at), Bool,
                      (Ptr{Cvoid}, Csize_t, Ref{PioModuleSourceView}, Ref{Ptr{Cvoid}}),
                      p, Csize_t(k - 1), out, err)
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
    return GC.@preserve h begin
        p = _ptr(h)
        n = Int(ccall(_library_symbol(lib, :pio_module_history_count), Csize_t, (Ptr{Cvoid},), p))
        map(1:n) do k
            i = Csize_t(k - 1)
            v = _fill(PioModuleHistoryEntryView, lib) do out, err
                ccall(_library_symbol(lib, :pio_module_history_at), Bool,
                      (Ptr{Cvoid}, Csize_t, Ref{PioModuleHistoryEntryView}, Ref{Ptr{Cvoid}}),
                      p, i, out, err)
            end
            parameters = Dict{String,String}()
            for j in 1:Int(v.parameter_count)
                param = _fill(PioModuleHistoryParameterView, lib) do out, err
                    ccall(_library_symbol(lib, :pio_module_history_parameter_at), Bool,
                          (Ptr{Cvoid}, Csize_t, Csize_t, Ref{PioModuleHistoryParameterView}, Ref{Ptr{Cvoid}}),
                          p, i, Csize_t(j - 1), out, err)
                end
                parameters[_str(param.name)] = _str(param.value_kind)
            end
            assumptions = [_str(_checked(lib) do err
                ccall(_library_symbol(lib, :pio_module_history_assumption_at), PioStringView,
                      (Ptr{Cvoid}, Csize_t, Csize_t, Ref{Ptr{Cvoid}}), p, i, Csize_t(j - 1), err)
            end) for j in 1:Int(v.assumption_count)]
            losses = [_str(_checked(lib) do err
                ccall(_library_symbol(lib, :pio_module_history_loss_at), PioStringView,
                      (Ptr{Cvoid}, Csize_t, Csize_t, Ref{Ptr{Cvoid}}), p, i, Csize_t(j - 1), err)
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
