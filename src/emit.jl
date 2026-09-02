# `emit` for grid exchange formats and `serialize` for PowerIO IR.

"""
    EmittedFile

One file produced by [`emit`](@ref) or [`serialize`](@ref). `name` is the
file name. `data` holds the content after an in-memory emission and is
`nothing` after a write to disk; `path` holds the written path after a write
to disk and is `nothing` for an in-memory emission.
"""
struct EmittedFile
    name::String
    data::Union{Vector{UInt8},Nothing}
    path::Union{String,Nothing}
end

"""
    EmitResult

What one emission produced.

- `files::Vector{EmittedFile}`: one entry per file.
- `layout::String`: `"file"` or `"directory"`.
- `fidelity::String`: `"exact_same_format"` when the output is the original
  file content the reader kept, `"canonical"` for freshly written output.
- `diagnostics::Vector{Diagnostic}`: what the writer kept, defaulted, or
  could not carry.
- `text`: the content of the one in-memory UTF-8 file as a `String`, or
  `nothing` when the result holds anything else.
"""
struct EmitResult
    files::Vector{EmittedFile}
    layout::String
    fidelity::String
    diagnostics::Vector{Diagnostic}
end

function Base.getproperty(r::EmitResult, name::Symbol)
    if name === :text
        files = getfield(r, :files)
        length(files) == 1 || return nothing
        data = files[1].data
        data === nothing && return nothing
        return isvalid(String, data) ? String(copy(data)) : nothing
    end
    return getfield(r, name)
end

Base.propertynames(::EmitResult, private::Bool=false) =
    (:files, :layout, :fidelity, :diagnostics, :text)

function Base.show(io::IO, r::EmitResult)
    print(io, "EmitResult(", length(r.files), " file", length(r.files) == 1 ? "" : "s",
          ", ", r.layout, ", ", r.fidelity, ", ", length(r.diagnostics), " diagnostic",
          length(r.diagnostics) == 1 ? "" : "s", ")")
end

# --- destinations ----------------------------------------------------------

function _destination_path(lib::AbstractString, path::AbstractString)
    path = String(path)
    ptr = _checked(lib) do err
        ccall(_library_symbol(lib, :pio_destination_path), Ptr{Cvoid},
              (Ptr{UInt8}, Csize_t, Ref{Ptr{Cvoid}}), path, sizeof(path), err)
    end
    return DestinationHandle(ptr, lib)
end

function _destination_memory(lib::AbstractString, root::AbstractString)
    root = String(root)
    ptr = _checked(lib) do err
        ccall(_library_symbol(lib, :pio_destination_memory), Ptr{Cvoid},
              (Ptr{UInt8}, Csize_t, Ref{Ptr{Cvoid}}), root, sizeof(root), err)
    end
    return DestinationHandle(ptr, lib)
end

# Read the file list of an emit result handle and release it.
function _emit_result(lib::AbstractString, ptr::Ptr{Cvoid}, in_memory::Bool)
    h = EmitResultHandle(ptr, lib)
    result = GC.@preserve h begin
        p = _ptr(h)
        layout = _str(ccall(_library_symbol(lib, :pio_emit_result_layout), PioStringView, (Ptr{Cvoid},), p))
        fidelity = _str(ccall(_library_symbol(lib, :pio_emit_result_fidelity), PioStringView, (Ptr{Cvoid},), p))
        n = Int(ccall(_library_symbol(lib, :pio_emit_result_artifact_count), Csize_t, (Ptr{Cvoid},), p))
        files = map(1:n) do k
            fptr = _checked(lib) do err
                ccall(_library_symbol(lib, :pio_emit_result_artifact), Ptr{Cvoid},
                      (Ptr{Cvoid}, Csize_t, Ref{Ptr{Cvoid}}), p, Csize_t(k - 1), err)
            end
            f = EmittedFileHandle(fptr, lib)
            file = GC.@preserve f begin
                name = _str(ccall(_library_symbol(lib, :pio_artifact_name), PioStringView, (Ptr{Cvoid},), _ptr(f)))
                if in_memory
                    EmittedFile(name, _bytes(ccall(_library_symbol(lib, :pio_artifact_bytes), PioByteView,
                                                   (Ptr{Cvoid},), _ptr(f))), nothing)
                else
                    EmittedFile(basename(name), nothing, name)
                end
            end
            release!(f)
            file
        end
        diagnostics = _diagnostics(lib, ccall(_library_symbol(lib, :pio_emit_result_diagnostics), Ptr{Cvoid},
                                              (Ptr{Cvoid},), p))
        EmitResult(files, layout, fidelity, diagnostics)
    end
    release!(h)
    return result
end

# Run one output operation against a destination. `destination` is `nothing`
# (in memory), a path, or a writable `IO` that receives the single file.
# `root` names the in-memory destination; file names carry it as a prefix.
function _output(op, m::PioModule, destination, what::AbstractString, root::AbstractString)
    lib = _lib_of(m)
    h = _handle(m)
    if destination === nothing || destination isa IO
        dest = _destination_memory(lib, root)
        result = GC.@preserve h dest _emit_result(lib, op(lib, _ptr(h), _ptr(dest)), true)
        release!(dest)
        if destination isa IO
            length(result.files) == 1 || throw(ArgumentError(
                "PowerIO.$what: a stream destination accepts one file, this emission produced " *
                "$(length(result.files)); pass a directory path instead"))
            write(destination, result.files[1].data)
        end
        return result
    elseif destination isa AbstractString
        dest = _destination_path(lib, destination)
        result = GC.@preserve h dest _emit_result(lib, op(lib, _ptr(h), _ptr(dest)), false)
        release!(dest)
        return result
    else
        throw(ArgumentError("PowerIO.$what: destination must be nothing, a path, or an IO"))
    end
end

"""
    emit(m::PioModule, format, destination=nothing) -> EmitResult

Write the module's value as the grid exchange format named by `format`
(`"matpower"`, `"psse"`, `"xiidm"`, `"cgmes"`, `"dss"`, `"pmd"`, `"bmopf"`,
`"powermodels-json"`, `"pypsa-csv"`, and the other canonical tokens). With
`destination === nothing` the files stay in memory. A path writes one file
or a directory. A writable `IO` receives the single file.

When the module was read from the same format and its value is unchanged,
the output is the original file content (`fidelity == "exact_same_format"`).
Anything the target cannot carry is reported in `result.diagnostics`.
"""
function emit(m::PioModule, format::AbstractString, destination=nothing)
    fmt = String(format)
    return _output(m, destination, "emit", "case") do lib, module_ptr, dest_ptr
        _checked(lib) do err
            ccall(_library_symbol(lib, :pio_emit), Ptr{Cvoid},
                  (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ptr{Cvoid}, Ref{Ptr{Cvoid}}),
                  module_ptr, fmt, sizeof(fmt), dest_ptr, err)
        end
    end
end

"""
    serialize(m::PioModule, destination=nothing) -> EmitResult

Write the module as PowerIO IR: one JSON document holding the typed value
with its diagnostics, producer, sources, source mappings, history, and
extensions. Read it back with [`deserialize`](@ref). PowerIO IR carries
PowerIO values between PowerIO consumers; use [`emit`](@ref) for other tools.
"""
function serialize(m::PioModule, destination=nothing)
    return _output(m, destination, "serialize", "module.pio.json") do lib, module_ptr, dest_ptr
        _checked(lib) do err
            ccall(_library_symbol(lib, :pio_module_serialize), Ptr{Cvoid},
                  (Ptr{Cvoid}, Ptr{Cvoid}, Ref{Ptr{Cvoid}}), module_ptr, dest_ptr, err)
        end
    end
end
