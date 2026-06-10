# Columnar export over the Arrow C Data Interface.
#
# `pio_export_arrow` (powerio-capi built `--features arrow`) lends one raw network
# table as an Arrow struct array across the C Data Interface: self-describing, the
# in-memory sibling of the JSON transport and the dense extractors. Arrow.jl is an
# IPC-format reader and does not import the C Data Interface, so we decode the two
# FFI structs here directly: read the schema's child fields and, per column, either
# copy the data buffer into an owned Julia Vector (the default) or wrap it in place
# (`copy=false`, zero copy).
#
# Reading a foreign buffer is inherently one unsafe op; the design keeps it bounded.
# `copy=true` (default) memcpys each column out while the producer is provably alive,
# then releases it before returning: only Julia-owned memory escapes, so there is no
# finalizer and no use after free if a column outlives the call. `copy=false` returns
# zero-copy views in an `ArrowTable` that holds the producer alive and frees it on
# finalize; the views then carry the standard keep-the-owner-alive caveat. For the
# numeric tables alone, `to_dense` is the copy-free, `unsafe_wrap`-free fast path
# (the C ABI fills Julia-owned buffers directly).
#
# The powerio export is the simple case the decoder is scoped to: every column is a
# non-nullable primitive (Int64 "l", Float64 "g", UInt8 "C") with no null buffer, so
# there are no validity bitmaps, no nested or variable-width layouts. The returned
# columns are a Tables.jl-shaped NamedTuple of vectors, so they flow straight into
# Arrow.write, DataFrame, etc.

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
    throw(ArgumentError("PowerIO.to_arrow: unsupported Arrow column format $(repr(fmt))"))
end

const _ARROW_TABLE_IDS = (bus = Cint(0), branch = Cint(1), gen = Cint(2), load = Cint(3), shunt = Cint(4))

"""
    ArrowTable

The zero-copy result of `to_arrow(...; copy=false)`. Its `columns` are a
NamedTuple of vectors that view the producer's buffers directly; the table holds
the producer alive and releases it (frees the buffers) when finalized. (The
default `copy=true` returns a plain NamedTuple of owned Vectors instead, no
`ArrowTable` involved.)

Keep the `ArrowTable` reachable while you use its columns: a column kept after
the table is garbage collected points into freed memory. Copy a column
(`collect(t.x)`) to outlive the table.
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

# Release the producer's array and schema (frees the columnar buffers). Each
# release callback NULLs its own struct's `release`, so a second call is a no-op —
# the explicit-finalize-then-GC-finalize path is safe.
function _release_ffi!(arr::Base.RefValue{CArrowArray}, sch::Base.RefValue{CArrowSchema})
    arr[].release == C_NULL || ccall(arr[].release, Cvoid, (Ptr{CArrowArray},), arr)
    sch[].release == C_NULL || ccall(sch[].release, Cvoid, (Ptr{CArrowSchema},), sch)
    return
end

_release!(t::ArrowTable) = _release_ffi!(getfield(t, :_array), getfield(t, :_schema))

# Read one primitive column. The data pointer is borrowed from the producer (valid
# until release). `copy=true` memcpys it into an owned Vector under `GC.@preserve` so
# the result outlives the producer; `copy=false` wraps it in place (zero-copy view).
function _column(::Type{T}, child::CArrowArray, nrows::Integer, name::Symbol,
                 arr::Base.RefValue{CArrowArray}, copy::Bool) where {T}
    nrows == 0 && return T[]
    # buffers[0] is the validity bitmap (NULL: non-nullable, null_count 0);
    # buffers[1] is the data. Julia 1-based: buffer index 2 is the data.
    # Guard the layout so a malformed producer errors instead of segfaulting.
    child.n_buffers >= 2 ||
        error("PowerIO.to_arrow: column $name has $(child.n_buffers) buffers, expected >= 2")
    raw = unsafe_load(child.buffers, 2)
    raw == C_NULL && error("PowerIO.to_arrow: null data buffer for column $name")
    src = Ptr{T}(raw) + child.offset * sizeof(T)
    copy || return unsafe_wrap(Array, src, nrows; own = false)
    dest = Vector{T}(undef, nrows)
    # `arr` roots the unreleased FFI struct (and thus the producer's buffers) across
    # the memcpy; the caller releases only after this returns.
    GC.@preserve arr unsafe_copyto!(pointer(dest), src, nrows)
    return dest
end

# Decode the struct array into a NamedTuple of columns (owned copies if `copy`, else
# zero-copy views), one per child field.
function _decode_arrow(arr::Base.RefValue{CArrowArray}, sch::Base.RefValue{CArrowSchema}; copy::Bool)
    a, s = arr[], sch[]
    nrows = a.length
    ncols = Int(a.n_children)
    ncols == Int(s.n_children) ||
        error("PowerIO.to_arrow: schema/array child count mismatch ($(s.n_children) vs $ncols)")
    names = Vector{Symbol}(undef, ncols)
    cols = Vector{Any}(undef, ncols)
    for i in 1:ncols
        child_arr = unsafe_load(unsafe_load(a.children, i))
        child_sch = unsafe_load(unsafe_load(s.children, i))
        T = _arrow_eltype(unsafe_string(child_sch.format))
        names[i] = Symbol(unsafe_string(child_sch.name))
        cols[i] = _column(T, child_arr, nrows, names[i], arr, copy)
    end
    return NamedTuple{Tuple(names)}(Tuple(cols))
end

# Export one table off a live handle over the Arrow C Data Interface, shared by the
# Network and path methods of `to_arrow`.
function _arrow_from_handle(p::Ptr{Cvoid}, table::Symbol, copy::Bool)
    id = get(_ARROW_TABLE_IDS, table, nothing)
    id === nothing && throw(ArgumentError(
        "PowerIO.to_arrow: unknown table $(repr(table)); expected one of $(keys(_ARROW_TABLE_IDS))"))
    arr = Ref(_zero(CArrowArray))
    sch = Ref(_zero(CArrowSchema))
    err = zeros(UInt8, _ERRLEN)
    rc = try
        ccall((:pio_export_arrow, _lib()), Cint,
              (Ptr{Cvoid}, Cint, Ptr{CArrowArray}, Ptr{CArrowSchema}, Ptr{UInt8}, Csize_t),
              p, id, arr, sch, err, length(err))
    catch e
        error("PowerIO.to_arrow: could not call pio_export_arrow: the C ABI at " *
              "\"$(_lib())\" was built without the arrow feature. Rebuild with " *
              "`cargo build -p powerio-capi --release --features arrow`. Underlying: $e")
    end
    rc == 0 || error("PowerIO.to_arrow: " * _cstr(err))
    # Export succeeded, so the producer set live release callbacks. If decoding
    # throws (a contract violation: unknown format code, child count mismatch),
    # release here so the buffers don't leak.
    cols = try
        _decode_arrow(arr, sch; copy=copy)
    catch
        _release_ffi!(arr, sch)
        rethrow()
    end
    # copy=true: the columns are owned, so free the producer now and hand back plain
    # Vectors. copy=false: the ArrowTable owns the producer and releases on finalize.
    copy || return ArrowTable(cols, arr, sch)
    _release_ffi!(arr, sch)
    return cols
end

"""
    to_arrow(net::Network, table::Symbol; copy=true) -> NamedTuple | ArrowTable
    to_arrow(path, table::Symbol; from=nothing, copy=true) -> NamedTuple | ArrowTable

Export one raw network table over the Arrow C Data Interface. `table` is `:bus`,
`:branch`, `:gen`, `:load`, or `:shunt`; the columns are the parsed network fields
with 1-based (external) bus ids, the same id space as [`to_dense`](@ref). Takes a
parsed [`Network`](@ref) (via its live handle) or a `path` to parse first. Needs
powerio-capi built `--features arrow`; see [`arrow_available`](@ref).

`copy=true` (default) returns a NamedTuple of **owned** Julia Vectors and releases
the producer before returning: plain arrays, no lifetime caveat. `copy=false`
returns a zero-copy [`ArrowTable`](@ref) whose columns view the producer's buffers;
keep it alive while reading them. Both support `result.<column>` access and are
Tables.jl-shaped. For the numeric tables alone, [`to_dense`](@ref) is a copy-free,
`unsafe_wrap`-free fast path.
"""
function to_arrow(net::Network, table::Symbol; copy::Bool=true)
    return _arrow_from_handle(_live_handle(net, "to_arrow").ptr, table, copy)
end
function to_arrow(path::AbstractString, table::Symbol; from=nothing, copy::Bool=true)
    h = _parse_handle(path; from=from)
    try
        return _arrow_from_handle(h.ptr, table, copy)
    finally
        # The exported buffers are owned by the Arrow array, independent of the
        # case handle — free the handle now.
        finalize(h)
    end
end

"""
    arrow_available() -> Bool

True if the resolved C library exports `pio_export_arrow` (built `--features
arrow`).
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
