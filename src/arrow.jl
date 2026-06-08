# Zero-copy columnar export over the Arrow C Data Interface.
#
# `pio_export_arrow` (powerio-capi built `--features arrow`) lends one raw network
# table as an Arrow struct array across the C Data Interface — self-describing,
# zero-copy, the in-memory sibling of the JSON transport and the dense extractors.
# Arrow.jl is an IPC-format reader and does not import the C Data Interface, so we
# decode the two FFI structs here directly: read the schema's child fields, wrap
# each primitive column's data buffer as a Julia array straight over the producer's
# memory (no copy), and hold the producer alive until the table is released.
#
# The powerio export is the simple case the decoder is scoped to: every column is a
# non-nullable primitive (Int64 "l", Float64 "g", UInt8 "C") with no null buffer, so
# there are no validity bitmaps, no offsets, no nested or variable-width layouts to
# handle. The returned columns are a Tables.jl-shaped NamedTuple of vectors, so they
# flow straight into Arrow.write, DataFrame, etc.

# Mirror of the Arrow C Data Interface structs (arrow/c/abi.h). Field order and
# types are the ABI; do not reorder.
struct CArrowSchema
    format::Ptr{Cchar}
    name::Ptr{Cchar}
    metadata::Ptr{Cchar}
    flags::Int64
    n_children::Int64
    children::Ptr{Ptr{CArrowSchema}}
    dictionary::Ptr{CArrowSchema}
    release::Ptr{Cvoid}
    private_data::Ptr{Cvoid}
end

struct CArrowArray
    length::Int64
    null_count::Int64
    offset::Int64
    n_buffers::Int64
    n_children::Int64
    buffers::Ptr{Ptr{Cvoid}}
    children::Ptr{Ptr{CArrowArray}}
    dictionary::Ptr{CArrowArray}
    release::Ptr{Cvoid}
    private_data::Ptr{Cvoid}
end

_zero(::Type{CArrowSchema}) = CArrowSchema(C_NULL, C_NULL, C_NULL, 0, 0, C_NULL, C_NULL, C_NULL, C_NULL)
_zero(::Type{CArrowArray}) = CArrowArray(0, 0, 0, 0, 0, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL)

# Arrow C Data Interface primitive format codes -> Julia element type. Only the
# three the powerio exporter emits are accepted; anything else is a contract change.
function _arrow_eltype(fmt::AbstractString)
    fmt == "l" && return Int64     # int64
    fmt == "g" && return Float64   # float64 (double)
    fmt == "C" && return UInt8     # uint8
    throw(ArgumentError("PowerIO.arrow_table: unsupported Arrow column format $(repr(fmt))"))
end

const _ARROW_TABLE_IDS = (bus = Cint(0), branch = Cint(1), gen = Cint(2), load = Cint(3), shunt = Cint(4))

"""
    ArrowTable

A columnar table imported zero-copy from the C ABI's Arrow export. Its `columns`
are a NamedTuple of vectors that view the producer's buffers directly; the table
holds the producer alive and releases it (frees the buffers) when finalized.

Keep the `ArrowTable` reachable while you use its columns: a column vector extracted
and kept after the table is collected views freed memory. Copy a column
(`collect(t.columns.x)`) to outlive the table.
"""
mutable struct ArrowTable
    columns::NamedTuple
    _array::Base.RefValue{CArrowArray}
    _schema::Base.RefValue{CArrowSchema}
    function ArrowTable(columns, array, schema)
        t = new(columns, array, schema)
        finalizer(_release!, t)
        return t
    end
end

columns(t::ArrowTable) = getfield(t, :columns)
Base.getproperty(t::ArrowTable, name::Symbol) = getfield(getfield(t, :columns), name)
Base.propertynames(t::ArrowTable) = propertynames(getfield(t, :columns))

function _release!(t::ArrowTable)
    arr = getfield(t, :_array)
    if arr[].release != C_NULL
        ccall(arr[].release, Cvoid, (Ptr{CArrowArray},), arr)
    end
    sch = getfield(t, :_schema)
    if sch[].release != C_NULL
        ccall(sch[].release, Cvoid, (Ptr{CArrowSchema},), sch)
    end
    return
end

# Decode the struct array into a NamedTuple of column views (one per child field).
function _decode_arrow(arr::Base.RefValue{CArrowArray}, sch::Base.RefValue{CArrowSchema})
    a, s = arr[], sch[]
    nrows = a.length
    ncols = Int(a.n_children)
    ncols == Int(s.n_children) ||
        error("PowerIO.arrow_table: schema/array child count mismatch ($(s.n_children) vs $ncols)")
    names = Vector{Symbol}(undef, ncols)
    cols = Vector{Any}(undef, ncols)
    for i in 1:ncols
        child_arr = unsafe_load(unsafe_load(a.children, i))
        child_sch = unsafe_load(unsafe_load(s.children, i))
        T = _arrow_eltype(unsafe_string(child_sch.format))
        names[i] = Symbol(unsafe_string(child_sch.name))
        if nrows == 0
            cols[i] = T[]
        else
            # buffers[0] is the validity bitmap (NULL — non-nullable, null_count 0);
            # buffers[1] is the data. Julia 1-based: buffer index 2 is the data.
            data = Ptr{T}(unsafe_load(child_arr.buffers, 2)) + child_arr.offset * sizeof(T)
            cols[i] = unsafe_wrap(Array, data, nrows; own = false)
        end
    end
    return NamedTuple{Tuple(names)}(Tuple(cols))
end

"""
    arrow_table(path, table; from=nothing) -> ArrowTable

Export one raw network table over the Arrow C Data Interface, zero-copy. `table` is
`:bus`, `:branch`, `:gen`, `:load`, or `:shunt`; the columns are the parsed network
fields with 1-based (external) bus ids — the same id space as [`parse_dense`], not
the gridfm schema. Needs powerio-capi built `--features arrow`; see
[`arrow_available`](@ref). The result's `columns` view the producer's memory, so
keep the table alive while reading them (see [`ArrowTable`](@ref)).
"""
function arrow_table(path::AbstractString, table::Symbol; from=nothing)
    id = get(_ARROW_TABLE_IDS, table, nothing)
    id === nothing && throw(ArgumentError(
        "PowerIO.arrow_table: unknown table $(repr(table)); expected one of $(keys(_ARROW_TABLE_IDS))"))
    h = _parse_handle(path; from=from)
    try
        arr = Ref(_zero(CArrowArray))
        sch = Ref(_zero(CArrowSchema))
        err = zeros(UInt8, _ERRLEN)
        rc = try
            ccall((:pio_export_arrow, _lib()), Cint,
                  (Ptr{Cvoid}, Cint, Ptr{CArrowArray}, Ptr{CArrowSchema}, Ptr{UInt8}, Csize_t),
                  h.ptr, id, arr, sch, err, length(err))
        catch e
            error("PowerIO.arrow_table: could not call pio_export_arrow — the C ABI at " *
                  "\"$(_lib())\" was built without the arrow feature. Rebuild with " *
                  "`cargo build -p powerio-capi --release --features arrow`. Underlying: $e")
        end
        rc == 0 || error("PowerIO.arrow_table: " * _cstr(err))
        return ArrowTable(_decode_arrow(arr, sch), arr, sch)
    finally
        # The exported buffers are owned by the Arrow array (released with the
        # ArrowTable), independent of the case handle — free the handle now.
        finalize(h)
    end
end

"""
    arrow_available() -> Bool

True if the resolved C library exports `pio_export_arrow` (built `--features
arrow`). Tests for the Arrow path skip when this is false.
"""
function arrow_available()
    try
        handle = Libdl.dlopen(_lib())
        try
            return Libdl.dlsym(handle, :pio_export_arrow; throw_error=false) !== nothing
        finally
            Libdl.dlclose(handle)
        end
    catch e
        @debug "PowerIO: arrow_available probe failed" exception = (e, catch_backtrace())
        return false
    end
end
