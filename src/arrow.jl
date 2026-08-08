# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements. See the NOTICE file distributed with this work
# for additional information regarding copyright ownership. The ASF licenses
# this file to you under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain a copy
# of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations under
# the License.
#
# This file contains a PowerIO scoped subset adapted from Apache Arrow.jl PR
# #594 by Olle Martenson (@ollemartenson):
# https://github.com/apache/arrow-julia/pull/594
#
# The subset is limited to the C Data Interface import path PowerIO needs today:
# primitive columns in a struct array, explicit release, safe finalizers, metadata
# parsing, and layout tests. When Arrow.jl ships this import path, replace this
# file with a thin wrapper around the released API.

# Columnar export over the Arrow C Data Interface.
#
# `pio_to_arrow` (powerio-capi built `--features arrow`) lends one raw or
# normalized solver table as an Arrow struct array across the C Data Interface.
# The table is self-describing, the in-memory sibling of the JSON transport and
# the dense extractors. Arrow.jl is an IPC-format reader and does not import the
# C Data Interface, so we decode the two FFI structs here directly: read the
# schema's child fields and, per column, either copy the data buffer into an
# owned Julia Vector (the default) or wrap it in place (`copy=false`, zero copy).
#
# Reading a foreign buffer is inherently one unsafe op; the design keeps it bounded.
# `copy=true` (default) memcpys each column out while the producer is provably alive,
# then releases it before returning: only Julia-owned memory escapes, so there is no
# finalizer and no use after free if a column outlives the call. `copy=false` returns
# zero copy `ArrowColumn` objects that each root the shared `ArrowBuffers` owner, so a
# column extracted from its `ArrowTable` keeps the producer alive on its own; the
# buffers free once nothing references them. For the numeric tables alone,
# `to_dense` is the copy free, `unsafe_wrap` free fast path (the C ABI fills
# Julia-owned buffers directly).
#
# The powerio export is the simple case the decoder supports: every column is a
# non-nullable primitive (Int64 "l", Float64 "g", UInt8 "C") with no null buffer, so
# there are no validity bitmaps, no nested or variable-width layouts. The returned
# columns are a Tables.jl compatible NamedTuple of vectors, so they flow straight into
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

const ArrowSchema = CArrowSchema
const ArrowArray = CArrowArray

@assert sizeof(CArrowSchema) == 9 * sizeof(Ptr{Cvoid}) "ArrowSchema size mismatch"
@assert sizeof(CArrowArray) == 10 * sizeof(Ptr{Cvoid}) "ArrowArray size mismatch"

_zero(::Type{CArrowSchema}) = CArrowSchema(C_NULL, C_NULL, C_NULL, 0, 0, C_NULL, C_NULL, C_NULL, C_NULL)
_zero(::Type{CArrowArray}) = CArrowArray(0, 0, 0, 0, 0, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL)

# Arrow C Data Interface primitive format codes -> Julia element type. Only the
# three the powerio exporter emits are accepted; anything else needs binding updates.
function _arrow_eltype(fmt::AbstractString)
    fmt == "l" && return Int64     # int64
    fmt == "g" && return Float64   # float64 (double)
    fmt == "C" && return UInt8     # uint8
    throw(ArgumentError("PowerIO.to_arrow: unsupported Arrow column format $(repr(fmt))"))
end

# Inverse of `_arrow_eltype` for the primitive types the matrix fast path pins.
# The fast path hardcodes each column's Julia type, so it must confirm the
# producer's schema format code agrees before reinterpreting the data buffer;
# otherwise a mismatched powerio-capi build would be read as garbage.
function _arrow_format_code(::Type{T}) where {T}
    T === Int64 && return "l"
    T === Float64 && return "g"
    T === UInt8 && return "C"
    throw(ArgumentError("PowerIO.to_arrow: no Arrow format code for $(T)"))
end

# `PIO_ARROW_SCHEMA_VERSION` lives in schema_lineage.jl (included by
# package.jl); gen/update_artifacts.jl checks it against the library's
# `pio_schema_versions_json` report before it pins binaries.

const _ARROW_TABLE_IDS = (
    bus = Cint(0),
    branch = Cint(1),
    gen = Cint(2),
    load = Cint(3),
    shunt = Cint(4),
    switch = Cint(5),
    solver_bus = Cint(6),
    solver_load = Cint(7),
    solver_shunt = Cint(8),
    solver_branch = Cint(9),
    solver_switch = Cint(10),
    solver_arc = Cint(11),
    solver_gen = Cint(12),
    solver_storage = Cint(13),
    solver_hvdc = Cint(14),
    ybus = Cint(15),
    incidence = Cint(16),
    bprime = Cint(17),
    bdoubleprime = Cint(18),
    matrix_bus = Cint(19),
    matrix_branch = Cint(20),
)

const _MATRIX_ARROW_TABLES = Set((:ybus, :incidence, :bprime, :bdoubleprime))

# Release the producer's array and schema (frees the columnar buffers). Each
# release callback NULLs its own struct's `release`, so a second call is a no-op —
# the explicit-close-then-GC-finalize path is safe.
function _release_ffi!(arr::Base.RefValue{CArrowArray}, sch::Base.RefValue{CArrowSchema})
    arr[].release == C_NULL || ccall(arr[].release, Cvoid, (Ptr{CArrowArray},), arr)
    sch[].release == C_NULL || ccall(sch[].release, Cvoid, (Ptr{CArrowSchema},), sch)
    return
end

function _require_release_callbacks!(arr::Base.RefValue{CArrowArray},
                                     sch::Base.RefValue{CArrowSchema})
    missing_array_release = arr[].release == C_NULL
    missing_schema_release = sch[].release == C_NULL
    !(missing_array_release || missing_schema_release) && return
    _release_ffi!(arr, sch)
    missing_array_release &&
        error("PowerIO.to_arrow: ArrowArray release callback is null")
    error("PowerIO.to_arrow: ArrowSchema release callback is null")
end

# The producer-owned FFI structs and their release callbacks. The one owner the
# zero copy table AND each of its columns root, so whichever of them stays
# reachable keeps the buffers alive; the finalizer releases once nothing does.
mutable struct ArrowBuffers
    array::Base.RefValue{CArrowArray}
    schema::Base.RefValue{CArrowSchema}
    closed::Bool
    lock::ReentrantLock
    function ArrowBuffers(array, schema)
        b = new(array, schema, false, ReentrantLock())
        finalizer(_release_buffers!, b)
        return b
    end
end

function _release_buffers!(b::ArrowBuffers)
    lock(getfield(b, :lock))
    try
        getfield(b, :closed) && return
        setfield!(b, :closed, true)
        _release_ffi!(getfield(b, :array), getfield(b, :schema))
    finally
        unlock(getfield(b, :lock))
    end
    return
end

"""
    ArrowColumn{T} <: AbstractVector{T}

One zero copy column of `to_arrow(...; copy=false)`: a column over the producer's
buffer that roots the shared `ArrowBuffers` owner, so the column alone keeps the
memory alive — extracting it from its [`ArrowTable`](@ref) is safe. `collect` it
for a plain owned `Vector`.
"""
struct ArrowColumn{T} <: AbstractVector{T}
    data::Vector{T}          # unsafe_wrap array over the producer's buffer
    buffers::ArrowBuffers    # roots the producer for the column's lifetime
end
Base.size(c::ArrowColumn) = size(getfield(c, :data))
Base.IndexStyle(::Type{<:ArrowColumn}) = IndexLinear()
# The raw array must not escape its rooting wrapper: a bare `c.data` does not root
# `buffers`, which is exactly the use after free this type exists to prevent.
Base.getproperty(c::ArrowColumn, name::Symbol) = error(
    "PowerIO.ArrowColumn has no public fields; `collect(c)` copies it to an owned Vector")
Base.propertynames(::ArrowColumn) = ()
# Preserve `c` (hence its ArrowBuffers) across the read. `close(table)` marks
# the shared owner closed before releasing, so a surviving column throws instead
# of touching freed producer memory.
Base.@propagate_inbounds function Base.getindex(c::ArrowColumn, i::Int)
    b = getfield(c, :buffers)
    lock(getfield(b, :lock))
    try
        getfield(b, :closed) && error(
            "PowerIO.ArrowColumn: parent ArrowTable is closed; use `collect(column)` before closing")
        return GC.@preserve c getfield(c, :data)[i]
    finally
        unlock(getfield(b, :lock))
    end
end

"""
    ArrowTable

The zero copy result of `to_arrow(...; copy=false)`: a NamedTuple of
[`ArrowColumn`](@ref) columns over the producer's buffers, behind property access
(`t.id`, `t.from`, ...). Every property name resolves to a column — including
`t.columns`, which would look up a column called `columns` — so the NamedTuple
itself comes from the unexported accessor `PowerIO.columns(t)`. The columns and
the table each root the shared buffer owner, which frees the buffers once none
of them is reachable; a column extracted from the table is safe on its own.
`close(t)` frees the buffers eagerly instead of waiting for GC; surviving
columns throw if read afterwards. (The default `copy=true` returns a plain
NamedTuple of owned Vectors instead, no `ArrowTable` involved.)
"""
mutable struct ArrowTable
    columns::NamedTuple
    _buffers::ArrowBuffers
end

columns(t::ArrowTable) = getfield(t, :columns)
Base.getproperty(t::ArrowTable, name::Symbol) = getfield(getfield(t, :columns), name)
Base.propertynames(t::ArrowTable) = propertynames(getfield(t, :columns))

"""
    close(t::ArrowTable)

Release the producer's buffers now instead of at GC. Every [`ArrowColumn`](@ref)
of `t` is invalid afterwards; reading one throws a Julia error. Idempotent (the
release callbacks NULL themselves).
"""
Base.close(t::ArrowTable) = (_release_buffers!(getfield(t, :_buffers)); nothing)

"""
    release_c_data(t::ArrowTable)
    release_c_data(c::ArrowColumn)

Release zero copy Arrow buffers explicitly. This mirrors the name used by the
Arrow.jl C Data Interface import PR; `close(t)` is kept as the Julia table
idiom. Calling it more than once is safe, and reads after release throw.
"""
release_c_data(t::ArrowTable) = close(t)
release_c_data(c::ArrowColumn) = (_release_buffers!(getfield(c, :buffers)); nothing)

function _nonnegative_int(x::Integer, what::AbstractString)
    x >= 0 || error("PowerIO.to_arrow: $what is negative ($x)")
    return Int(x)
end

function _check_root_array(a::CArrowArray, s::CArrowSchema)
    nrows = _nonnegative_int(a.length, "array length")
    ncols = _nonnegative_int(a.n_children, "array child count")
    schema_cols = _nonnegative_int(s.n_children, "schema child count")
    a.offset == 0 || error("PowerIO.to_arrow: root array offset $(a.offset) is unsupported")
    a.null_count == 0 || error("PowerIO.to_arrow: root array has $(a.null_count) nulls")
    ncols == schema_cols ||
        error("PowerIO.to_arrow: schema/array child count mismatch ($(s.n_children) vs $ncols)")
    if ncols > 0
        a.children != C_NULL || error("PowerIO.to_arrow: null array children pointer")
        s.children != C_NULL || error("PowerIO.to_arrow: null schema children pointer")
    end
    return nrows, ncols
end

function _check_child_array(child::CArrowArray, nrows::Int, name::Symbol)
    child_len = _nonnegative_int(child.length, "column $name length")
    child_len == nrows ||
        error("PowerIO.to_arrow: column $name length $child_len does not match row count $nrows")
    child.null_count == 0 || error("PowerIO.to_arrow: column $name has $(child.null_count) nulls")
    child.offset == 0 || error("PowerIO.to_arrow: column $name offset $(child.offset) is unsupported")
    return
end

# Read one primitive column. The data pointer is borrowed from the producer (valid
# until release). `copy=true` memcpys it into an owned Vector under `GC.@preserve` so
# the result outlives the producer; `copy=false` wraps it in place.
function _column(::Type{T}, child::CArrowArray, nrows::Integer, name::Symbol,
                 arr::Base.RefValue{CArrowArray}, copy::Bool) where {T}
    nrows == 0 && return T[]
    # buffers[0] is the validity bitmap (NULL: non-nullable, null_count 0);
    # buffers[1] is the data. Julia 1-based: buffer index 2 is the data.
    # Guard the layout so a malformed producer errors instead of segfaulting.
    child.n_buffers >= 2 ||
        error("PowerIO.to_arrow: column $name has $(child.n_buffers) buffers, expected >= 2")
    child.buffers != C_NULL || error("PowerIO.to_arrow: null buffer pointer for column $name")
    raw = unsafe_load(child.buffers, 2)
    raw == C_NULL && error("PowerIO.to_arrow: null data buffer for column $name")
    src = Ptr{T}(raw)
    copy || return unsafe_wrap(Array, src, nrows; own = false)
    dest = Vector{T}(undef, nrows)
    # `arr` roots the unreleased FFI struct (and thus the producer's buffers) across
    # the memcpy; the caller releases only after this returns.
    GC.@preserve arr unsafe_copyto!(pointer(dest), src, nrows)
    return dest
end

# Decode the struct array into a NamedTuple of columns (owned copies if `copy`, else
# zero copy columns), one per child field.
function _metadata_i32(ptr::Ptr{UInt8}, offset::Int)
    raw = UInt32(unsafe_load(ptr + offset)) |
          (UInt32(unsafe_load(ptr + offset + 1)) << 8) |
          (UInt32(unsafe_load(ptr + offset + 2)) << 16) |
          (UInt32(unsafe_load(ptr + offset + 3)) << 24)
    return Int(reinterpret(Int32, raw))
end

# The Arrow C Data Interface metadata block carries no total length, so a corrupt
# pair count or key/value length prefix would drive the unsafe_load walk off the
# end of the block. The producer is our own Rust lib and never emits anything near
# these, so a value past the ceiling means corruption: error instead of reading
# arbitrary memory. Pair count and byte lengths get separate, generous caps.
const _ARROW_METADATA_MAX_PAIRS = 1 << 16
const _ARROW_METADATA_MAX_BYTES = 1 << 20

function _metadata_len(ptr::Ptr{UInt8}, offset::Int, what::AbstractString, cap::Int)
    n = _metadata_i32(ptr, offset)
    n < 0 && error("PowerIO.to_arrow: negative Arrow metadata $what ($n)")
    n > cap && error("PowerIO.to_arrow: Arrow metadata $what $n exceeds the $cap ceiling")
    return n
end

function _schema_metadata(s::CArrowSchema)
    s.metadata == C_NULL && return Dict{String,String}()
    ptr = Ptr{UInt8}(s.metadata)
    offset = 0
    npairs = _metadata_len(ptr, offset, "pair count", _ARROW_METADATA_MAX_PAIRS)
    offset += sizeof(Int32)
    out = Dict{String,String}()
    for _ in 1:npairs
        klen = _metadata_len(ptr, offset, "key length", _ARROW_METADATA_MAX_BYTES)
        offset += sizeof(Int32)
        key = unsafe_string(ptr + offset, klen)
        offset += klen
        vlen = _metadata_len(ptr, offset, "value length", _ARROW_METADATA_MAX_BYTES)
        offset += sizeof(Int32)
        value = unsafe_string(ptr + offset, vlen)
        offset += vlen
        out[key] = value
    end
    return out
end

function _metadata_key_eq(ptr::Ptr{UInt8}, len::Integer, wanted::String)
    len == ncodeunits(wanted) || return false
    @inbounds for i in 1:len
        unsafe_load(ptr + i - 1) == codeunit(wanted, i) || return false
    end
    return true
end

# Read the matrix table's dimension and axis metadata in one pass over the raw
# schema key/value block. The axis names (`powerio.row_axis`/`powerio.col_axis`)
# let the caller confirm the matrix rows and columns are indexed by the axis the
# binding assumes (`matrix_bus`/`matrix_branch`), so a producer that changed the
# axis convention errors here instead of silently mislabeling rows.
function _matrix_axis_metadata(s::CArrowSchema)
    s.metadata != C_NULL || error("PowerIO.to_arrow: matrix table has no schema metadata")
    ptr = Ptr{UInt8}(s.metadata)
    offset = 0
    npairs = _metadata_len(ptr, offset, "pair count", _ARROW_METADATA_MAX_PAIRS)
    offset += sizeof(Int32)
    row_count = nothing
    col_count = nothing
    row_axis = nothing
    col_axis = nothing
    for _ in 1:npairs
        klen = _metadata_len(ptr, offset, "key length", _ARROW_METADATA_MAX_BYTES)
        offset += sizeof(Int32)
        key_ptr = ptr + offset
        is_row_count = _metadata_key_eq(key_ptr, klen, "powerio.row_count")
        is_col_count = _metadata_key_eq(key_ptr, klen, "powerio.col_count")
        is_row_axis = _metadata_key_eq(key_ptr, klen, "powerio.row_axis")
        is_col_axis = _metadata_key_eq(key_ptr, klen, "powerio.col_axis")
        offset += klen
        vlen = _metadata_len(ptr, offset, "value length", _ARROW_METADATA_MAX_BYTES)
        offset += sizeof(Int32)
        if is_row_count
            row_count = parse(Int, unsafe_string(ptr + offset, vlen))
        elseif is_col_count
            col_count = parse(Int, unsafe_string(ptr + offset, vlen))
        elseif is_row_axis
            row_axis = unsafe_string(ptr + offset, vlen)
        elseif is_col_axis
            col_axis = unsafe_string(ptr + offset, vlen)
        end
        offset += vlen
    end
    row_count === nothing && error("PowerIO.to_arrow: missing powerio.row_count metadata")
    col_count === nothing && error("PowerIO.to_arrow: missing powerio.col_count metadata")
    return row_count, col_count, row_axis, col_axis
end

# The row/column axis each matrix table is expected to be indexed by. Rust labels
# every matrix row with the `matrix_bus` axis; incidence columns are `matrix_branch`,
# the rest square on `matrix_bus`. The binding maps rows/columns through those axis
# tables, so a mismatch means the COO indices no longer line up with the axis map.
_expected_matrix_axes(table::Symbol) =
    table === :incidence ? ("matrix_bus", "matrix_branch") : ("matrix_bus", "matrix_bus")

function _check_matrix_axes(table::Symbol, row_axis, col_axis)
    want_row, want_col = _expected_matrix_axes(table)
    (row_axis === nothing || row_axis == want_row) ||
        error("PowerIO.to_arrow: table $table reports row axis $(repr(row_axis)), " *
              "expected $(repr(want_row)); rebuild powerio-capi from a matching commit.")
    (col_axis === nothing || col_axis == want_col) ||
        error("PowerIO.to_arrow: table $table reports col axis $(repr(col_axis)), " *
              "expected $(repr(want_col)); rebuild powerio-capi from a matching commit.")
    return
end

function _with_matrix_metadata(cols::NamedTuple, table::Symbol,
                               metadata::Dict{String,String})
    table in _MATRIX_ARROW_TABLES || return cols
    reported = get(metadata, "powerio.table", String(table))
    schema_version = get(metadata, "powerio.schema_version", "")
    format = get(metadata, "powerio.format", "coo")
    row_axis = get(metadata, "powerio.row_axis", "solver_bus")
    col_axis = get(metadata, "powerio.col_axis", table == :incidence ? "solver_branch" : "solver_bus")
    row_count = parse(Int, metadata["powerio.row_count"])
    col_count = parse(Int, metadata["powerio.col_count"])
    return (; cols..., table=reported, schema_version, format, row_axis, col_axis,
            row_count, col_count)
end

function _decode_arrow(arr::Base.RefValue{CArrowArray}, sch::Base.RefValue{CArrowSchema};
                       copy::Bool, table::Symbol)
    a, s = arr[], sch[]
    nrows, ncols = _check_root_array(a, s)
    names = Vector{Symbol}(undef, ncols)
    cols = Vector{Any}(undef, ncols)
    for i in 1:ncols
        child_arr_ptr = unsafe_load(a.children, i)
        child_sch_ptr = unsafe_load(s.children, i)
        child_arr_ptr != C_NULL || error("PowerIO.to_arrow: null array child pointer at column $i")
        child_sch_ptr != C_NULL || error("PowerIO.to_arrow: null schema child pointer at column $i")
        child_arr = unsafe_load(child_arr_ptr)
        child_sch = unsafe_load(child_sch_ptr)
        child_sch.format != C_NULL || error("PowerIO.to_arrow: null format for column $i")
        child_sch.name != C_NULL || error("PowerIO.to_arrow: null name for column $i")
        T = _arrow_eltype(unsafe_string(child_sch.format))
        names[i] = Symbol(unsafe_string(child_sch.name))
        _check_child_array(child_arr, nrows, names[i])
        cols[i] = _column(T, child_arr, nrows, names[i], arr, copy)
    end
    decoded = NamedTuple{Tuple(names)}(Tuple(cols))
    table in _MATRIX_ARROW_TABLES || return decoded
    return _with_matrix_metadata(decoded, table, _schema_metadata(s))
end

# Export one table off a live handle over the Arrow C Data Interface, shared by the
# BalancedNetwork and path methods of `to_arrow`. Takes the handle and preserves it across
# the ccall (see `_normalize_handle` for why the raw pointer never travels alone).
function _arrow_from_handle(h::BalancedNetworkHandle, table::Symbol, copy::Bool)
    id = get(_ARROW_TABLE_IDS, table, nothing)
    id === nothing && throw(ArgumentError(
        "PowerIO.to_arrow: unknown table $(repr(table)); expected one of $(keys(_ARROW_TABLE_IDS))"))
    arr = Ref(_zero(CArrowArray))
    sch = Ref(_zero(CArrowSchema))
    err = zeros(UInt8, _ERRLEN)
    lib = getfield(h, :lib)
    rc = try
        GC.@preserve h ccall(_library_symbol(lib, :pio_to_arrow), Cint,
              (Ptr{Cvoid}, Cint, Ptr{CArrowArray}, Ptr{CArrowSchema}, Ptr{UInt8}, Csize_t),
              h.ptr, id, arr, sch, err, length(err))
    catch e
        _feature_call_error("to_arrow", "pio_to_arrow", "arrow", e)
    end
    if rc != 0
        msg = _cstr(err)
        if occursin("unknown Arrow table id", msg)
            error("PowerIO.to_arrow: the loaded C library does not support table " *
                  "$(repr(table)) (id $(Int(id))). Rebuild powerio-capi from a " *
                  "matching commit or repin the PowerIO.jl artifact.")
        end
        error("PowerIO.to_arrow: " * msg)
    end
    _require_release_callbacks!(arr, sch)
    if copy
        # The columns are owned copies: release the producer before returning, and
        # on a decode error (unknown format code, child count
        # mismatch) release too so the buffers don't leak.
        cols = try
            _decode_arrow(arr, sch; copy=true, table=table)
        catch
            _release_ffi!(arr, sch)
            rethrow()
        end
        _release_ffi!(arr, sch)
        return cols
    end
    # Zero copy: hand ownership to ArrowBuffers FIRST — from here its finalizer
    # releases the producer even if decoding throws, then wrap each column so every
    # column roots the owner on its own.
    buffers = ArrowBuffers(arr, sch)
    cols = try
        _decode_arrow(arr, sch; copy=false, table=table)
    catch
        _release_buffers!(buffers)
        rethrow()
    end
    rooted = map(v -> v isa AbstractVector ? ArrowColumn(v, buffers) : v, cols)
    return ArrowTable(rooted, buffers)
end

function _fast_child_column(::Type{T}, arr::Base.RefValue{CArrowArray},
                            sch::Base.RefValue{CArrowSchema},
                            child_idx::Integer, nrows::Integer,
                            name::Symbol) where {T}
    a = arr[]
    s = sch[]
    child_arr_ptr = unsafe_load(a.children, child_idx)
    child_arr_ptr != C_NULL ||
        error("PowerIO.to_arrow: null array child pointer at column $child_idx")
    child_sch_ptr = unsafe_load(s.children, child_idx)
    child_sch_ptr != C_NULL ||
        error("PowerIO.to_arrow: null schema child pointer at column $child_idx")
    child_sch = unsafe_load(child_sch_ptr)
    # The fast path pins each column's Julia type; confirm the producer's format
    # code agrees before reinterpreting its buffer, matching the generic decode's
    # `_arrow_eltype` gate so a wrong-typed column errors instead of decoding garbage.
    child_sch.format != C_NULL || error("PowerIO.to_arrow: null format for column $name")
    fmt = unsafe_string(child_sch.format)
    want = _arrow_format_code(T)
    fmt == want ||
        error("PowerIO.to_arrow: column $name has Arrow format $(repr(fmt)), expected $(repr(want))")
    child_arr = unsafe_load(child_arr_ptr)
    _check_child_array(child_arr, Int(nrows), name)
    return _column(T, child_arr, nrows, name, arr, true)
end

function _matrix_arrow_from_handle(h::BalancedNetworkHandle, table::Symbol)
    id = get(_ARROW_TABLE_IDS, table, nothing)
    id === nothing && throw(ArgumentError(
        "PowerIO.to_arrow: unknown table $(repr(table)); expected one of $(keys(_ARROW_TABLE_IDS))"))
    expected = table == :ybus ? 4 : 3
    arr = Ref(_zero(CArrowArray))
    sch = Ref(_zero(CArrowSchema))
    err = zeros(UInt8, _ERRLEN)
    lib = getfield(h, :lib)
    rc = try
        GC.@preserve h ccall(_library_symbol(lib, :pio_to_arrow), Cint,
              (Ptr{Cvoid}, Cint, Ptr{CArrowArray}, Ptr{CArrowSchema}, Ptr{UInt8}, Csize_t),
              h.ptr, id, arr, sch, err, length(err))
    catch e
        _feature_call_error("to_arrow", "pio_to_arrow", "arrow", e)
    end
    rc == 0 || error("PowerIO.to_arrow: " * _cstr(err))
    _require_release_callbacks!(arr, sch)
    try
        a, s = arr[], sch[]
        nrows = _nonnegative_int(a.length, "array length")
        a.offset == 0 || error("PowerIO.to_arrow: root array offset $(a.offset) is unsupported")
        a.null_count == 0 || error("PowerIO.to_arrow: root array has $(a.null_count) nulls")
        Int(a.n_children) == expected ||
            error("PowerIO.to_arrow: table $table has $(a.n_children) columns, expected $expected")
        Int(s.n_children) == expected ||
            error("PowerIO.to_arrow: table $table schema has $(s.n_children) columns, expected $expected")
        a.children != C_NULL || error("PowerIO.to_arrow: null array children pointer")
        s.children != C_NULL || error("PowerIO.to_arrow: null schema children pointer")
        row_count, col_count, row_axis, col_axis = _matrix_axis_metadata(s)
        _check_matrix_axes(table, row_axis, col_axis)
        row_index = _fast_child_column(Int64, arr, sch, 1, nrows, :row_index)
        col_index = _fast_child_column(Int64, arr, sch, 2, nrows, :col_index)
        if table == :ybus
            g = _fast_child_column(Float64, arr, sch, 3, nrows, :g)
            b = _fast_child_column(Float64, arr, sch, 4, nrows, :b)
            return (; row_index, col_index, g, b, row_count, col_count)
        end
        value = _fast_child_column(Float64, arr, sch, 3, nrows, :value)
        return (; row_index, col_index, value, row_count, col_count)
    finally
        _release_ffi!(arr, sch)
    end
end

"""
    to_arrow(net::BalancedNetwork, table::Symbol; copy=true) -> NamedTuple | ArrowTable
    to_arrow(path, table::Symbol; from=nothing, copy=true) -> NamedTuple | ArrowTable

Export one network table over the Arrow C Data Interface. Raw table selectors are
`:bus`, `:branch`, `:gen`, `:load`, `:shunt`, and `:switch`; those columns are
the parsed network fields with 1-based (external) bus ids, the same id space as
[`to_dense`](@ref). Normalized solver table selectors are `:solver_bus`,
`:solver_load`, `:solver_shunt`, `:solver_branch`, `:solver_switch`,
`:solver_arc`, `:solver_gen`, `:solver_storage`, and `:solver_hvdc`; those
columns use dense 0-based row ids and per unit/radian values. Matrix selectors
are `:ybus`, `:incidence`, `:bprime`, and `:bdoubleprime`; they return COO
columns plus schema metadata. Matrix axis selectors are `:matrix_bus` and
`:matrix_branch`; they map dense matrix rows and incidence columns back to source
bus and branch rows. Takes
a parsed [`BalancedNetwork`](@ref) (via its live handle) or a `path` to parse
first. Needs powerio-capi built `--features arrow`; matrix selectors also need
`--features matrix`; see [`arrow_available`](@ref) and [`matrix_available`](@ref).

`copy=true` (default) returns a NamedTuple of **owned** Julia Vectors and releases
the producer before returning: plain arrays, no lifetime caveat. `copy=false`
returns a zero copy [`ArrowTable`](@ref) of [`ArrowColumn`](@ref) columns; each
column roots the shared buffers, so columns can outlive the table until
`close(t)` frees the buffers; reads after close throw. Both support `result.<column>` access,
but only the `copy=true` NamedTuple is Tables.jl compatible (flows into
`Arrow.write`, `DataFrame`, etc.); `collect` a zero copy column for an owned
Vector. For the numeric tables alone, [`to_dense`](@ref) is a copy free,
`unsafe_wrap` free fast path.
"""
function to_arrow(net::BalancedNetwork, table::Symbol; copy::Bool=true)
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
arrow`). This checks the Arrow entry point, not that the loaded library supports
every table selector this binding knows about.
"""
arrow_available() = _exports_symbol(:pio_to_arrow)

"""
    matrix_available() -> Bool

True if the resolved C library exports `pio_to_arrow` and was built with the
matrix Arrow table API.
"""
function matrix_available()
    arrow_available() || return false
    _exports_symbol(:pio_matrix_available) || return false
    try
        return ccall((:pio_matrix_available, _lib()), Cint, ()) != 0
    catch e
        @debug "PowerIO: pio_matrix_available probe failed" exception = (e, catch_backtrace())
        return false
    end
end

"""
    arrow_catalog() -> JSON3.Object

The Arrow table catalog (`pio_arrow_catalog_json`): what this library build can
export over [`to_arrow`](@ref), independent of any parsed network. Top level
fields are `schema_version`, `producer`, and `tables`; each table entry carries
`id`, `name`, `schema_version`, `format`, `feature_requirements`, `available`,
`row_axis`, `col_axis`, `units`, and `columns`. Needs powerio-capi v0.7 built
`--features arrow`.
"""
function arrow_catalog()
    lib = _lib()
    _ensure_compatible(lib)
    _require_export("arrow_catalog", :pio_arrow_catalog_json,
                    "powerio v0.7, `--features arrow`", lib)
    err = zeros(UInt8, _ERRLEN)
    s = ccall(_library_symbol(lib, :pio_arrow_catalog_json), Cstring,
              (Ptr{UInt8}, Csize_t), err, length(err))
    s == C_NULL && error("PowerIO.arrow_catalog: " * _cstr(err))
    return JSON3.read(_take_string(lib, s))
end
