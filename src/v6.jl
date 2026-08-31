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
    PowerIOError

A structured failure from an ABI v6 entry point: the stable diagnostic
`code`, the rendered `message`, and the structured `diagnostics` decoded from
the error handle's JSON array.
"""
struct PowerIOError <: Exception
    code::String
    message::String
    diagnostics::Vector{Diagnostic}
end

function Base.showerror(io::IO, e::PowerIOError)
    # The C side already prefixes `message` with `code:` for some failure
    # classes and leaves it off for others; strip the prefix when present so
    # the code renders exactly once.
    message = lstrip(chopprefix(e.message, e.code * ":"))
    print(io, "PowerIOError [", e.code, "]: ", message)
end

# Copy one v6 error handle into a Julia exception and release the handle. The
# findings cross as native records through the structured diagnostics handle.
function _v6_error(lib::AbstractString, err::Ptr{Cvoid})
    code = unsafe_string(ccall(_library_symbol(lib, :pio_error_code), Cstring,
                               (Ptr{Cvoid},), err))
    message = unsafe_string(ccall(_library_symbol(lib, :pio_error_message), Cstring,
                                  (Ptr{Cvoid},), err))
    diagnostics = _diagnostics_of(lib) do e
        ccall(_library_symbol(lib, :pio_error_diagnostics), Ptr{Cvoid},
              (Ptr{Cvoid},), err)
    end
    ccall(_library_symbol(lib, :pio_error_release), Cvoid, (Ptr{Cvoid},), err)
    return PowerIOError(code, message, diagnostics)
end

# Run one fallible v6 ccall: `f(err_ref)` returns the raw result; a non-NULL
# stored error handle throws `PowerIOError`.
function _v6_call(f, lib::AbstractString)
    err = Ref{Ptr{Cvoid}}(C_NULL)
    result = f(err)
    err[] == C_NULL || throw(_v6_error(lib, err[]))
    return result
end

"""
    StoredModule

One runtime module: a typed value with its common records, behind an owned
ABI v6 handle. Internal: [`PioModule`](@ref) wraps it, and the public
surface reads and writes it through [`parse_file`](@ref) and [`to_json`](@ref).
The handle's finalizer releases it; every
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
    _require_export("read_module", :pio_module_read_json, "a PowerIO ABI 6 library", lib)
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
    _require_export("parse_module", :pio_parse_file, "a PowerIO ABI 6 library", lib)
    ptr = _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_parse_file), Ptr{Cvoid},
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
                          name::AbstractString="<memory>",
                          format::Union{AbstractString,Nothing}=nothing)
    lib = _lib()
    _ensure_compatible(lib)
    _require_export("parse_module_str", :pio_parse_str, "a PowerIO ABI 6 library", lib)
    ptr = _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_parse_str), Ptr{Cvoid},
              (Cstring, Cstring, Cstring, Ref{Ptr{Cvoid}}), name, text,
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
                            name::AbstractString="<memory>",
                            format::Union{AbstractString,Nothing}=nothing)
    lib = _lib()
    _ensure_compatible(lib)
    _require_export("parse_module_bytes", :pio_parse_bytes, "a PowerIO ABI 6 library", lib)
    data = Vector{UInt8}(bytes)
    ptr = GC.@preserve data _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_parse_bytes), Ptr{Cvoid},
              (Cstring, Ptr{UInt8}, Csize_t, Cstring, Ref{Ptr{Cvoid}}), name, data,
              length(data), format === nothing ? C_NULL : format, err)
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
    list_states(m::StoredModule)

List the typed time points or scenarios of the module's value.
"""
function list_states(m::StoredModule)
    lib = getfield(m, :lib)
    symbol = _preferred_symbol(
        :pio_module_list_states_json,
        :pio_module_state_inventory_json,
        lib,
    )
    s = GC.@preserve m _v6_call(lib) do err
        ccall(_library_symbol(lib, symbol), Cstring,
              (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), _module_ptr(m), err)
    end
    return JSON3.read(_take_string(lib, s))
end

"""
    _export_state(m::StoredModule; time_position=nothing, scenario=nothing) -> StoredModule

Export one selected time point or scenario as an independent static module.
Pass exactly one key. `time_position` is zero based, matching the C ABI and
every other language binding; the first time point is `time_position=0`.
"""
function _export_state(m::StoredModule;
                       time_position::Union{Integer,Nothing}=nothing,
                       scenario::Union{AbstractString,Nothing}=nothing)
    (time_position === nothing) == (scenario === nothing) &&
        error("PowerIO._export_state: pass exactly one of time_position and scenario")
    lib = getfield(m, :lib)
    ptr = if time_position !== nothing && time_position >= 0 &&
             _exports_symbol(:pio_module_export_time_point, lib)
        position = Csize_t(time_position)
        GC.@preserve m _v6_call(lib) do err
            ccall(_library_symbol(lib, :pio_module_export_time_point), Ptr{Cvoid},
                  (Ptr{Cvoid}, Csize_t, Ref{Ptr{Cvoid}}),
                  _module_ptr(m), position, err)
        end
    elseif scenario !== nothing && _exports_symbol(:pio_module_export_scenario, lib)
        GC.@preserve m _v6_call(lib) do err
            ccall(_library_symbol(lib, :pio_module_export_scenario), Ptr{Cvoid},
                  (Ptr{Cvoid}, Cstring, Ref{Ptr{Cvoid}}),
                  _module_ptr(m), scenario, err)
        end
    else
        position = time_position === nothing ? Int64(-1) : Int64(time_position)
        GC.@preserve m _v6_call(lib) do err
            ccall(_library_symbol(lib, :pio_module_export_state), Ptr{Cvoid},
                  (Ptr{Cvoid}, Int64, Cstring, Ref{Ptr{Cvoid}}),
                  _module_ptr(m), position, scenario === nothing ? C_NULL : scenario, err)
        end
    end
    return StoredModule(ptr, lib)
end

"""
    _to_balanced_report(m::StoredModule; base_mva=100.0)

Readiness of the multiconductor value for the balanced transformation,
decoded from JSON as `ready` plus structured `diagnostics`.
"""
function _to_balanced_report(m::StoredModule; base_mva::Real=100.0)
    lib = getfield(m, :lib)
    symbol = _preferred_symbol(:pio_module_to_balanced_report_json,
                               :pio_module_lowering_readiness_json, lib)
    s = GC.@preserve m _v6_call(lib) do err
        ccall(_library_symbol(lib, symbol), Cstring,
              (Ptr{Cvoid}, Cdouble, Ref{Ptr{Cvoid}}), _module_ptr(m), base_mva, err)
    end
    return JSON3.read(_take_string(lib, s))
end

"""
    _to_balanced_module(m::StoredModule; base_mva=100.0) -> StoredModule

Transform a multiconductor module to a balanced module. The pass
appends its findings and one Transform history entry; the source
descriptors carry over, but not the retained bytes, so a later emission in the
original format cannot echo the source exactly.
"""
function _to_balanced_module(m::StoredModule; base_mva::Real=100.0)
    lib = getfield(m, :lib)
    symbol = _preferred_symbol(:pio_module_to_balanced,
                               :pio_module_lower_to_balanced, lib)
    ptr = GC.@preserve m _v6_call(lib) do err
        ccall(_library_symbol(lib, symbol), Ptr{Cvoid},
              (Ptr{Cvoid}, Cdouble, Ref{Ptr{Cvoid}}), _module_ptr(m), base_mva, err)
    end
    return StoredModule(ptr, lib)
end

# ---- private DC calculation machinery --------------------------------------

# ABI 6 exposes an owned DC data handle and borrowed numeric spans. Julia 1.0
# keeps that representation private: callers ask for a named matrix or vector,
# and these helpers acquire and release the C handle inside that calculation.
struct _BorrowedVector{T} <: AbstractVector{T}
    owner::Any
    ptr::Ptr{T}
    len::Int
end

Base.size(v::_BorrowedVector) = (v.len,)
Base.IndexStyle(::Type{<:_BorrowedVector}) = IndexLinear()
function Base.getindex(v::_BorrowedVector{T}, i::Int) where {T}
    @boundscheck checkbounds(v, i)
    owner = getfield(v, :owner)
    GC.@preserve owner begin
        _dc_ptr(owner)
        return unsafe_load(v.ptr, i)
    end
end
Base.setindex!(::_BorrowedVector, _, ::Int) =
    error("PowerIO: a borrowed DC view is read only; copy it for a mutable array")
function Base.copy(v::_BorrowedVector{T}) where {T}
    owner = getfield(v, :owner)
    GC.@preserve owner begin
        _dc_ptr(owner)
        return T[unsafe_load(v.ptr, i) for i in eachindex(v)]
    end
end

mutable struct _DcData
    ptr::Ptr{Cvoid}
    lib::String
    function _DcData(ptr::Ptr{Cvoid}, lib::AbstractString)
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

function _dc_ptr(d::_DcData)
    ptr = getfield(d, :ptr)
    ptr == C_NULL && error("PowerIO: the private DC data handle was released")
    return ptr
end

function _dc_data(m::StoredModule;
                  formula::AbstractString="series_susceptance")
    lib = getfield(m, :lib)
    _require_export("DC calculations", :pio_dc_data_build,
                    "a PowerIO ABI 6 library", lib)
    ptr = GC.@preserve m _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_dc_data_build), Ptr{Cvoid},
              (Ptr{Cvoid}, Cstring, Ref{Ptr{Cvoid}}), _module_ptr(m), formula, err)
    end
    return _DcData(ptr, lib)
end

_dc_len(d::_DcData, sym::Symbol) =
    Int(GC.@preserve d ccall(_library_symbol(getfield(d, :lib), sym), Csize_t,
                             (Ptr{Cvoid},), _dc_ptr(d)))

function _dc_n_branches(d::_DcData)
    lib = getfield(d, :lib)
    symbol = _preferred_symbol(:pio_dc_data_n_branches, :pio_dc_data_n_rows, lib)
    return _dc_len(d, symbol)
end

_dc_n_buses(d::_DcData) = _dc_len(d, :pio_dc_data_n_buses)

function _dc_span(d::_DcData, sym::Symbol, ::Type{T}, len::Int) where {T}
    lib = getfield(d, :lib)
    ptr = GC.@preserve d ccall(_library_symbol(lib, sym), Ptr{T},
                               (Ptr{Cvoid},), _dc_ptr(d))
    ptr == C_NULL && error("PowerIO: NULL private DC data span")
    return _BorrowedVector{T}(d, ptr, len)
end

_dc_from_indices(d::_DcData) =
    _dc_span(d, :pio_dc_data_from_indices, Int64, _dc_n_branches(d))
_dc_to_indices(d::_DcData) =
    _dc_span(d, :pio_dc_data_to_indices, Int64, _dc_n_branches(d))
_dc_susceptance(d::_DcData) =
    _dc_span(d, :pio_dc_data_susceptance, Float64, _dc_n_branches(d))
_dc_shift(d::_DcData) =
    _dc_span(d, :pio_dc_data_shift, Float64, _dc_n_branches(d))
_dc_shift_injection(d::_DcData) =
    _dc_span(d, :pio_dc_data_shift_injection, Float64, _dc_n_buses(d))

function _dc_strings(d::_DcData, sym::Symbol, count_sym::Symbol,
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

function _dc_string_entry(sym::Symbol, table::Ptr{Cstring}, i::Int, len::Int)
    p = unsafe_load(table, i)
    p == C_NULL && error("PowerIO: $sym has a NULL entry at index $i of $len")
    return unsafe_string(p)
end

function _dc_branch_ids(d::_DcData)
    lib = getfield(d, :lib)
    ids_symbol = _preferred_symbol(:pio_dc_data_branch_ids, :pio_dc_data_row_ids, lib)
    count_symbol = _preferred_symbol(:pio_dc_data_n_branches, :pio_dc_data_n_rows, lib)
    return _dc_strings(d, ids_symbol, count_symbol, _dc_n_branches(d))
end

_dc_bus_ids(d::_DcData) =
    _dc_strings(d, :pio_dc_data_bus_ids, :pio_dc_data_n_buses, _dc_n_buses(d))

function _dc_omitted(d::_DcData)
    count = _dc_len(d, :pio_dc_data_n_omitted)
    ids = _dc_strings(d, :pio_dc_data_omitted_ids, :pio_dc_data_n_omitted, count)
    reasons = _dc_strings(d, :pio_dc_data_omitted_reasons, :pio_dc_data_n_omitted, count)
    return collect(zip(ids, reasons))
end

function _dc_formula(d::_DcData)
    lib = getfield(d, :lib)
    return GC.@preserve d unsafe_string(ccall(
        _library_symbol(lib, :pio_dc_data_formula), Cstring,
        (Ptr{Cvoid},), _dc_ptr(d),
    ))
end

function _dc_calc_branch_flow(d::_DcData, va::AbstractVector{<:Real})
    lib = getfield(d, :lib)
    rows = _dc_n_branches(d)
    buses = _dc_n_buses(d)
    length(va) == buses ||
        error("PowerIO.calc_branch_flow_dc: voltage_angles has $(length(va)) entries for $buses buses")
    angles = Vector{Float64}(va)
    out = Vector{Float64}(undef, rows)
    checked_symbol = if _exports_symbol(:pio_dc_data_calc_branch_flow, lib)
        :pio_dc_data_calc_branch_flow
    elseif _exports_symbol(:pio_dc_data_fill_branch_flow_checked, lib)
        :pio_dc_data_fill_branch_flow_checked
    else
        nothing
    end
    ok = if checked_symbol !== nothing
        GC.@preserve d angles out _v6_call(lib) do err
            ccall(_library_symbol(lib, checked_symbol), Bool,
                  (Ptr{Cvoid}, Ptr{Float64}, Csize_t, Ptr{Float64}, Csize_t,
                   Ref{Ptr{Cvoid}}),
                  _dc_ptr(d), angles, length(angles), out, length(out), err)
        end
    else
        GC.@preserve d angles out ccall(
            _library_symbol(lib, :pio_dc_data_fill_branch_flow), Bool,
            (Ptr{Cvoid}, Ptr{Float64}, Csize_t, Ptr{Float64}, Csize_t),
            _dc_ptr(d), angles, length(angles), out, length(out))
    end
    ok || error("PowerIO.calc_branch_flow_dc: the calculation was refused")
    return out
end

function _dc_calc_incidence_matrix(d::_DcData)
    rows = _dc_n_branches(d)
    from = _dc_from_indices(d)
    to = _dc_to_indices(d)
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
    return SparseArrays.sparse(i, j, v, rows, _dc_n_buses(d))
end

function _dc_calc_bus_susceptance_matrix(d::_DcData)
    a = _dc_calc_incidence_matrix(d)
    return a' * SparseArrays.spdiagm(0 => copy(_dc_susceptance(d))) * a
end

function _dc_calc_branch_susceptance_matrix(d::_DcData)
    a = _dc_calc_incidence_matrix(d)
    return SparseArrays.spdiagm(0 => copy(_dc_susceptance(d))) * a
end

function _dc_calc_bus_injection(d::_DcData, va::AbstractVector{<:Real})
    buses = _dc_n_buses(d)
    length(va) == buses ||
        error("PowerIO.calc_bus_injection_dc: voltage_angles has $(length(va)) entries for $buses buses")
    return -(_dc_calc_bus_susceptance_matrix(d) * Vector{Float64}(va)) +
           copy(_dc_shift_injection(d))
end
