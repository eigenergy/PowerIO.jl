# Two readers, one per field role.
#
# `_powerdata_bound` accepts a finite value or ±Inf and refuses a NaN: an
# absent reactive limit is `Inf` in MATPOWER, PowerModels, pandapower and
# PyPSA, and stock case9241pegase.m carries it on seven generators, so a
# finiteness check there refuses a case whose data is fine.
#
# `_powerdata_real` is that reader plus a finiteness check, and it is the one
# for every field that is not a bound. 0.9 relaxed the check for the bound
# case and relaxed it for the whole row, so an infinite series reactance, tap
# ratio, voltage magnitude or base kV reached the caller — and for `br_x` it
# did not stop there, since `_branch_coeffs` ran on it in the same `let` block
# and the row carried admittance coefficients derived from `1/Inf` with
# nothing recorded. The Rust core moved the other way in the same release
# (#292): `branch_susceptance` returns `NaN` for a denominator that is not
# finite, and `IncidenceParts` errors with `NonFiniteSusceptance` rather than
# assembling. An infinite reactance is a corrupt case there and was a valid
# row here.
#
# The split is by whether a source format spells "no bound" as ±Inf, not by
# whether a field is a limit: no format spells "no voltage limit" that way, so
# `vmin`/`vmax` are a data defect rather than a convention and read as reals.

function _powerdata_bound(x, ::Type{T}, element::AbstractString,
                         field::Symbol) where {T<:Real}
    x === nothing &&
        throw(ArgumentError("PowerIO.to_powerdata: $element has missing field `$field`"))
    y = try
        _json_float(T, x)
    catch err
        msg = sprint(showerror, err)
        throw(ArgumentError("PowerIO.to_powerdata: $element has invalid field `$field`: $msg"))
    end
    # An infinite limit is how MATPOWER, PowerModels, pandapower and PyPSA spell
    # "no bound", so it passes through here. A NaN carries no such reading, and
    # `_powerdata_real` is the reader for a field that is not a bound.
    isnan(y) &&
        throw(ArgumentError("PowerIO.to_powerdata: $element has NaN field `$field`"))
    return y
end

function _powerdata_bound(x::Union{Float64,Int64}, ::Type{T},
                         element::AbstractString, field::Symbol) where {T<:Real}
    y = T(x)
    isnan(y) &&
        throw(ArgumentError("PowerIO.to_powerdata: $element has NaN field `$field`"))
    return y
end

function _powerdata_bound(x::String, ::Type{T}, element::AbstractString,
                         field::Symbol) where {T<:Real}
    y = if x == "Infinity"
        T(Inf)
    elseif x == "-Infinity"
        T(-Inf)
    elseif x == "NaN"
        T(NaN)
    else
        throw(ArgumentError(
            "PowerIO.to_powerdata: $element has invalid field `$field`: " *
            "$(repr(x)) is neither a number nor a nonfinite spelling"))
    end
    isnan(y) &&
        throw(ArgumentError("PowerIO.to_powerdata: $element has NaN field `$field`"))
    return y
end

# A field that is not a bound. `_powerdata_bound` first, so the NaN and the
# unparseable-string messages stay identical whichever reader a call site picks.
function _powerdata_real(x, ::Type{T}, element::AbstractString,
                         field::Symbol) where {T<:Real}
    y = _powerdata_bound(x, T, element, field)
    isfinite(y) || throw(ArgumentError(
        "PowerIO.to_powerdata: $element has nonfinite field `$field` ($y); " *
        "an infinite value spells an absent bound and `$field` is not a bound"))
    return y
end

function _quadratic_cost_coeffs(coeffs::Vector{T}, base::T,
                                normalized::Bool) where {T<:Real}
    scaled = copy(coeffs)
    if !normalized
        k = length(scaled)
        for i in eachindex(scaled)
            scaled[i] *= base^(k - i)
        end
    end
    while length(scaled) > 3 && iszero(first(scaled))
        popfirst!(scaled)
    end
    length(scaled) > 3 &&
        throw(ArgumentError("PowerIO.to_powerdata: polynomial generator cost cannot fit PowerData quadratic cost"))

    vals = [zero(T), zero(T), zero(T)]
    offset = 3 - length(scaled)
    for (i, c) in enumerate(scaled)
        vals[offset + i] = c
    end
    return vals
end

function _cost_tuple(g, ::Type{T}, base::T; normalized::Bool=false) where {T<:Real}
    cost = g.cost
    cost === nothing && return (false, zero(T), zero(T), 0, (zero(T), zero(T), zero(T)))
    coeffs = T[_powerdata_real(c, T, "generator cost", :coeffs) for c in cost.coeffs]
    model = Int(cost.model)
    n = Int(cost.ncost)
    if model == 2
        limit = min(n, length(coeffs))
        trimmed = limit == 0 ? T[] : coeffs[1:limit]
        vals = _quadratic_cost_coeffs(trimmed, base, normalized)
        return (true,
                _powerdata_real(cost.startup, T, "generator cost", :startup),
                _powerdata_real(cost.shutdown, T, "generator cost", :shutdown),
                3, (vals[1], vals[2], vals[3]))
    else
        limit = model == 1 ? min(2 * n, length(coeffs)) : length(coeffs)
        trimmed = limit == 0 ? T[] : coeffs[1:limit]
        vals = [zero(T), zero(T), zero(T)]
        for i in 1:min(3, length(trimmed))
            vals[i] = trimmed[i]
        end
    end
    # Only reached for model != 2 (the model-2 quadratic case returned above), so
    # this is never a polynomial cost: model_poly is false.
    return (false,
            _powerdata_real(cost.startup, T, "generator cost", :startup),
            _powerdata_real(cost.shutdown, T, "generator cost", :shutdown),
            n, (vals[1], vals[2], vals[3]))
end

function _branch_coeffs(r::T, x::T, b_fr::T, b_to::T, g_fr::T, g_to::T,
                        tap::T, shift::T) where {T<:Real}
    y = iszero(r) && iszero(x) ? zero(Complex{T}) : inv(complex(r, x))
    isfinite(real(y)) && isfinite(imag(y)) || (y = zero(Complex{T}))
    g = real(y)
    b = imag(y)
    tap_eff = isapprox(tap, zero(T)) ? one(T) : tap
    tr = tap_eff * cos(shift)
    ti = tap_eff * sin(shift)
    ttm = tr^2 + ti^2
    return (
        (-g * tr - b * ti) / ttm,
        (-b * tr + g * ti) / ttm,
        (-g * tr + b * ti) / ttm,
        (-b * tr - g * ti) / ttm,
        (g + g_fr) / ttm,
        (b + b_fr) / ttm,
        g + g_to,
        b + b_to,
    )
end

_powerdata_storage_row_type(::Type{T}) where {T<:Real} = @NamedTuple{
    i::Int,
    storage_bus::Int,
    Pexts::T,
    Qexts::T,
    energy::T,
    energy_rating::T,
    charge_rating::T,
    discharge_rating::T,
    charge_efficiency::T,
    discharge_efficiency::T,
    thermal_rating::T,
    qmin::T,
    qmax::T,
    Zr::T,
    Zim::T,
    p_loss::T,
    q_loss::T,
    status::Int,
}

# The bus/gen/branch/arc/storage rows of `to_powerdata` are built into these
# concrete `@NamedTuple` row types. They are the ExaModelsPower bridge schema:
# the field names ExaModelsPower's `build_*_opf` reads. This schema is a Julia
# bridge (like `to_powermodels`) and does not port to the Rust core / C ABI, so
# these declarations are the single source of truth for it.
#
# Each row literal below is wrapped in its row type's constructor
# (`GenRow((; ...))`), which selects fields by NAME. The literal's field order is
# therefore irrelevant, so the declaration order here and the literal order
# cannot drift apart: a name typo or an omitted field errors, a reordering does
# not. The outer typed comprehension (`GenRow[ ... ]`) keeps an empty section a
# concrete `Vector{Row}` rather than a comprehension inferring `Vector{Any}`,
# which `CuArray` rejects when ExaModelsPower moves the rows to the GPU.
#
# These declarations are hand maintained rather than inferred from `to_dense`'s
# typed columns because `to_dense` exposes only the minimal numeric subset the
# matrix-assembly path needs. Deriving these rows from it would require the C ABI
# to also surface: bus `type`/`vm`/`va`/`base_kv`/`area`/`zone`/`vmax`/`vmin` and
# the REF/PV/PQ reassignment; generator `qg`/`qmax`/`qmin`/`vg`/`mbase` and the
# parsed cost model (startup/shutdown/ncost/coefficients); branch
# `rate_a`/`rate_b`/`rate_c`/`angmin`/`angmax` and the `c1..c8` line coefficients;
# and the full storage table. Until the dense extractors carry those fields, the
# row schema is built here from the accessors.
_powerdata_bus_row_type(::Type{T}) where {T<:Real} = @NamedTuple{
    i::Int,
    bus_i::Int,
    type::Int,
    pd::T,
    qd::T,
    gs::T,
    bs::T,
    area::Int,
    vm::T,
    va::T,
    baseKV::T,
    zone::Int,
    vmax::T,
    vmin::T,
}

_powerdata_gen_row_type(::Type{T}) where {T<:Real} = @NamedTuple{
    i::Int,
    bus::Int,
    pg::T,
    qg::T,
    qmax::T,
    qmin::T,
    vg::T,
    mbase::T,
    status::Int,
    pmax::T,
    pmin::T,
    model_poly::Bool,
    startup::T,
    shutdown::T,
    n::Int,
    c::Tuple{T,T,T},
}

_powerdata_branch_row_type(::Type{T}) where {T<:Real} = @NamedTuple{
    i::Int,
    f_bus::Int,
    t_bus::Int,
    br_r::T,
    br_x::T,
    b_fr::T,
    b_to::T,
    g_fr::T,
    g_to::T,
    rate_a::T,
    rate_b::T,
    rate_c::T,
    tap::T,
    shift::T,
    status::Int,
    angmin::T,
    angmax::T,
    f_idx::Int,
    t_idx::Int,
    c1::T,
    c2::T,
    c3::T,
    c4::T,
    c5::T,
    c6::T,
    c7::T,
    c8::T,
}

_powerdata_arc_row_type(::Type{T}) where {T<:Real} = @NamedTuple{
    i::Int,
    bus::Int,
    rate_a::T,
}

# JSON3's schema-free `Array` accessor intentionally erases its element type.
# That is useful for the public rich payload, but it leaves every row as `Any`
# in an ahead of time call graph. Decode only the fields this bridge reads into
# a closed schema before building its concrete output rows.
const _PowerdataNumber = Union{Float64,Int64,String}
abstract type _PowerdataInputRecord end

struct _PowerdataCostInput <: _PowerdataInputRecord
    model::Int64
    startup::_PowerdataNumber
    shutdown::_PowerdataNumber
    ncost::Int64
    coeffs::Vector{_PowerdataNumber}
end

struct _PowerdataBusInput <: _PowerdataInputRecord
    id::Int64
    kind::String
    vm::_PowerdataNumber
    va::_PowerdataNumber
    base_kv::_PowerdataNumber
    vmax::_PowerdataNumber
    vmin::_PowerdataNumber
    area::Int64
    zone::Int64
end

struct _PowerdataLoadInput <: _PowerdataInputRecord
    bus::Int64
    p::_PowerdataNumber
    q::_PowerdataNumber
    in_service::Bool
end

struct _PowerdataShuntInput <: _PowerdataInputRecord
    bus::Int64
    g::_PowerdataNumber
    b::_PowerdataNumber
    in_service::Bool
end

struct _PowerdataGeneratorInput <: _PowerdataInputRecord
    bus::Int64
    pg::_PowerdataNumber
    qg::_PowerdataNumber
    pmax::_PowerdataNumber
    pmin::_PowerdataNumber
    qmax::_PowerdataNumber
    qmin::_PowerdataNumber
    vg::_PowerdataNumber
    mbase::_PowerdataNumber
    in_service::Bool
    cost::Union{Nothing,_PowerdataCostInput}
end

struct _PowerdataBranchInput <: _PowerdataInputRecord
    from::Int64
    to::Int64
    r::_PowerdataNumber
    x::_PowerdataNumber
    b::_PowerdataNumber
    rate_a::_PowerdataNumber
    rate_b::_PowerdataNumber
    rate_c::_PowerdataNumber
    tap::_PowerdataNumber
    shift::_PowerdataNumber
    in_service::Bool
    angmin::_PowerdataNumber
    angmax::_PowerdataNumber
end

struct _PowerdataStorageInput <: _PowerdataInputRecord
    bus::Int64
    ps::_PowerdataNumber
    qs::_PowerdataNumber
    energy::_PowerdataNumber
    energy_rating::_PowerdataNumber
    charge_rating::_PowerdataNumber
    discharge_rating::_PowerdataNumber
    charge_efficiency::_PowerdataNumber
    discharge_efficiency::_PowerdataNumber
    thermal_rating::_PowerdataNumber
    qmin::_PowerdataNumber
    qmax::_PowerdataNumber
    r::_PowerdataNumber
    x::_PowerdataNumber
    p_loss::_PowerdataNumber
    q_loss::_PowerdataNumber
    in_service::Bool
end

struct _PowerdataInput <: _PowerdataInputRecord
    base_mva::_PowerdataNumber
    source_format::String
    buses::Vector{_PowerdataBusInput}
    loads::Vector{_PowerdataLoadInput}
    shunts::Vector{_PowerdataShuntInput}
    generators::Vector{_PowerdataGeneratorInput}
    branches::Vector{_PowerdataBranchInput}
    storage::Vector{_PowerdataStorageInput}
end

JSON3.StructTypes.StructType(::Type{T}) where {T<:_PowerdataInputRecord} =
    JSON3.StructTypes.Struct()

function _powerdata_skip_json(buf::AbstractVector{UInt8}, pos::Int,
                              len::Int, b::UInt8)
    if b == UInt8('"')
        pos += 1
        while pos <= len
            byte = @inbounds buf[pos]
            if byte == UInt8('\\')
                pos += 2
            elseif byte == UInt8('"')
                return pos + 1
            else
                pos += 1
            end
        end
    elseif b == UInt8('{') || b == UInt8('[')
        depth = 1
        in_string = false
        pos += 1
        while pos <= len
            byte = @inbounds buf[pos]
            if in_string
                if byte == UInt8('\\')
                    pos += 2
                    continue
                elseif byte == UInt8('"')
                    in_string = false
                end
            elseif byte == UInt8('"')
                in_string = true
            elseif byte == UInt8('{') || byte == UInt8('[')
                depth += 1
            elseif byte == UInt8('}') || byte == UInt8(']')
                depth -= 1
                depth == 0 && return pos + 1
            end
            pos += 1
        end
    else
        while pos <= len
            byte = @inbounds buf[pos]
            (byte == UInt8(',') || byte == UInt8('}') || byte == UInt8(']') ||
             byte == UInt8(' ') || byte == UInt8('\t') || byte == UInt8('\n') ||
             byte == UInt8('\r')) && return pos
            pos += 1
        end
        return pos
    end
    throw(ArgumentError(
        "PowerIO.to_powerdata: unterminated additive field in model JSON"))
end

function _powerdata_read_bool(buf::AbstractVector{UInt8}, pos::Int,
                              len::Int, b::UInt8)
    if b == UInt8('t') && pos + 3 <= len &&
       @inbounds(buf[pos + 1] == UInt8('r') &&
                 buf[pos + 2] == UInt8('u') &&
                 buf[pos + 3] == UInt8('e'))
        return pos + 4, true
    elseif b == UInt8('f') && pos + 4 <= len &&
           @inbounds(buf[pos + 1] == UInt8('a') &&
                     buf[pos + 2] == UInt8('l') &&
                     buf[pos + 3] == UInt8('s') &&
                     buf[pos + 4] == UInt8('e'))
        return pos + 5, false
    end
    throw(ArgumentError(
        "PowerIO.to_powerdata: invalid Boolean in model JSON at byte position $pos"))
end

function _powerdata_skip_whitespace(buf::AbstractVector{UInt8}, pos::Int,
                                    len::Int)
    while pos <= len
        byte = @inbounds buf[pos]
        (byte == UInt8(' ') || byte == UInt8('\t') || byte == UInt8('\n') ||
         byte == UInt8('\r')) || break
        pos += 1
    end
    return pos
end

function _powerdata_read_string(buf::AbstractVector{UInt8}, pos::Int,
                                len::Int, b::UInt8)
    b == UInt8('"') || throw(ArgumentError(
        "PowerIO.to_powerdata: expected a string in model JSON at byte position $pos"))
    first_byte = pos + 1
    pos = first_byte
    while pos <= len
        byte = @inbounds buf[pos]
        byte == UInt8('\\') && throw(ArgumentError(
            "PowerIO.to_powerdata: escaped bridge string in model JSON at byte position $pos"))
        if byte == UInt8('"')
            return pos + 1, String(buf[first_byte:(pos - 1)])
        end
        pos += 1
    end
    throw(ArgumentError(
        "PowerIO.to_powerdata: unterminated string in model JSON"))
end

function _powerdata_number_end(buf::AbstractVector{UInt8}, pos::Int, len::Int)
    while pos <= len
        byte = @inbounds buf[pos]
        (byte == UInt8(',') || byte == UInt8('}') || byte == UInt8(']') ||
         byte == UInt8(' ') || byte == UInt8('\t') || byte == UInt8('\n') ||
         byte == UInt8('\r')) && return pos
        pos += 1
    end
    return pos
end

function _powerdata_read_number(buf::AbstractVector{UInt8}, pos::Int,
                                len::Int, b::UInt8)
    b == UInt8('"') && return _powerdata_read_string(buf, pos, len, b)
    stop = _powerdata_number_end(buf, pos, len)
    value = tryparse(Float64, String(buf[pos:(stop - 1)]))
    value === nothing && throw(ArgumentError(
        "PowerIO.to_powerdata: invalid number in model JSON at byte position $pos"))
    return stop, value
end

function _powerdata_read_int(buf::AbstractVector{UInt8}, pos::Int,
                             len::Int, ::UInt8)
    stop = _powerdata_number_end(buf, pos, len)
    value = tryparse(Int64, String(buf[pos:(stop - 1)]))
    value === nothing && throw(ArgumentError(
        "PowerIO.to_powerdata: invalid integer in model JSON at byte position $pos"))
    return stop, value
end

function _powerdata_read_numbers(buf::AbstractVector{UInt8}, pos::Int,
                                 len::Int, b::UInt8)
    b == UInt8('[') || throw(ArgumentError(
        "PowerIO.to_powerdata: expected a numeric array in model JSON at byte position $pos"))
    values = Vector{_PowerdataNumber}()
    pos = _powerdata_skip_whitespace(buf, pos + 1, len)
    pos <= len || throw(ArgumentError(
        "PowerIO.to_powerdata: unterminated numeric array in model JSON"))
    @inbounds(buf[pos]) == UInt8(']') && return pos + 1, values
    while true
        pos, value = _powerdata_read_number(buf, pos, len, @inbounds(buf[pos]))
        push!(values, value)
        pos = _powerdata_skip_whitespace(buf, pos, len)
        pos <= len || throw(ArgumentError(
            "PowerIO.to_powerdata: unterminated numeric array in model JSON"))
        byte = @inbounds buf[pos]
        byte == UInt8(']') && return pos + 1, values
        byte == UInt8(',') || throw(ArgumentError(
            "PowerIO.to_powerdata: expected a comma in numeric JSON array at byte position $pos"))
        pos = _powerdata_skip_whitespace(buf, pos + 1, len)
        pos <= len || throw(ArgumentError(
            "PowerIO.to_powerdata: unterminated numeric array in model JSON"))
    end
end

function _powerdata_read_cost(buf::AbstractVector{UInt8}, pos::Int,
                              len::Int, b::UInt8)
    if b == UInt8('n') && pos + 3 <= len &&
       @inbounds(buf[pos + 1] == UInt8('u') &&
                 buf[pos + 2] == UInt8('l') &&
                 buf[pos + 3] == UInt8('l'))
        return pos + 4, nothing
    end
    return JSON3.read(JSON3.StructType(_PowerdataCostInput), buf, pos, len, b,
                      _PowerdataCostInput)
end

# JSON3's unordered-struct reader delegates each key to
# `StructTypes.applyfield(f, T, key)`. The generic implementation discovers a
# field type in a run time loop, which leaves the reader closure's `TT`
# argument abstract under trim verification even though this schema is closed.
# Generate the key dispatch and concrete reader call for these private records.
# Unknown and newly added model fields are scanned past without decoding, so
# the bridge remains additive without pulling JSON3's schema-free `Any` reader
# into the ahead of time call graph.
macro _define_powerdata_reader(record)
    return esc(quote
        @generated function JSON3.StructTypes.applyfield(
                f, ::Type{$record}, nm::Symbol)
            reads = map(1:fieldcount($record)) do i
                name = QuoteNode(fieldname($record, i))
                concrete_type = fieldtype($record, i)
                field_type = QuoteNode(concrete_type)
                read_value = if concrete_type === Bool
                    :(_powerdata_read_bool(f.buf, f.pos, f.len, f.b))
                elseif concrete_type === String
                    :(_powerdata_read_string(f.buf, f.pos, f.len, f.b))
                elseif concrete_type === Int64
                    :(_powerdata_read_int(f.buf, f.pos, f.len, f.b))
                elseif concrete_type === _PowerdataNumber
                    :(_powerdata_read_number(f.buf, f.pos, f.len, f.b))
                elseif concrete_type === Vector{_PowerdataNumber}
                    :(_powerdata_read_numbers(f.buf, f.pos, f.len, f.b))
                elseif concrete_type === Union{Nothing,_PowerdataCostInput}
                    :(_powerdata_read_cost(f.buf, f.pos, f.len, f.b))
                else
                    :(JSON3.read(JSON3.StructType($field_type), f.buf, f.pos,
                                 f.len, f.b, $field_type))
                end
                quote
                    if nm === $name
                        pos_i, value_i = $read_value
                        f.pos = pos_i
                        f.values[$i] = value_i
                        return true
                    end
                end
            end
            return quote
                $(reads...)
                f.pos = _powerdata_skip_json(f.buf, f.pos, f.len, f.b)
                return true
            end
        end
    end)
end

@_define_powerdata_reader _PowerdataCostInput
@_define_powerdata_reader _PowerdataBusInput
@_define_powerdata_reader _PowerdataLoadInput
@_define_powerdata_reader _PowerdataShuntInput
@_define_powerdata_reader _PowerdataGeneratorInput
@_define_powerdata_reader _PowerdataBranchInput
@_define_powerdata_reader _PowerdataStorageInput
@_define_powerdata_reader _PowerdataInput

# JSON3's generic invalid-input renderer prints an abstract `Type` value. Keep
# the bridge's parse failure directed without adding that open show dispatch to
# a trimmed call graph.
@noinline JSON3.invalid(::JSON3.Error, ::AbstractVector{UInt8}, pos::Int,
                        ::Type{T}) where {T<:_PowerdataInputRecord} =
    throw(ArgumentError(
        "PowerIO.to_powerdata: invalid model JSON at byte position $pos"))
@noinline JSON3.invalid(::JSON3.Error, ::AbstractVector{UInt8}, pos::Int,
                        ::Type{Vector{T}}) where {T<:_PowerdataInputRecord} =
    throw(ArgumentError(
        "PowerIO.to_powerdata: invalid model JSON array at byte position $pos"))

# StructTypes' generic constructor keeps parsed fields in `Vector{Any}` and
# then recovers their types with a run time loop. Unroll that last step for the
# closed bridge schema so trim verification sees every constructor target.
@generated function JSON3.StructTypes.construct(values::Vector{Any},
                                                 ::Type{T}) where {T<:_PowerdataInputRecord}
    checks = map(1:fieldcount(T)) do i
        field = fieldname(T, i)
        message = "PowerIO.to_powerdata: model JSON is missing required field `$(field)`"
        :(isassigned(values, $i) || throw(ArgumentError($message)))
    end
    args = [:(values[$i]::$(fieldtype(T, i))) for i in 1:fieldcount(T)]
    return quote
        $(checks...)
        T($(args...))
    end
end

_powerdata_input(net::BalancedNetwork) = JSON3.parse(to_json(net), _PowerdataInput)
_powerdata_input(h::BalancedNetworkHandle) = JSON3.parse(_to_json(h), _PowerdataInput)

# The live-only path is a separate call graph for ahead of time consumers. A
# `BalancedNetwork` is mutable and does not encode handle state in its type, so
# mixing the data fallback into this function makes both branches reachable to
# Julia's trim verifier even when the caller has just parsed a live network.
function _normalized_powerdata_input_live(net::BalancedNetwork)
    h = _live_handle(net, "to_powerdata")
    format = _handle_string(net, :pio_source_format)
    if format === nothing
        # ABI-compatible development builds can predate this additive scalar
        # accessor. Keep their behavior without making every current call parse
        # the full source document just to inspect one string.
        input = _powerdata_input(h)
        _source_format_token(input.source_format) == "normalized" && return input
    elseif format == "normalized"
        return _powerdata_input(h)
    end
    norm = to_normalized(net)
    normalized_handle = _live_handle(norm, "to_powerdata")
    seen = Set{SubString{String}}()
    for line in _handle_warnings(normalized_handle)
        code = first(split(line, ": "; limit=2))
        code in seen && continue
        push!(seen, code)
        @warn line
    end
    return _powerdata_input(normalized_handle)
end

function _normalized_powerdata_input(net::BalancedNetwork)
    if _maybe_live_handle(net) === nothing
        input = _powerdata_input(net)
        _source_format_token(input.source_format) == "normalized" && return input
    end
    return _normalized_powerdata_input_live(net)
end

_to_powerdata_normalized(net::BalancedNetwork, ::Type{T}) where {T<:Real} =
    _to_powerdata_normalized_input(_normalized_powerdata_input(net), T)

_to_powerdata_normalized_live(net::BalancedNetwork, ::Type{T}) where {T<:Real} =
    _to_powerdata_normalized_input(_normalized_powerdata_input_live(net), T)

function _to_powerdata_normalized_input(input::_PowerdataInput,
                                        ::Type{T}) where {T<:Real}
    base = _powerdata_real(input.base_mva, T, "network", :base_mva)
    raw_buses = input.buses
    kept_ids = [Int(b.id) for b in raw_buses]
    id_to_idx = Dict(id => i for (i, id) in enumerate(kept_ids))

    pd = zeros(T, length(kept_ids))
    qd = zeros(T, length(kept_ids))
    for (row, l) in enumerate(input.loads)
        idx = get(id_to_idx, Int(l.bus), 0)
        idx == 0 && continue
        pd[idx] += _powerdata_real(l.p, T, "load $row", :p)
        qd[idx] += _powerdata_real(l.q, T, "load $row", :q)
    end
    gs = zeros(T, length(kept_ids))
    bs = zeros(T, length(kept_ids))
    for (row, s) in enumerate(input.shunts)
        idx = get(id_to_idx, Int(s.bus), 0)
        idx == 0 && continue
        gs[idx] += _powerdata_real(s.g, T, "shunt $row", :g)
        bs[idx] += _powerdata_real(s.b, T, "shunt $row", :b)
    end

    BusRow = _powerdata_bus_row_type(T)
    bus_rows = BusRow[
        let id = Int(b.id)
            BusRow((;
                i,
                bus_i = id,
                type = bus_type_code(String(b.kind)),
                pd = pd[i],
                qd = qd[i],
                gs = gs[i],
                bs = bs[i],
                area = Int(b.area),
                vm = _powerdata_real(b.vm, T, "bus $id", :vm),
                va = _powerdata_real(b.va, T, "bus $id", :va),
                baseKV = _powerdata_real(b.base_kv, T, "bus $id", :base_kv),
                zone = Int(b.zone),
                vmax = _powerdata_real(b.vmax, T, "bus $id", :vmax),
                vmin = _powerdata_real(b.vmin, T, "bus $id", :vmin),
            ))
        end
        for (i, b) in enumerate(raw_buses)
    ]

    kept_gens = [g for g in input.generators if get(id_to_idx, Int(g.bus), 0) != 0]
    GenRow = _powerdata_gen_row_type(T)
    gen_rows = GenRow[
        let (model_poly, startup, shutdown, ncost, c) =
                _cost_tuple(g, T, base; normalized=true)
            GenRow((;
                i,
                bus = id_to_idx[Int(g.bus)],
                pg = _powerdata_real(g.pg, T, "generator $i", :pg),
                qg = _powerdata_real(g.qg, T, "generator $i", :qg),
                qmax = _powerdata_bound(g.qmax, T, "generator $i", :qmax),
                qmin = _powerdata_bound(g.qmin, T, "generator $i", :qmin),
                vg = _powerdata_real(g.vg, T, "generator $i", :vg),
                mbase = _powerdata_real(g.mbase, T, "generator $i", :mbase),
                status = Int(g.in_service),
                pmax = _powerdata_bound(g.pmax, T, "generator $i", :pmax),
                pmin = _powerdata_bound(g.pmin, T, "generator $i", :pmin),
                model_poly,
                startup,
                shutdown,
                n = ncost,
                c,
            ))
        end
        for (i, g) in enumerate(kept_gens)
    ]

    kept_branches = [br for br in input.branches
                     if get(id_to_idx, Int(br.from), 0) != 0 &&
                        get(id_to_idx, Int(br.to), 0) != 0]
    m = length(kept_branches)
    BranchRow = _powerdata_branch_row_type(T)
    branch_rows = BranchRow[
        let
            label = "branch $i"
            f = id_to_idx[Int(br.from)]
            t = id_to_idx[Int(br.to)]
            tap_raw = _powerdata_real(br.tap, T, label, :tap)
            tap = isapprox(tap_raw, zero(T)) ? one(T) : tap_raw
            shift = _powerdata_real(br.shift, T, label, :shift)
            b = _powerdata_real(br.b, T, label, :b)
            b_fr = b / T(2)
            b_to = b / T(2)
            g_fr = zero(T)
            g_to = zero(T)
            r = _powerdata_real(br.r, T, label, :br_r)
            x = _powerdata_real(br.x, T, label, :br_x)
            c1, c2, c3, c4, c5, c6, c7, c8 =
                _branch_coeffs(r, x, b_fr, b_to, g_fr, g_to, tap, shift)
            BranchRow((;
                i,
                f_bus = f,
                t_bus = t,
                br_r = r,
                br_x = x,
                b_fr,
                b_to,
                g_fr,
                g_to,
                rate_a = _powerdata_bound(br.rate_a, T, label, :rate_a),
                rate_b = _powerdata_bound(br.rate_b, T, label, :rate_b),
                rate_c = _powerdata_bound(br.rate_c, T, label, :rate_c),
                tap,
                shift,
                status = Int(br.in_service),
                angmin = _powerdata_bound(br.angmin, T, label, :angmin),
                angmax = _powerdata_bound(br.angmax, T, label, :angmax),
                f_idx = i,
                t_idx = i + m,
                c1, c2, c3, c4, c5, c6, c7, c8,
            ))
        end
        for (i, br) in enumerate(kept_branches)
    ]
    ArcRow = _powerdata_arc_row_type(T)
    arc_rows = vcat(
        ArcRow[ArcRow((; i, bus = br.f_bus, rate_a = br.rate_a)) for (i, br) in enumerate(branch_rows)],
        ArcRow[ArcRow((; i = i + m, bus = br.t_bus, rate_a = br.rate_a)) for (i, br) in enumerate(branch_rows)],
    )

    StorageRow = _powerdata_storage_row_type(T)
    storage_rows = StorageRow[StorageRow((;
        i = row,
        storage_bus = Int(st.bus),
        Pexts = _powerdata_real(st.ps, T, "storage $row", :ps),
        Qexts = _powerdata_real(st.qs, T, "storage $row", :qs),
        energy = _powerdata_real(st.energy, T, "storage $row", :energy),
        energy_rating = _powerdata_bound(st.energy_rating, T, "storage $row", :energy_rating),
        charge_rating = _powerdata_bound(st.charge_rating, T, "storage $row", :charge_rating),
        discharge_rating = _powerdata_bound(st.discharge_rating, T, "storage $row", :discharge_rating),
        charge_efficiency = _powerdata_real(st.charge_efficiency, T, "storage $row", :charge_efficiency),
        discharge_efficiency = _powerdata_real(st.discharge_efficiency, T, "storage $row", :discharge_efficiency),
        thermal_rating = _powerdata_bound(st.thermal_rating, T, "storage $row", :thermal_rating),
        qmin = _powerdata_bound(st.qmin, T, "storage $row", :qmin),
        qmax = _powerdata_bound(st.qmax, T, "storage $row", :qmax),
        Zr = _powerdata_real(st.r, T, "storage $row", :r),
        Zim = _powerdata_real(st.x, T, "storage $row", :x),
        p_loss = _powerdata_real(st.p_loss, T, "storage $row", :p_loss),
        q_loss = _powerdata_real(st.q_loss, T, "storage $row", :q_loss),
        status = Int(st.in_service),
    )) for (row, st) in enumerate(input.storage)]

    return (;
        version = "2",
        baseMVA = base,
        bus = bus_rows,
        gen = gen_rows,
        branch = branch_rows,
        arc = arc_rows,
        storage = storage_rows,
    )
end

struct _DefaultPowerdataFilter end
const _DEFAULT_POWERDATA_FILTER = _DefaultPowerdataFilter()

_powerdata_filter(::Type{T}, ::_DefaultPowerdataFilter) where {T<:Real} = Val(true)
_powerdata_filter(::Type{T}, filtered::Bool) where {T<:Real} = Val(filtered)

"""
    to_powerdata(net; filtered=true, T=Float64) -> NamedTuple
    to_powerdata(path; from=nothing, filtered=true, T=Float64) -> NamedTuple

Return a NamedTuple in ExaPowerIO's `PowerData` layout: `version`, `baseMVA`, `bus`,
`gen`, `branch`, `arc`, and `storage`. Rows use the field names ExaModelsPower
reads. With the default `filtered=true`, values are derived from
[`to_normalized`](@ref): `bus_i` preserves the source bus id, powers are per unit,
branch angle fields are radians, and branch/generator bus references are indices
into the bus vector.

With `filtered=true` the normalize pass runs inside this call, so its findings are
re-emitted as `@warn`, one per distinct diagnostic code. A case with no generator
cost data warns `CANONICALIZE.NORMALIZE.GEN_COST_ABSENT`: the rows build, and any
cost objective built from them is identically zero. Read them off the network
itself with [`warnings`](@ref)`(`[`to_normalized`](@ref)`(net))`.

A field reads as finite unless it is a bound a source format spells as
unlimited. `±Inf` passes on the generator and storage reactive and active
limits, the branch ratings, and the angle-difference bounds — an absent
reactive limit is `Inf` in MATPOWER, PowerModels, pandapower and PyPSA, and
stock case9241pegase.m carries it on seven generators. Everywhere else an
infinite value is refused with the element and the field named, including
`br_r`, `br_x`, `b`, `tap`, `shift`, `vm`, `va`, `base_kv`, `vmin`, `vmax`,
`pg`, `qg`, `mbase` and the cost coefficients: no format spells "no voltage
limit" or "no reactance" as `Inf`, so it is a data defect rather than a
convention, and an infinite `br_x` otherwise reached `_branch_coeffs` and put
admittance coefficients derived from `1/Inf` in the returned row. A `NaN` is
refused everywhere, as before.

This is an ExaModels-facing bridge (a Julia sibling of [`to_powermodels`](@ref)):
the returned row schema is the field set ExaModelsPower's model builders read. It is
not a general PowerIO representation and does not port to the Rust core / C ABI; for
general numeric access use [`to_dense`](@ref) or [`to_arrow`](@ref).

An ahead of time caller that has just parsed `net` can pass a final
`Val(:live)` argument. That method requires a live Rust handle and keeps the
handle-only call graph separate from the data-backed compatibility path.
"""
to_powerdata(net::BalancedNetwork;
             filtered::Union{Bool,_DefaultPowerdataFilter}=_DEFAULT_POWERDATA_FILTER,
             T::Type{<:Real}=Float64) =
    to_powerdata(net, T; filtered=filtered)

_to_powerdata(net::BalancedNetwork, ::Type{T}, ::Val{true}) where {T<:Real} =
    _to_powerdata_normalized(net, T)

_to_powerdata(net::BalancedNetwork, ::Type{T}, ::Val{false}) where {T<:Real} =
    _to_powerdata_raw_input(_powerdata_input(net), T)

_to_powerdata_live(net::BalancedNetwork, ::Type{T}, ::Val{true}) where {T<:Real} =
    _to_powerdata_normalized_live(net, T)

_to_powerdata_live(net::BalancedNetwork, ::Type{T}, ::Val{false}) where {T<:Real} =
    _to_powerdata_raw_input(_powerdata_input(_live_handle(net, "to_powerdata")), T)

function _to_powerdata_raw_input(input::_PowerdataInput,
                                 ::Type{T}) where {T<:Real}
    base = _json_float(T, input.base_mva)
    raw_buses = input.buses
    kept_ids = [Int(b.id) for b in raw_buses]
    id_to_idx = Dict(id => i for (i, id) in enumerate(kept_ids))

    pd = zeros(T, length(kept_ids))
    qd = zeros(T, length(kept_ids))
    for l in input.loads
        idx = get(id_to_idx, Int(l.bus), 0)
        idx == 0 && continue
        pd[idx] += _json_float(T, l.p) / base
        qd[idx] += _json_float(T, l.q) / base
    end
    gs = zeros(T, length(kept_ids))
    bs = zeros(T, length(kept_ids))
    for s in input.shunts
        idx = get(id_to_idx, Int(s.bus), 0)
        idx == 0 && continue
        gs[idx] += _json_float(T, s.g) / base
        bs[idx] += _json_float(T, s.b) / base
    end

    BusRow = _powerdata_bus_row_type(T)
    bus_rows = BusRow[
        let id = Int(b.id), i = id_to_idx[id]
            BusRow((;
                i,
                bus_i = id,
                type = bus_type_code(String(b.kind)),
                pd = pd[i],
                qd = qd[i],
                gs = gs[i],
                bs = bs[i],
                area = Int(b.area),
                vm = _json_float(T, b.vm),
                va = _json_float(T, b.va),
                baseKV = _json_float(T, b.base_kv),
                zone = Int(b.zone),
                vmax = _json_float(T, b.vmax),
                vmin = _json_float(T, b.vmin),
            ))
        end
        for b in raw_buses
    ]

    kept_gens = [g for g in input.generators if get(id_to_idx, Int(g.bus), 0) != 0]
    GenRow = _powerdata_gen_row_type(T)
    gen_rows = GenRow[
        let (model_poly, startup, shutdown, ncost, c) =
                _cost_tuple(g, T, base; normalized=false)
            GenRow((;
                i,
                bus = id_to_idx[Int(g.bus)],
                pg = _json_float(T, g.pg) / base,
                qg = _json_float(T, g.qg) / base,
                qmax = _json_float(T, g.qmax) / base,
                qmin = _json_float(T, g.qmin) / base,
                vg = _json_float(T, g.vg),
                mbase = _json_float(T, g.mbase),
                status = Int(Bool(g.in_service)),
                pmax = _json_float(T, g.pmax) / base,
                pmin = _json_float(T, g.pmin) / base,
                model_poly,
                startup,
                shutdown,
                n = ncost,
                c,
            ))
        end
        for (i, g) in enumerate(kept_gens)
    ]

    # In-service generators mark their bus and drive the slack fallback below.
    has_gen = falses(length(bus_rows))
    biggest_gen_bus = 0
    biggest_gen_pmax = typemin(T)
    for g in kept_gens
        Bool(g.in_service) || continue
        idx = id_to_idx[Int(g.bus)]
        has_gen[idx] = true
        pmax = _json_float(T, g.pmax) / base
        if pmax > biggest_gen_pmax
            biggest_gen_pmax = pmax
            biggest_gen_bus = idx
        end
    end

    for i in eachindex(bus_rows)
        typ = bus_rows[i].type
        if has_gen[i] && typ == 1
            bus_rows[i] = merge(bus_rows[i], (; type = 2))
        elseif !has_gen[i] && (typ == 2 || typ == 3)
            bus_rows[i] = merge(bus_rows[i], (; type = 1))
        end
    end
    if !any(row.type == 3 for row in bus_rows) && biggest_gen_bus > 0
        bus_rows[biggest_gen_bus] = merge(bus_rows[biggest_gen_bus], (; type = 3))
    end

    kept_branches = [br for br in input.branches
                     if get(id_to_idx, Int(br.from), 0) != 0 &&
                        get(id_to_idx, Int(br.to), 0) != 0]
    m = length(kept_branches)
    BranchRow = _powerdata_branch_row_type(T)
    branch_rows = BranchRow[
        let
            f = id_to_idx[Int(br.from)]
            t = id_to_idx[Int(br.to)]
            label = "branch $i"
            tap_raw = _powerdata_real(br.tap, T, label, :tap)
            tap = isapprox(tap_raw, zero(T)) ? one(T) : tap_raw
            shift = _powerdata_real(br.shift, T, label, :shift) / T(180) * T(pi)
            b = _powerdata_real(br.b, T, label, :b)
            b_fr = b / T(2)
            b_to = b / T(2)
            g_fr = zero(T)
            g_to = zero(T)
            r = _powerdata_real(br.r, T, label, :br_r)
            x = _powerdata_real(br.x, T, label, :br_x)
            c1, c2, c3, c4, c5, c6, c7, c8 =
                _branch_coeffs(r, x, b_fr, b_to, g_fr, g_to, tap, shift)
            BranchRow((;
                i,
                f_bus = f,
                t_bus = t,
                br_r = r,
                br_x = x,
                b_fr,
                b_to,
                g_fr,
                g_to,
                rate_a = _powerdata_bound(br.rate_a, T, label, :rate_a) / base,
                rate_b = _powerdata_bound(br.rate_b, T, label, :rate_b) / base,
                rate_c = _powerdata_bound(br.rate_c, T, label, :rate_c) / base,
                tap,
                shift,
                status = Int(Bool(br.in_service)),
                angmin = _powerdata_bound(br.angmin, T, label, :angmin) / T(180) * T(pi),
                angmax = _powerdata_bound(br.angmax, T, label, :angmax) / T(180) * T(pi),
                f_idx = i,
                t_idx = i + m,
                c1, c2, c3, c4, c5, c6, c7, c8,
            ))
        end
        for (i, br) in enumerate(kept_branches)
    ]
    ArcRow = _powerdata_arc_row_type(T)
    arc_rows = vcat(
        ArcRow[ArcRow((; i, bus = br.f_bus, rate_a = br.rate_a)) for (i, br) in enumerate(branch_rows)],
        ArcRow[ArcRow((; i = i + m, bus = br.t_bus, rate_a = br.rate_a)) for (i, br) in enumerate(branch_rows)],
    )

    StorageRow = _powerdata_storage_row_type(T)
    storage_rows = StorageRow[StorageRow((;
        i = row,
        storage_bus = Int(st.bus),
        Pexts = _json_float(T, st.ps),
        Qexts = _json_float(T, st.qs),
        energy = _json_float(T, st.energy) / base,
        energy_rating = _json_float(T, st.energy_rating) / base,
        charge_rating = _json_float(T, st.charge_rating) / base,
        discharge_rating = _json_float(T, st.discharge_rating) / base,
        charge_efficiency = _json_float(T, st.charge_efficiency),
        discharge_efficiency = _json_float(T, st.discharge_efficiency),
        thermal_rating = _json_float(T, st.thermal_rating) / base,
        qmin = _json_float(T, st.qmin) / base,
        qmax = _json_float(T, st.qmax) / base,
        Zr = _json_float(T, st.r),
        Zim = _json_float(T, st.x),
        p_loss = _json_float(T, st.p_loss),
        q_loss = _json_float(T, st.q_loss),
        status = Int(Bool(st.in_service)),
    )) for (row, st) in enumerate(input.storage)]

    return (;
        version = "2",
        baseMVA = base,
        bus = bus_rows,
        gen = gen_rows,
        branch = branch_rows,
        arc = arc_rows,
        storage = storage_rows,
    )
end

to_powerdata(net::BalancedNetwork, ::Type{T};
             filtered::Union{Bool,_DefaultPowerdataFilter}=_DEFAULT_POWERDATA_FILTER) where {T<:Real} =
    _to_powerdata(net, T, _powerdata_filter(T, filtered))

to_powerdata(net::BalancedNetwork, ::Type{T}, ::Val{:live};
             filtered::Union{Bool,_DefaultPowerdataFilter}=_DEFAULT_POWERDATA_FILTER) where {T<:Real} =
    _to_powerdata_live(net, T, _powerdata_filter(T, filtered))

to_powerdata(path::AbstractString; from=nothing,
             filtered::Union{Bool,_DefaultPowerdataFilter}=_DEFAULT_POWERDATA_FILTER,
             T::Type{<:Real}=Float64) =
    to_powerdata(path, T; from=from, filtered=filtered)

to_powerdata(path::AbstractString, ::Type{T}; from=nothing,
             filtered::Union{Bool,_DefaultPowerdataFilter}=_DEFAULT_POWERDATA_FILTER) where {T<:Real} =
    to_powerdata(parse_file(path; from=from), T; filtered=filtered)

to_powerdata(path::AbstractString, ::Type{T}, live::Val{:live}; from=nothing,
             filtered::Union{Bool,_DefaultPowerdataFilter}=_DEFAULT_POWERDATA_FILTER) where {T<:Real} =
    to_powerdata(parse_file(BalancedNetwork, path; from=from), T, live;
                 filtered=filtered)

"""
    parse_ac_power_data(input; from=nothing, filtered=true, T=Float64) -> NamedTuple

Return the NamedTuple layout consumed by ExaModelsPower's `build_polar_opf`,
`build_rect_opf`, and `build_dcopf`. `input` may be a [`BalancedNetwork`](@ref) or a path.
Emits the normalize findings as `@warn` the way [`to_powerdata`](@ref) does,
and reads each field under the same finiteness rule: `±Inf` on a bound a
source format spells as unlimited, refused everywhere else.
The final `Val(:live)` form is the handle-only spelling for ahead of time
callers; it requires either a live network or a path that parses as one.
"""
parse_ac_power_data(input; from=nothing,
                    filtered::Union{Bool,_DefaultPowerdataFilter}=_DEFAULT_POWERDATA_FILTER,
                    T::Type{<:Real}=Float64) =
    parse_ac_power_data(input, T; from=from, filtered=filtered)

function parse_ac_power_data(input, ::Type{T}; from=nothing,
                             filtered::Union{Bool,_DefaultPowerdataFilter}=_DEFAULT_POWERDATA_FILTER) where {T<:Real}
    pd = input isa BalancedNetwork ? to_powerdata(input, T; filtered=filtered) :
         to_powerdata(String(input), T; from=from, filtered=filtered)
    return _parse_ac_power_data_output(pd, T)
end

function parse_ac_power_data(net::BalancedNetwork, ::Type{T}, live::Val{:live};
                             from=nothing,
                             filtered::Union{Bool,_DefaultPowerdataFilter}=_DEFAULT_POWERDATA_FILTER) where {T<:Real}
    pd = to_powerdata(net, T, live; filtered=filtered)
    return _parse_ac_power_data_output(pd, T)
end

function parse_ac_power_data(path::AbstractString, ::Type{T}, live::Val{:live};
                             from=nothing,
                             filtered::Union{Bool,_DefaultPowerdataFilter}=_DEFAULT_POWERDATA_FILTER) where {T<:Real}
    net = parse_file(BalancedNetwork, path; from=from)
    return parse_ac_power_data(net, T, live; filtered=filtered)
end

function _parse_ac_power_data_output(pd, ::Type{T}) where {T<:Real}
    return (;
        baseMVA = [pd.baseMVA],
        bus = pd.bus,
        gen = pd.gen,
        arc = pd.arc,
        branch = pd.branch,
        storage = pd.storage,
        ref_buses = [i for i in 1:length(pd.bus) if pd.bus[i].type == 3],
        vmax = [b.vmax for b in pd.bus],
        vmin = [b.vmin for b in pd.bus],
        pmax = [g.pmax for g in pd.gen],
        pmin = [g.pmin for g in pd.gen],
        qmax = [g.qmax for g in pd.gen],
        qmin = [g.qmin for g in pd.gen],
        angmax = [br.angmax for br in pd.branch],
        angmin = [br.angmin for br in pd.branch],
        rate_a = [a.rate_a for a in pd.arc],
        vm0 = [b.vm for b in pd.bus],
        va0 = [b.va for b in pd.bus],
        pg0 = [g.pg for g in pd.gen],
        qg0 = [g.qg for g in pd.gen],
        pdmax = T[s.charge_rating for s in pd.storage],
        pcmax = T[s.discharge_rating for s in pd.storage],
        srating = T[s.thermal_rating for s in pd.storage],
        emax = T[s.energy_rating for s in pd.storage],
    )
end

# ---------------------------------------------------------------------------
# LoadSeries: dense per-period bus loads (multiperiod OPF convenience)
# ---------------------------------------------------------------------------

"""
    LoadSeries{T}

A dense per-bus time series of loads over a parsed network. `pd` and `qd` are
`n_buses` by `n_periods` matrices of active/reactive demand, per unit on `base_mva` and
ordered by the network's buses; `bus_ids[k]` is the source id of row `k`, so the
row-to-bus alignment is recorded rather than assumed. Read a period `t` off the matrices
directly (`series.pd[:, t]`); get the counts with [`n_periods`](@ref) / `n_buses`.

This is a focused convenience for ExaModelsPower's multiperiod OPF, which supplies dense
per-bus `.Pd`/`.Qd` load tables. PowerIO's general, format-neutral time series is the
`OperatingPointSeries` (the type of the same name in the powerio Rust core): a time axis
plus per-period sparse field updates over a base network, which represents more than
loads and stores only what changes each period. A later release binds that type (gated on
the construct/attach C ABI, eigenergy/powerio#236) and re-backs `LoadSeries` with it, but
`LoadSeries`'s surface — the `pd`/`qd` matrices, `bus_ids`, `base_mva`, and [`n_periods`](@ref) —
stays stable and is not hard removed, so no consumer change is required when that lands.

Build one from a load matrix, a per-period demand multiplier, an id-keyed load table, or
two whitespace-delimited files:

```julia
PowerIO.LoadSeries(net, pd_mw, qd_mw)          # rows = buses in network order, MW
PowerIO.LoadSeries(net, curve)                 # scale the base-case loads per period
PowerIO.LoadSeries(net, pd_by_id, qd_by_id)    # Dict(bus_id => per-period MW vector)
PowerIO.read_load_series(net, pd_path, qd_path) # same layout as the matrix form, from files
```

Ahead of time callers with a freshly parsed live network can append
`Val(:live)` after the positional element type. The ordinary methods retain
the data-backed compatibility path.
"""
struct LoadSeries{T}
    pd::Matrix{T}
    qd::Matrix{T}
    bus_ids::Vector{Int}
    base_mva::T
end

"""
    n_periods(series) -> Int

Number of periods in a [`LoadSeries`](@ref).
"""
n_periods(s::LoadSeries) = size(s.pd, 2)
n_buses(s::LoadSeries) = size(s.pd, 1)

"""
    demands_mw(series::LoadSeries) -> (; pd, qd)

The demand matrices rescaled to MW: `series.pd .* series.base_mva` and the
same for `qd`. `LoadSeries` stores per unit, and the matrix and file
constructors take MW, so this is the round trip back out for any interface
that works in MW. Pass these matrices, never the per-unit fields, wherever MW
is what is expected.
"""
demands_mw(s::LoadSeries) = (; pd = s.pd .* s.base_mva, qd = s.qd .* s.base_mva)

function Base.show(io::IO, s::LoadSeries{T}) where {T}
    print(io, "LoadSeries{$T}: ", n_buses(s), " buses, ", n_periods(s), " periods")
end

# Base loads (per unit), bus ids, and base MVA in the exact bus order
# parse_ac_power_data / mpopf use, so a series aligns to `data.bus` with no
# positional guessing. This walks the same normalized view `to_powerdata` walks
# but builds only the four values a series needs, not the whole row schema.
function _load_alignment(net::BalancedNetwork, ::Type{T}) where {T<:Real}
    return _load_alignment_input(_normalized_powerdata_input(net), T)
end

function _load_alignment_live(net::BalancedNetwork, ::Type{T}) where {T<:Real}
    return _load_alignment_input(_normalized_powerdata_input_live(net), T)
end

function _load_alignment_input(input::_PowerdataInput,
                               ::Type{T}) where {T<:Real}
    base = _powerdata_real(input.base_mva, T, "network", :base_mva)
    bus_ids = Int[Int(b.id) for b in input.buses]
    id_to_idx = Dict(id => i for (i, id) in enumerate(bus_ids))
    base_pd = zeros(T, length(bus_ids))
    base_qd = zeros(T, length(bus_ids))
    for (row, l) in enumerate(input.loads)
        idx = get(id_to_idx, Int(l.bus), 0)
        idx == 0 && continue
        base_pd[idx] += _powerdata_real(l.p, T, "load $row", :p)
        base_qd[idx] += _powerdata_real(l.q, T, "load $row", :q)
    end
    return base, bus_ids, base_pd, base_qd
end

function _check_load_matrix(pd_mw::AbstractMatrix, qd_mw::AbstractMatrix, nbus::Int)
    size(pd_mw) == size(qd_mw) ||
        throw(DimensionMismatch(
            "LoadSeries: Pd is $(size(pd_mw)) but Qd is $(size(qd_mw))"))
    size(pd_mw, 1) == nbus ||
        throw(DimensionMismatch(
            "LoadSeries: load matrix has $(size(pd_mw, 1)) rows but the network has " *
            "$nbus buses (rows must be buses in the network's order)"))
    return nothing
end

function _perunit(x_mw::AbstractMatrix, base::T) where {T<:Real}
    out = Matrix{T}(undef, size(x_mw))
    @inbounds for j in axes(x_mw, 2), i in axes(x_mw, 1)
        v = T(x_mw[i, j]) / base
        isfinite(v) ||
            throw(ArgumentError("LoadSeries: non-finite load at bus row $i, period $j"))
        out[i, j] = v
    end
    return out
end

"""
    LoadSeries(net::BalancedNetwork, pd_mw, qd_mw, ::Type{T})
    LoadSeries(net::BalancedNetwork, pd_mw, qd_mw; T=Float64)

Build a series from active/reactive load matrices in MW, `n_buses` by `n_periods`, whose
rows are the buses in `net`'s order. Values are converted to per unit on the network's
base MVA.
"""
function LoadSeries(net::BalancedNetwork, pd_mw::AbstractMatrix,
                    qd_mw::AbstractMatrix, ::Type{T}) where {T<:Real}
    return _load_series_matrices(_load_alignment(net, T), pd_mw, qd_mw, T)
end

function LoadSeries(net::BalancedNetwork, pd_mw::AbstractMatrix,
                    qd_mw::AbstractMatrix, ::Type{T},
                    ::Val{:live}) where {T<:Real}
    return _load_series_matrices(_load_alignment_live(net, T), pd_mw, qd_mw, T)
end

function _load_series_matrices(alignment, pd_mw::AbstractMatrix,
                               qd_mw::AbstractMatrix,
                               ::Type{T}) where {T<:Real}
    base, bus_ids, _, _ = alignment
    _check_load_matrix(pd_mw, qd_mw, length(bus_ids))
    LoadSeries{T}(_perunit(pd_mw, base), _perunit(qd_mw, base), bus_ids, base)
end

LoadSeries(net::BalancedNetwork, pd_mw::AbstractMatrix, qd_mw::AbstractMatrix;
           T::Type{<:Real}=Float64) = LoadSeries(net, pd_mw, qd_mw, T)

"""
    LoadSeries(net::BalancedNetwork, curve::AbstractVector, ::Type{T})
    LoadSeries(net::BalancedNetwork, curve::AbstractVector; T=Float64)

Build a series by scaling the base-case bus loads by `curve[t]` in each period `t`. Only
the loads are scaled; fixed bus shunts stay at their base value.
"""
function LoadSeries(net::BalancedNetwork, curve::AbstractVector,
                    ::Type{T}) where {T<:Real}
    return _load_series_curve(_load_alignment(net, T), curve, T)
end

function LoadSeries(net::BalancedNetwork, curve::AbstractVector,
                    ::Type{T}, ::Val{:live}) where {T<:Real}
    return _load_series_curve(_load_alignment_live(net, T), curve, T)
end

function _load_series_curve(alignment, curve::AbstractVector,
                            ::Type{T}) where {T<:Real}
    isempty(curve) &&
        throw(ArgumentError("LoadSeries: curve must have at least one period"))
    base, bus_ids, base_pd, base_qd = alignment
    c = T[T(x) for x in curve]
    all(isfinite, c) ||
        throw(ArgumentError("LoadSeries: curve has a non-finite multiplier"))
    pd = base_pd * transpose(c)
    qd = base_qd * transpose(c)
    LoadSeries{T}(pd, qd, bus_ids, base)
end

LoadSeries(net::BalancedNetwork, curve::AbstractVector;
           T::Type{<:Real}=Float64) = LoadSeries(net, curve, T)

"""
    LoadSeries(net::BalancedNetwork, pd_by_id::AbstractDict, qd_by_id::AbstractDict,
               ::Type{T})
    LoadSeries(net::BalancedNetwork, pd_by_id::AbstractDict, qd_by_id::AbstractDict; T=Float64)

Build a series from id-keyed load tables: each dict maps a source bus id to its per-period
MW vector. Every bus in `net` must have an entry and all vectors must share the same
length. This removes the positional row assumption of the matrix form.
"""
function LoadSeries(net::BalancedNetwork, pd_by_id::AbstractDict,
                    qd_by_id::AbstractDict, ::Type{T}) where {T<:Real}
    return _load_series_id_tables(_load_alignment(net, T), pd_by_id, qd_by_id, T)
end

function LoadSeries(net::BalancedNetwork, pd_by_id::AbstractDict,
                    qd_by_id::AbstractDict, ::Type{T},
                    ::Val{:live}) where {T<:Real}
    return _load_series_id_tables(_load_alignment_live(net, T),
                                  pd_by_id, qd_by_id, T)
end

function _load_series_id_tables(alignment, pd_by_id::AbstractDict,
                                qd_by_id::AbstractDict,
                                ::Type{T}) where {T<:Real}
    base, bus_ids, _, _ = alignment
    pd = _matrix_from_id_table(pd_by_id, bus_ids, :Pd, T)
    qd = _matrix_from_id_table(qd_by_id, bus_ids, :Qd, T)
    _check_load_matrix(pd, qd, length(bus_ids))
    LoadSeries{T}(_perunit(pd, base), _perunit(qd, base), bus_ids, base)
end

LoadSeries(net::BalancedNetwork, pd_by_id::AbstractDict, qd_by_id::AbstractDict;
           T::Type{<:Real}=Float64) = LoadSeries(net, pd_by_id, qd_by_id, T)

# Build the load matrix at the caller's precision `T` directly, so the GPU-facing
# `T=Float32` path does not allocate a Float64 matrix here only for `_perunit` to
# reallocate and convert it.
function _matrix_from_id_table(by_id::AbstractDict, bus_ids::Vector{Int}, which::Symbol,
                               ::Type{T}) where {T<:Real}
    isempty(bus_ids) &&
        throw(ArgumentError(
            "LoadSeries: cannot build $which from an id table for a network with no buses"))
    nper = -1
    for id in bus_ids
        haskey(by_id, id) ||
            throw(ArgumentError("LoadSeries: $which has no entry for bus $id"))
        len = length(by_id[id])
        nper == -1 && (nper = len)
        len == nper ||
            throw(DimensionMismatch(
                "LoadSeries: $which vectors have unequal lengths ($nper vs $len)"))
    end
    out = Matrix{T}(undef, length(bus_ids), nper)
    for (k, id) in enumerate(bus_ids)
        out[k, :] .= by_id[id]
    end
    return out
end

"""
    read_load_series(net::BalancedNetwork, pd_path, qd_path, ::Type{T})
    read_load_series(net::BalancedNetwork, pd_path, qd_path; T=Float64)

Read two whitespace-delimited MW load matrices (rows = buses in `net`'s order, columns =
periods) and build a [`LoadSeries`](@ref). Reads the same `.Pd` / `.Qd` files a raw
`readdlm` would, but dimension-checked, bus-aligned, and **converted to per unit**.

!!! warning "Units"
    The files hold **MW**. A `LoadSeries` holds **per unit**. Reading `series.pd`
    and handing it to something that expects MW is off by `baseMVA` with no
    error; [`demands_mw`](@ref) is the conversion back out.

    ```julia
    series = read_load_series(net, "case5.Pd", "case5.Qd")
    series.pd              # per unit
    demands_mw(series).pd  # MW
    ```
"""
function read_load_series(net::BalancedNetwork, pd_path::AbstractString,
                          qd_path::AbstractString, ::Type{T}) where {T<:Real}
    pd_mw = _read_load_file(pd_path)
    qd_mw = _read_load_file(qd_path)
    LoadSeries(net, pd_mw, qd_mw, T)
end

function read_load_series(net::BalancedNetwork, pd_path::AbstractString,
                          qd_path::AbstractString, ::Type{T},
                          live::Val{:live}) where {T<:Real}
    pd_mw = _read_load_file(pd_path)
    qd_mw = _read_load_file(qd_path)
    LoadSeries(net, pd_mw, qd_mw, T, live)
end

read_load_series(net::BalancedNetwork, pd_path::AbstractString,
                 qd_path::AbstractString; T::Type{<:Real}=Float64) =
    read_load_series(net, pd_path, qd_path, T)

function _read_load_file(path::AbstractString)
    isfile(path) ||
        throw(ArgumentError("LoadSeries: load file not found: $path"))
    rows = Vector{Vector{Float64}}()
    ncol = -1
    for (lineno, line) in enumerate(eachline(path))
        fields = split(line)
        isempty(fields) && continue
        vals = Float64[parse(Float64, f) for f in fields]
        ncol == -1 && (ncol = length(vals))
        length(vals) == ncol ||
            throw(DimensionMismatch(
                "LoadSeries: $path row $lineno has $(length(vals)) values, " *
                "expected $ncol"))
        push!(rows, vals)
    end
    isempty(rows) &&
        throw(ArgumentError("LoadSeries: $path has no load rows"))
    return permutedims(reduce(hcat, rows))
end
