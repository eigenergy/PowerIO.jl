# ABI v6: structured error handles, the stored module surface, and the DC
# branch data with borrowed array views.
#
# Every handle keeps the pointer AND the library that created it, and every
# ccall on a handle resolves its symbol from `getfield(h, :lib)` — never the
# globally configured `_lib()` — so a handle outlives a `set_library!` switch
# without dispatching into the wrong image. Borrowed array views root their
# owner handle, so the spans they alias stay valid for the view's lifetime;
# `copy` returns an ordinary mutable Julia array.

"""
    PowerIOCError

A structured failure from an ABI v6 entry point: the stable diagnostic
`code`, the rendered `message`, and the structured `diagnostics` decoded from
the error handle's JSON array.
"""
struct PowerIOCError <: Exception
    code::String
    message::String
    diagnostics::Any
end

function Base.showerror(io::IO, e::PowerIOCError)
    print(io, "PowerIOCError [", e.code, "]: ", e.message)
end

# Copy one v6 error handle into a Julia exception and release the handle.
function _v6_error(lib::AbstractString, err::Ptr{Cvoid})
    code = unsafe_string(ccall(_library_symbol(lib, :pio_error_code), Cstring,
                               (Ptr{Cvoid},), err))
    message = unsafe_string(ccall(_library_symbol(lib, :pio_error_message), Cstring,
                                  (Ptr{Cvoid},), err))
    diagnostics_json = unsafe_string(ccall(_library_symbol(lib, :pio_error_diagnostics_json),
                                           Cstring, (Ptr{Cvoid},), err))
    ccall(_library_symbol(lib, :pio_error_release), Cvoid, (Ptr{Cvoid},), err)
    diagnostics = try
        JSON3.read(diagnostics_json)
    catch e
        @debug "PowerIO: could not decode v6 error diagnostics JSON" exception = (e, catch_backtrace())
        JSON3.read("[]")
    end
    return PowerIOCError(code, message, diagnostics)
end

# Run one fallible v6 ccall: `f(err_ref)` returns the raw result; a non-NULL
# stored error handle throws `PowerIOCError`.
function _v6_call(f, lib::AbstractString)
    err = Ref{Ptr{Cvoid}}(C_NULL)
    result = f(err)
    err[] == C_NULL || throw(_v6_error(lib, err[]))
    return result
end

"""
    StoredModule

One runtime module: a typed value with its common records, behind an owned
ABI v6 handle. Read stored `.pio.json` text with [`read_module`](@ref), parse
a case with [`parse_module`](@ref), and write the stored version 1 document
with [`write_module`](@ref). The handle's finalizer releases it; every
retained child (an exported module, DC data) is independently owned, so
releasing this module never invalidates them.
"""
mutable struct StoredModule
    ptr::Ptr{Cvoid}
    lib::String
    function StoredModule(ptr::Ptr{Cvoid}, lib::AbstractString)
        ptr == C_NULL && error("PowerIO: null module handle")
        lib = String(lib)
        release = _library_symbol(lib, :pio_module_release)
        h = new(ptr, lib)
        finalizer(h) do x
            x.ptr == C_NULL || ccall(release, Cvoid, (Ptr{Cvoid},), x.ptr)
            x.ptr = C_NULL
        end
        return h
    end
end

function _module_ptr(m::StoredModule)
    ptr = getfield(m, :ptr)
    ptr == C_NULL && error("PowerIO: the module handle was released")
    return ptr
end

"""
    read_module(text::AbstractString) -> StoredModule

Read stored `.pio.json` text: version 1, or a released 0.9 package upgraded
one way.
"""
function read_module(text::AbstractString)
    lib = _lib()
    _ensure_compatible(lib)
    _require_export("read_module", :pio_module_read_json, "powerio v1.0", lib)
    ptr = _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_read_json), Ptr{Cvoid},
              (Cstring, Ref{Ptr{Cvoid}}), text, err)
    end
    return StoredModule(ptr, lib)
end

"""
    parse_module(path; format=nothing) -> StoredModule

Parse a case file into a module of whichever family claims it.
"""
function parse_module(path::AbstractString; format::Union{AbstractString,Nothing}=nothing)
    lib = _lib()
    _ensure_compatible(lib)
    _require_export("parse_module", :pio_module_parse_file, "powerio v1.0", lib)
    ptr = _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_parse_file), Ptr{Cvoid},
              (Cstring, Cstring, Ref{Ptr{Cvoid}}), path,
              format === nothing ? C_NULL : format, err)
    end
    return StoredModule(ptr, lib)
end

"""
    parse_module_str(text; format=nothing) -> StoredModule

Parse in-memory case text into a module.
"""
function parse_module_str(text::AbstractString;
                          format::Union{AbstractString,Nothing}=nothing)
    lib = _lib()
    _ensure_compatible(lib)
    _require_export("parse_module_str", :pio_module_parse_str, "powerio v1.0", lib)
    ptr = _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_parse_str), Ptr{Cvoid},
              (Cstring, Cstring, Ref{Ptr{Cvoid}}), text,
              format === nothing ? C_NULL : format, err)
    end
    return StoredModule(ptr, lib)
end

"""
    parse_module_bytes(bytes; format=nothing) -> StoredModule

Parse in-memory case bytes into a module: the only in-memory way to read a
binary format. Text formats must be UTF-8.
"""
function parse_module_bytes(bytes::AbstractVector{UInt8};
                            format::Union{AbstractString,Nothing}=nothing)
    lib = _lib()
    _ensure_compatible(lib)
    _require_export("parse_module_bytes", :pio_module_parse_bytes, "powerio v1.0", lib)
    data = Vector{UInt8}(bytes)
    ptr = GC.@preserve data _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_parse_bytes), Ptr{Cvoid},
              (Ptr{UInt8}, Csize_t, Cstring, Ref{Ptr{Cvoid}}), data, length(data),
              format === nothing ? C_NULL : format, err)
    end
    return StoredModule(ptr, lib)
end

"""
    write_module(m::StoredModule) -> String

The stored version 1 document.
"""
function write_module(m::StoredModule)
    lib = getfield(m, :lib)
    s = GC.@preserve m _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_write_json), Cstring,
              (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), _module_ptr(m), err)
    end
    return _take_string(lib, s)
end

"""
    module_kind(m::StoredModule) -> String

The value's permanent kind identifier (`"balanced_network"`, ...).
"""
function module_kind(m::StoredModule)
    lib = getfield(m, :lib)
    return GC.@preserve m unsafe_string(ccall(_library_symbol(lib, :pio_module_kind), Cstring,
                                              (Ptr{Cvoid},), _module_ptr(m)))
end

"""
    inspect_module(m::StoredModule)

Value inspection and supported operation discovery, decoded from JSON.
"""
function inspect_module(m::StoredModule)
    lib = getfield(m, :lib)
    s = GC.@preserve m _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_inspect_json), Cstring,
              (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), _module_ptr(m), err)
    end
    return JSON3.read(_take_string(lib, s))
end

"""
    state_inventory(m::StoredModule)

The typed time or scenario inventory of the module's value.
"""
function state_inventory(m::StoredModule)
    lib = getfield(m, :lib)
    s = GC.@preserve m _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_state_inventory_json), Cstring,
              (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), _module_ptr(m), err)
    end
    return JSON3.read(_take_string(lib, s))
end

"""
    export_state(m::StoredModule; time_position=nothing, scenario=nothing) -> StoredModule

Export one selected time point or scenario as an independent static module.
Pass exactly one key. `time_position` is zero based, matching the C ABI and
every other language binding; the first time point is `time_position=0`.
"""
function export_state(m::StoredModule;
                      time_position::Union{Integer,Nothing}=nothing,
                      scenario::Union{AbstractString,Nothing}=nothing)
    (time_position === nothing) == (scenario === nothing) &&
        error("PowerIO.export_state: pass exactly one of time_position and scenario")
    lib = getfield(m, :lib)
    position = time_position === nothing ? Int64(-1) : Int64(time_position)
    ptr = GC.@preserve m _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_export_state), Ptr{Cvoid},
              (Ptr{Cvoid}, Int64, Cstring, Ref{Ptr{Cvoid}}), _module_ptr(m), position,
              scenario === nothing ? C_NULL : scenario, err)
    end
    return StoredModule(ptr, lib)
end

"""
    lowering_readiness(m::StoredModule; base_mva=100.0)

Readiness of the multiconductor value for the balanced lowering, decoded
from JSON: the inspect half of the transformation.
"""
function lowering_readiness(m::StoredModule; base_mva::Real=100.0)
    lib = getfield(m, :lib)
    s = GC.@preserve m _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_lowering_readiness_json), Cstring,
              (Ptr{Cvoid}, Cdouble, Ref{Ptr{Cvoid}}), _module_ptr(m), base_mva, err)
    end
    return JSON3.read(_take_string(lib, s))
end

"""
    lower_module_to_balanced(m::StoredModule; base_mva=100.0) -> StoredModule

Explicitly lower a multiconductor module to a balanced module. Records and
source ownership carry over; the pass appends its findings and one Transform
history entry.
"""
function lower_module_to_balanced(m::StoredModule; base_mva::Real=100.0)
    lib = getfield(m, :lib)
    ptr = GC.@preserve m _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_lower_to_balanced), Ptr{Cvoid},
              (Ptr{Cvoid}, Cdouble, Ref{Ptr{Cvoid}}), _module_ptr(m), base_mva, err)
    end
    return StoredModule(ptr, lib)
end

# ---- DC branch data ---------------------------------------------------------

"""
    BorrowedVector{T}

A read only view over a span owned by a C result handle. The view roots the
owner, so the span stays valid for the view's lifetime; `copy` returns an
ordinary mutable `Vector{T}`. Mutation throws.
"""
struct BorrowedVector{T} <: AbstractVector{T}
    owner::Any
    ptr::Ptr{T}
    len::Int
end

Base.size(v::BorrowedVector) = (v.len,)
Base.IndexStyle(::Type{<:BorrowedVector}) = IndexLinear()
function Base.getindex(v::BorrowedVector{T}, i::Int) where {T}
    @boundscheck checkbounds(v, i)
    owner = getfield(v, :owner)
    GC.@preserve owner begin
        _dc_ptr(owner)  # raises the owner's own released-handle error first
        unsafe_load(v.ptr, i)
    end
end
Base.setindex!(::BorrowedVector, _, ::Int) =
    error("PowerIO: a BorrowedVector is read only; `copy` it for a mutable array")
function Base.copy(v::BorrowedVector{T}) where {T}
    owner = getfield(v, :owner)
    GC.@preserve owner begin
        _dc_ptr(owner)  # one release check up front, not once per element
        return T[unsafe_load(v.ptr, i) for i in eachindex(v)]
    end
end

"""
    DcData

The DC branch data of one balanced module under one susceptance formula, an
independently owned ABI v6 result: releasing the module that built it never
invalidates it. Fields with numeric spans are [`BorrowedVector`](@ref)s over
the handle's own arrays.

The public equations and signs match PowerModels directly:

    A[e, from] = +1
    A[e, to]   = -1
    B  = A' * Diagonal(b) * A
    Bf = Diagonal(b) * A
    p_shift  = -A' * (b .* shift)
    p_bus    = -B * va + p_shift
    p_branch = -Bf * va - b .* shift
"""
mutable struct DcData
    ptr::Ptr{Cvoid}
    lib::String
    function DcData(ptr::Ptr{Cvoid}, lib::AbstractString)
        ptr == C_NULL && error("PowerIO: null DC data handle")
        lib = String(lib)
        release = _library_symbol(lib, :pio_dc_data_release)
        h = new(ptr, lib)
        finalizer(h) do x
            x.ptr == C_NULL || ccall(release, Cvoid, (Ptr{Cvoid},), x.ptr)
            x.ptr = C_NULL
        end
        return h
    end
end

function _dc_ptr(d::DcData)
    ptr = getfield(d, :ptr)
    ptr == C_NULL && error("PowerIO: the DC data handle was released")
    return ptr
end

"""
    dc_data(m::StoredModule; formula="series_susceptance") -> DcData

Build the DC branch data of the module's balanced network value. Formulas:
`series_susceptance` (`imag(inv(r + im*x))` with the PowerModels sign),
`tap_adjusted_reactance` (`1/(x*tap)`), `reactance_only` (`1/x`).
"""
function dc_data(m::StoredModule; formula::AbstractString="series_susceptance")
    lib = getfield(m, :lib)
    ptr = GC.@preserve m _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_dc_data_build), Ptr{Cvoid},
              (Ptr{Cvoid}, Cstring, Ref{Ptr{Cvoid}}), _module_ptr(m), formula, err)
    end
    return DcData(ptr, lib)
end

_dc_len(d::DcData, sym::Symbol) =
    Int(GC.@preserve d ccall(_library_symbol(getfield(d, :lib), sym), Csize_t,
                             (Ptr{Cvoid},), _dc_ptr(d)))

"""Included incidence row count (`m`)."""
n_rows(d::DcData) = _dc_len(d, :pio_dc_data_n_rows)

"""Incidence column count (`n`, the bus count)."""
n_buses(d::DcData) = _dc_len(d, :pio_dc_data_n_buses)

function _dc_span(d::DcData, sym::Symbol, ::Type{T}, len::Int) where {T}
    lib = getfield(d, :lib)
    ptr = GC.@preserve d ccall(_library_symbol(lib, sym), Ptr{T}, (Ptr{Cvoid},), _dc_ptr(d))
    ptr == C_NULL && error("PowerIO: NULL DC data span")
    return BorrowedVector{T}(d, ptr, len)
end

"""From bus column per included row (`A[e, from] = +1`), zero based."""
from_indices(d::DcData) = _dc_span(d, :pio_dc_data_from_indices, Int64, n_rows(d))

"""To bus column per included row (`A[e, to] = -1`), zero based."""
to_indices(d::DcData) = _dc_span(d, :pio_dc_data_to_indices, Int64, n_rows(d))

"""Branch susceptance per included row, PowerModels sign."""
susceptance(d::DcData) = _dc_span(d, :pio_dc_data_susceptance, Float64, n_rows(d))

"""Branch phase shift angle per included row, radians (the `shift` in `p_branch = -Bf * va - b .* shift`)."""
shift(d::DcData) = _dc_span(d, :pio_dc_data_shift, Float64, n_rows(d))

"""Phase shift bus injection `p_shift = -A' * (b .* shift)`, per bus."""
shift_injection(d::DcData) = _dc_span(d, :pio_dc_data_shift_injection, Float64, n_buses(d))

# Read a C string table (`const char *const *`): `sym` is the table itself,
# `count_sym` is the count accessor that owns its length. The length always
# comes from calling `count_sym` here, never from a value a caller already had
# on hand; `expected`, when given, is that caller's independently obtained
# belief about the same count (e.g. a public `n_rows`/`n_buses` it already
# read), checked against `count_sym` so a disagreement is a directed error
# instead of a bounds fault deep in a matrix build.
function _dc_strings(d::DcData, sym::Symbol, count_sym::Symbol,
                     expected::Union{Int,Nothing}=nothing)
    len = _dc_len(d, count_sym)
    if expected !== nothing && expected != len
        error("PowerIO: $sym has $len entries ($count_sym), expected $expected")
    end
    lib = getfield(d, :lib)
    table = GC.@preserve d ccall(_library_symbol(lib, sym), Ptr{Cstring},
                                 (Ptr{Cvoid},), _dc_ptr(d))
    table == C_NULL && return String[]
    return GC.@preserve d String[_dc_string_entry(sym, table, i, len) for i in 1:len]
end

# One entry of a C string table: a NULL this far into a table whose own count
# accessor claims `len` entries is the table and its count disagreeing about
# what is actually populated, not an absent table (already handled above), so
# it gets its own directed error rather than surfacing as unsafe_string's
# generic "cannot convert NULL to string".
function _dc_string_entry(sym::Symbol, table::Ptr{Cstring}, i::Int, len::Int)
    p = unsafe_load(table, i)
    p == C_NULL && error("PowerIO: $sym has a NULL entry at index $i of $len")
    return unsafe_string(p)
end

"""Stable module element ID per included row."""
row_ids(d::DcData) = _dc_strings(d, :pio_dc_data_row_ids, :pio_dc_data_n_rows, n_rows(d))

"""Stable bus element ID per incidence column."""
bus_ids(d::DcData) = _dc_strings(d, :pio_dc_data_bus_ids, :pio_dc_data_n_buses, n_buses(d))

"""Omitted branches: stable element IDs and diagnostic reasons."""
function omitted(d::DcData)
    count = _dc_len(d, :pio_dc_data_n_omitted)
    ids = _dc_strings(d, :pio_dc_data_omitted_ids, :pio_dc_data_n_omitted, count)
    reasons = _dc_strings(d, :pio_dc_data_omitted_reasons, :pio_dc_data_n_omitted, count)
    return collect(zip(ids, reasons))
end

"""The selected branch susceptance formula's stable name."""
function formula(d::DcData)
    lib = getfield(d, :lib)
    return GC.@preserve d unsafe_string(ccall(_library_symbol(lib, :pio_dc_data_formula), Cstring,
                                              (Ptr{Cvoid},), _dc_ptr(d)))
end

"""
    branch_flow(d::DcData, va::AbstractVector{<:Real}) -> Vector{Float64}

The complete affine branch flow `p_branch = -Bf * va - b .* shift`, per row
`-b[e] * (va_from - va_to) - b[e] * shift[e]`, filled by the C library with
no intermediate vector beyond the result. The phase shift term is included
in the returned values; [`shift`](@ref) is the per row `shift` the fill
uses. `va` is per bus, radians.
"""
function branch_flow(d::DcData, va::AbstractVector{<:Real})
    lib = getfield(d, :lib)
    rows = n_rows(d)
    buses = n_buses(d)
    length(va) == buses ||
        error("PowerIO.branch_flow: va has $(length(va)) entries for $buses buses")
    angles = Vector{Float64}(va)
    out = Vector{Float64}(undef, rows)
    ok = GC.@preserve d angles out ccall(_library_symbol(lib, :pio_dc_data_fill_branch_flow),
                                         Bool,
                                         (Ptr{Cvoid}, Ptr{Float64}, Csize_t, Ptr{Float64}, Csize_t),
                                         _dc_ptr(d), angles, length(angles), out, length(out))
    ok || error("PowerIO.branch_flow: the fill was refused")
    return out
end

# ---- typed record access ----------------------------------------------------

"""
    ModuleDiagnostic

One durable finding on a stored module: `code`, `severity`, `message`, and
the optional `target` pointer into the value.
"""
struct ModuleDiagnostic
    code::String
    severity::String
    message::String
    target::Union{String,Nothing}
end

"""
    ModuleHistoryEntry

One structured, descriptive operation in a module's history: `id`, `kind`
(`"parse"`, `"upgrade"`, `"transform"`, ...), `name`, and the stated
`assumptions` and `losses`. History describes; it does not replay.
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

# The stored document is the wire; decoding records from it reads exactly what
# `write_module` states, no whole network re-serialization beyond that wire.
function _stored_document(m::StoredModule)
    return JSON3.read(write_module(m))
end

_record_string(row, key) = haskey(row, key) ? String(row[key]) : nothing

"""
    module_diagnostics(m::StoredModule) -> Vector{ModuleDiagnostic}

The module's durable findings, decoded from the stored document.
"""
function module_diagnostics(m::StoredModule)
    document = _stored_document(m)
    rows = get(document, :diagnostics, nothing)
    rows === nothing && return ModuleDiagnostic[]
    return [ModuleDiagnostic(String(row.code), String(row.severity), String(row.message),
                             _record_string(row, :target)) for row in rows]
end

"""
    module_history(m::StoredModule) -> Vector{ModuleHistoryEntry}

The module's descriptive history, decoded from the stored document.
"""
function module_history(m::StoredModule)
    document = _stored_document(m)
    rows = get(document, :history, nothing)
    rows === nothing && return ModuleHistoryEntry[]
    return [ModuleHistoryEntry(
                String(row.id), String(row.kind), String(row.name),
                haskey(row, :assumptions) ? String.(row.assumptions) : String[],
                haskey(row, :losses) ? String.(row.losses) : String[],
            ) for row in rows]
end

"""
    module_sources(m::StoredModule) -> Vector{ModuleSource}

The sources the module was compiled from, decoded from the stored document.
"""
function module_sources(m::StoredModule)
    document = _stored_document(m)
    rows = get(document, :sources, nothing)
    rows === nothing && return ModuleSource[]
    return [ModuleSource(String(row.id), String(row.name), Int(row.byte_length),
                         _record_string(row, :format)) for row in rows]
end

# ---- assembled DC matrices --------------------------------------------------

"""
    incidence_matrix(d::DcData) -> SparseMatrixCSC{Float64,Int}

The signed incidence `A` (`m × n`): `A[e, from] = +1`, `A[e, to] = -1`,
assembled from the DC data's own spans with no temporary sign converted
vector — the spans already carry the PowerModels orientation.
"""
function incidence_matrix(d::DcData)
    rows = n_rows(d)
    from = from_indices(d)
    to = to_indices(d)
    i = Vector{Int}(undef, 2rows)
    j = Vector{Int}(undef, 2rows)
    v = Vector{Float64}(undef, 2rows)
    for e in 1:rows
        i[2e - 1] = e
        j[2e - 1] = Int(from[e]) + 1
        v[2e - 1] = 1.0
        i[2e] = e
        j[2e] = Int(to[e]) + 1
        v[2e] = -1.0
    end
    return SparseArrays.sparse(i, j, v, rows, n_buses(d))
end

"""
    susceptance_laplacian(d::DcData) -> SparseMatrixCSC{Float64,Int}

The DC Laplacian `B = A' * Diagonal(b) * A` (`n × n`), PowerModels sign,
assembled from the DC data's spans.
"""
function susceptance_laplacian(d::DcData)
    a = incidence_matrix(d)
    return a' * SparseArrays.spdiagm(0 => copy(susceptance(d))) * a
end

"""
    flow_matrix(d::DcData) -> SparseMatrixCSC{Float64,Int}

The branch flow map `Bf = Diagonal(b) * A` (`m × n`), PowerModels sign, so
`p_branch = -Bf * va - b .* shift`.
"""
function flow_matrix(d::DcData)
    a = incidence_matrix(d)
    return SparseArrays.spdiagm(0 => copy(susceptance(d))) * a
end

"""
    bus_injection(d::DcData, va::AbstractVector{<:Real}) -> Vector{Float64}

The DC bus injection `p_bus = -B * va + p_shift`, PowerModels sign.
"""
function bus_injection(d::DcData, va::AbstractVector{<:Real})
    length(va) == n_buses(d) ||
        error("PowerIO.bus_injection: va has $(length(va)) entries for $(n_buses(d)) buses")
    return -(susceptance_laplacian(d) * Vector{Float64}(va)) + copy(shift_injection(d))
end
