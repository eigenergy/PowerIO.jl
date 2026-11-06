"""
    InputCollection(path; max_bytes=64<<20, max_files=4096)
    InputCollection(files::AbstractDict; name="collection", max_bytes=64<<20, max_files=4096)
    InputCollection(bytes::AbstractVector{UInt8}; name="collection.zip", max_bytes=64<<20, max_files=4096)

A bounded, immutable folder/ZIP/named-file inventory. `inspect_collection(collection)`
returns metadata and selection suggestions without parsing every case. Call
`parse(collection, selection)` explicitly. `close` releases the inventory;
previously returned modules retain their sources and remain usable.
"""
struct InputCollection
    handle::CollectionHandle
end

function _collection_limits(max_bytes, max_files)
    max_bytes isa Bool && throw(ArgumentError("max_bytes must be a positive integer"))
    max_files isa Bool && throw(ArgumentError("max_files must be a positive integer"))
    max_bytes > 0 && max_files > 0 || throw(ArgumentError("collection limits must be positive"))
    return UInt64(max_bytes), Csize_t(max_files)
end

function InputCollection(path::AbstractString; max_bytes::Integer=64<<20, max_files::Integer=4096)
    max_bytes, max_files = _collection_limits(max_bytes, max_files)
    lib, path = _checked_lib(), String(path)
    ptr = @with_handles path _checked(lib) do err
        @capi lib :pio_collection_open(path, sizeof(path), max_bytes, max_files, err)
    end
    return InputCollection(CollectionHandle(ptr, lib))
end

function InputCollection(bytes::AbstractVector{UInt8}; name::AbstractString="collection.zip",
                         max_bytes::Integer=64<<20, max_files::Integer=4096)
    max_bytes, max_files = _collection_limits(max_bytes, max_files)
    length(bytes) <= max_bytes || throw(ArgumentError("collection compressed byte limit exceeded"))
    lib, name = _checked_lib(), String(name)
    data = bytes isa Vector{UInt8} ? bytes : Vector{UInt8}(bytes)
    ptr = @with_handles data name _checked(lib) do err
        @capi lib :pio_collection_from_zip(name, sizeof(name), pointer(data), length(data), max_bytes, max_files, err)
    end
    return InputCollection(CollectionHandle(ptr, lib))
end

function InputCollection(files::AbstractDict; name::AbstractString="collection",
                         max_bytes::Integer=64<<20, max_files::Integer=4096)
    max_bytes, max_files = _collection_limits(max_bytes, max_files)
    length(files) <= max_files || throw(ArgumentError("collection file limit exceeded"))
    names, buffers = String[], Vector{UInt8}[]
    remaining = max_bytes
    for (key, value) in files
        key isa AbstractString || throw(ArgumentError("collection paths must be strings"))
        value isa AbstractVector{UInt8} || throw(ArgumentError("collection files must contain byte vectors"))
        length(value) <= remaining || throw(ArgumentError("collection byte limit exceeded"))
        remaining -= length(value)
        push!(names, String(key))
        push!(buffers, value isa Vector{UInt8} ? value : Vector{UInt8}(value))
    end
    lib, name = _checked_lib(), String(name)
    ptr = @with_handles names buffers name begin
        views = [PioNamedBufferView(PioStringView(pointer(n), sizeof(n)), PioByteView(pointer(b), length(b)))
                 for (n, b) in zip(names, buffers)]
        @with_handles views _checked(lib) do err
            @capi lib :pio_collection_from_files(name, sizeof(name), pointer(views), length(views), max_bytes, max_files, err)
        end
    end
    return InputCollection(CollectionHandle(ptr, lib))
end

Base.close(collection::InputCollection) = release!(collection.handle)
function Base.copy(collection::InputCollection)
    h = collection.handle
    ptr = @with_handles h @capi h.lib :pio_collection_retain(_ptr(h))
    return InputCollection(CollectionHandle(ptr, h.lib))
end

"""Inspect inventory and suggested selections; does not certify completeness or solver suitability."""
function inspect_collection(collection::InputCollection)
    h = collection.handle
    ptr = @with_handles h _checked(h.lib) do err
        @capi h.lib :pio_collection_inspect(_ptr(h), err)
    end
    return JSON3.read(_take_string(h.lib, ptr))
end

"""A typed parsed module and observations for this selection only."""
struct CollectionResult{T}
    var"module"::PioModule{T}
    dependencies::Vector{String}
    incomplete::Bool
end

# Reuse the existing typed C option records. All strings, records, and pointers
# remain rooted for the callback; acquisition_root is deliberately unavailable.
function _collection_options(f, mc, tx)
    choice = mc === nothing ? SincalReadOptions() : mc
    balanced = tx === nothing ? SincalBalancedReadOptions() : tx
    tables, balanced_tables = choice.acquired_tables, balanced.acquired_tables
    @with_handles tables balanced_tables begin
        selected = Ref(PioSincalReadOptions(choice.variant !== nothing, something(choice.variant, Int64(0)),
            choice.snapshot_hours !== nothing, something(choice.snapshot_hours, 0.0),
            _optional_input_view(tables), choice.assume_inactive_source_controls))
        selected_balanced = Ref(PioSincalBalancedReadOptions(balanced.variant !== nothing,
            something(balanced.variant, Int64(0)), balanced.snapshot_hours !== nothing,
            something(balanced.snapshot_hours, 0.0), _optional_input_view(balanced_tables)))
        @with_handles selected selected_balanced begin
            options = Ref(PioParseOptions(_optional_input_view(nothing),
                mc === nothing ? C_NULL : Base.unsafe_convert(Ptr{PioSincalReadOptions}, selected),
                tx === nothing ? C_NULL : Base.unsafe_convert(Ptr{PioSincalBalancedReadOptions}, selected_balanced)))
            @with_handles options f(options)
        end
    end
end

"""
    parse(collection::InputCollection, selection; sincal_multiconductor=nothing, sincal_balanced=nothing)

Parse (or deserialize, as selected) one case. Returns `CollectionResult` with
an owned typed module and observed dependencies. False `incomplete` is not a
completeness certificate; findings remain on the module. Selection is a JSON
object/NamedTuple/Dict with root, primary or members, format, and operation.
"""
function Base.parse(collection::InputCollection, selection;
                    sincal_multiconductor::Union{SincalReadOptions,Nothing}=nothing,
                    sincal_balanced::Union{SincalBalancedReadOptions,Nothing}=nothing)
    h, text = collection.handle, JSON3.write(selection)
    report = Ref{Ptr{LibPowerIO.PioString}}(C_NULL)
    ptr = _collection_options(sincal_multiconductor, sincal_balanced) do options
        @with_handles h text report _checked(h.lib) do err
            @capi h.lib :pio_collection_parse(_ptr(h), text, sizeof(text), options, report, err)
        end
    end
    module_value = _wrap_module(h.lib, ptr)
    metadata = JSON3.read(_take_string(h.lib, report[]))
    return CollectionResult(module_value, String.(metadata.dependencies), Bool(metadata.incomplete))
end
