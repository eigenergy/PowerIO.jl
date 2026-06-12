# Columnar export over the Arrow C Data Interface.
#
# `pio_to_arrow` (powerio-capi built `--features arrow`) lends one raw network
# table as an Arrow struct array across the C Data Interface: self-describing, the
# in-memory sibling of the powerio-json snapshot and the dense extractors. Arrow.jl
# is an IPC-format reader and does not import the C Data Interface, so we decode the
# two FFI structs here directly: read the schema's child fields and, per column,
# either copy the data buffer into an owned Julia Vector (the default) or wrap it in
# place (`copy=false`, zero copy).
#
# Reading a foreign buffer is inherently one unsafe op; the design keeps it bounded.
# `copy=true` (default) memcpys each column out while the producer is provably alive,
# then releases it before returning: only Julia-owned memory escapes, so there is no
# finalizer and no use after free if a column outlives the call. `copy=false` returns
# zero-copy `ArrowColumn` views that each root the shared `ArrowBuffers` owner, so a
# column extracted from its `ArrowTable` keeps the producer alive on its own; the
# buffers free once nothing references them. For the numeric tables alone,
# `to_dense` is the copy-free, `unsafe_wrap`-free fast path (the C ABI fills
# Julia-owned buffers directly).
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

# Release the producer's array and schema (frees the columnar buffers). Each
# release callback NULLs its own struct's `release`, so a second call is a no-op —
# the explicit-finalize-then-GC-finalize path is safe.
function _release_ffi!(arr::Base.RefValue{CArrowArray}, sch::Base.RefValue{CArrowSchema})
    arr[].release == C_NULL || ccall(arr[].release, Cvoid, (Ptr{CArrowArray},), arr)
    sch[].release == C_NULL || ccall(sch[].release, Cvoid, (Ptr{CArrowSchema},), sch)
    return
end

# The producer-owned FFI structs and their release callbacks. The one owner the
# zero-copy table AND each of its columns root, so whichever of them stays
# reachable keeps the buffers alive; the finalizer releases once nothing does.
mutable struct ArrowBuffers
    array::Base.RefValue{CArrowArray}
    schema::Base.RefValue{CArrowSchema}
    function ArrowBuffers(array, schema)
        b = new(array, schema)
        finalizer(x -> _release_ffi!(x.array, x.schema), b)
        return b
    end
end

"""
    ArrowColumn{T} <: AbstractVector{T}

One zero-copy column of `to_arrow(...; copy=false)`: a view into the producer's
buffer that roots the shared `ArrowBuffers` owner, so the column alone keeps the
memory alive — extracting it from its [`ArrowTable`](@ref) is safe. `collect` it
for a plain owned `Vector`.
"""
struct ArrowColumn{T} <: AbstractVector{T}
    data::Vector{T}          # unsafe_wrap view into the producer's buffer
    buffers::ArrowBuffers    # roots the producer for the column's lifetime
end
Base.size(c::ArrowColumn) = size(getfield(c, :data))
Base.IndexStyle(::Type{<:ArrowColumn}) = IndexLinear()
# The raw view must not escape its rooting wrapper: a bare `c.data` does not root
# `buffers`, which is exactly the use after free this type exists to prevent.
Base.getproperty(c::ArrowColumn, name::Symbol) = error(
    "PowerIO.ArrowColumn has no public fields; `collect(c)` copies it to an owned Vector")
Base.propertynames(::ArrowColumn) = ()
# Preserve `c` (hence its ArrowBuffers) across the read: the wrapped Vector's
# memory is the producer's, not Julia's, so `c` being collectible mid-read would
# let the release finalizer free it.
Base.@propagate_inbounds Base.getindex(c::ArrowColumn, i::Int) =
    GC.@preserve c getfield(c, :data)[i]

"""
    ArrowTable

The zero-copy result of `to_arrow(...; copy=false)`: a NamedTuple of
[`ArrowColumn`](@ref) views into the producer's buffers, behind property access
(`t.id`, `t.from`, ...). Every property name resolves to a column — including
`t.columns`, which would look up a column called `columns` — so the NamedTuple
itself comes from the unexported accessor `PowerIO.columns(t)`. The columns and
the table each root the shared buffer owner, which frees the buffers once none
of them is reachable; a column extracted from the table is safe on its own.
`close(t)` frees the buffers eagerly instead of waiting for GC. (The default
`copy=true` returns a plain NamedTuple of owned Vectors instead, no `ArrowTable`
involved.)
"""
struct ArrowTable
    columns::NamedTuple
    _buffers::ArrowBuffers
end

columns(t::ArrowTable) = getfield(t, :columns)
Base.getproperty(t::ArrowTable, name::Symbol) = getfield(getfield(t, :columns), name)
Base.propertynames(t::ArrowTable) = propertynames(getfield(t, :columns))

"""
    close(t::ArrowTable)

Release the producer's buffers now instead of at GC. Every [`ArrowColumn`](@ref)
of `t` is invalid afterwards; reading one is undefined behavior. Idempotent (the
release callbacks NULL themselves).
"""
Base.close(t::ArrowTable) = (finalize(getfield(t, :_buffers)); nothing)

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
# Network and path methods of `to_arrow`. Takes the handle and preserves it across
# the ccall (see `_normalize_handle` for why the raw pointer never travels alone).
function _arrow_from_handle(h::NetworkHandle, table::Symbol, copy::Bool)
    id = get(_ARROW_TABLE_IDS, table, nothing)
    id === nothing && throw(ArgumentError(
        "PowerIO.to_arrow: unknown table $(repr(table)); expected one of $(keys(_ARROW_TABLE_IDS))"))
    arr = Ref(_zero(CArrowArray))
    sch = Ref(_zero(CArrowSchema))
    err = zeros(UInt8, _ERRLEN)
    rc = try
        GC.@preserve h ccall((:pio_to_arrow, _lib()), Cint,
              (Ptr{Cvoid}, Cint, Ptr{CArrowArray}, Ptr{CArrowSchema}, Ptr{UInt8}, Csize_t),
              h.ptr, id, arr, sch, err, length(err))
    catch e
        _feature_call_error("to_arrow", "pio_to_arrow", "arrow", e)
    end
    rc == 0 || error("PowerIO.to_arrow: " * _cstr(err))
    if copy
        # The columns are owned copies: release the producer before returning, and
        # on a decode error (a contract violation: unknown format code, child count
        # mismatch) release too so the buffers don't leak.
        cols = try
            _decode_arrow(arr, sch; copy=true)
        catch
            _release_ffi!(arr, sch)
            rethrow()
        end
        _release_ffi!(arr, sch)
        return cols
    end
    # Zero copy: hand ownership to ArrowBuffers FIRST — from here its finalizer
    # releases the producer even if decoding throws — then wrap each view so every
    # column roots the owner on its own.
    buffers = ArrowBuffers(arr, sch)
    cols = _decode_arrow(arr, sch; copy=false)
    rooted = map(v -> ArrowColumn(v, buffers), cols)
    return ArrowTable(rooted, buffers)
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
returns a zero-copy [`ArrowTable`](@ref) of [`ArrowColumn`](@ref) views; each
column roots the shared buffers, so columns may outlive the table, and
`close(t)` frees the buffers eagerly. Both support `result.<column>` access,
but only the `copy=true` NamedTuple is Tables.jl-shaped (flows into
`Arrow.write`, `DataFrame`, etc.); `collect` a zero-copy column for an owned
Vector. For the numeric tables alone, [`to_dense`](@ref) is a copy-free,
`unsafe_wrap`-free fast path.
"""
function to_arrow(net::Network, table::Symbol; copy::Bool=true)
    return _arrow_from_handle(_live_handle(net, "to_arrow"), table, copy)
end
function to_arrow(path::AbstractString, table::Symbol; from=nothing, copy::Bool=true)
    h = _parse_handle(path; from=from)
    try
        return _arrow_from_handle(h, table, copy)
    finally
        # The exported buffers are owned by the Arrow array, independent of the
        # network handle — free the handle now.
        finalize(h)
    end
end

"""
    arrow_available() -> Bool

True if the resolved C library exports `pio_to_arrow` (built `--features
arrow`).
"""
arrow_available() = _exports_symbol(:pio_to_arrow)
