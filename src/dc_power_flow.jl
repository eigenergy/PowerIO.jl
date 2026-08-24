# DC power flow vectors over the C ABI. Rust builds the incidence data once;
# the bulk call fills the Julia arrays directly.

"""
    dc_power_flow_available() -> Bool

Return `true` when the resolved C library exports the DC power flow data
functions. Constructing [`DcPowerFlowData`](@ref) also needs the `arrow`
feature for its incidence matrix.
"""
dc_power_flow_available() =
    all(_exports_symbol, (:pio_dc_power_flow_data, :pio_branch_susceptance,
                          :pio_phase_shift_injection,
                          :pio_incidence_branch_rows, :pio_incidence_skipped_rows))

const _DC_CONVENTIONS = Dict("series" => "series",
                             "seriesimpedance" => "series",
                             "matpower" => "matpower",
                             "mp" => "matpower",
                             "reactanceonly" => "reactance-only")

const _DC_CONVENTION_RETIRED = ("paper", "paperpure", "pure")

function _dc_convention_token(convention)
    convention isa Union{Symbol,AbstractString} || throw(ArgumentError(
        "PowerIO: a DC convention is named by a Symbol or a String, got " *
        "$(repr(convention)); expected :series, :matpower or :reactance_only"))
    key = _canonical_token_key(convention)
    key in _DC_CONVENTION_RETIRED && throw(ArgumentError(
        "PowerIO: convention 'paper-pure' is now :reactance_only; it is no longer " *
        "the default, and :series uses b = imag(inv(r + im*x))"))
    token = get(_DC_CONVENTIONS, key, nothing)
    token === nothing && throw(ArgumentError(
        "PowerIO: unknown DC convention $(repr(convention)); expected " *
        ":series (b = imag(inv(r + im*x))), :matpower (b = -1/(x*tap)), " *
        "or :reactance_only (b = -1/x)"))
    return token
end

_dc_convention_symbol(token::AbstractString) =
    token == "reactance-only" ? :reactance_only : Symbol(token)

function _dc_vector_call(net::BalancedNetwork, fname::AbstractString, sym::Symbol,
                         ::Type{E}, token::AbstractString, out, cap::Integer) where {E}
    h = _live_handle(net, fname)
    lib = getfield(h, :lib)
    _ensure_compatible(lib)
    _require_export(fname, sym, "powerio v0.9, `--features matrix`", lib)
    err = zeros(UInt8, _ERRLEN)
    n = GC.@preserve h ccall(_library_symbol(lib, sym), Cptrdiff_t,
                             (Ptr{Cvoid}, Cstring, Ptr{E}, Csize_t, Ptr{UInt8}, Csize_t),
                             h.ptr, token, out, cap, err, length(err))
    n < 0 && error("PowerIO.$fname: " * _cstr(err))
    return Int(n)
end

function _dc_vector_fill(net::BalancedNetwork, fname::AbstractString, sym::Symbol,
                         ::Type{E}, token::AbstractString) where {E}
    n = _dc_vector_call(net, fname, sym, E, token, Ptr{E}(C_NULL), 0)
    out = Vector{E}(undef, n)
    got = _dc_vector_call(net, fname, sym, E, token, out, length(out))
    _check_filled(got, n, string(sym))
    return out
end

function _dc_power_flow_fill(net::BalancedNetwork, token::AbstractString, m::Int, n::Int)
    h = _live_handle(net, "DcPowerFlowData")
    lib = getfield(h, :lib)
    _ensure_compatible(lib)
    _require_export("DcPowerFlowData", :pio_dc_power_flow_data,
                    "powerio v0.9, `--features matrix`", lib)
    nb = Int(GC.@preserve h ccall(_library_symbol(lib, :pio_n_branches), Csize_t,
                                  (Ptr{Cvoid},), h.ptr))
    b = Vector{Float64}(undef, m)
    rows = Vector{Int64}(undef, m)
    p_shift = Vector{Float64}(undef, n)
    skipped = Vector{Int64}(undef, nb)
    out_m, out_n, out_skipped = Ref{Csize_t}(0), Ref{Csize_t}(0), Ref{Csize_t}(0)
    err = zeros(UInt8, _ERRLEN)
    status = GC.@preserve h ccall(
        _library_symbol(lib, :pio_dc_power_flow_data), Cint,
        (Ptr{Cvoid}, Cstring, Ptr{Float64}, Ptr{Int64}, Csize_t,
         Ptr{Float64}, Csize_t, Ptr{Int64}, Csize_t,
         Ref{Csize_t}, Ref{Csize_t}, Ref{Csize_t}, Ptr{UInt8}, Csize_t),
        h.ptr, token, b, rows, m, p_shift, n, skipped, nb,
        out_m, out_n, out_skipped, err, length(err))
    status == 0 || error("PowerIO.DcPowerFlowData: " * _cstr(err))

    got_m, got_n, got_skipped = Int(out_m[]), Int(out_n[]), Int(out_skipped[])
    got_m == m || error(
        "PowerIO.DcPowerFlowData: incidence matrix has $m branch rows but the C ABI reported $got_m")
    got_n == n || error(
        "PowerIO.DcPowerFlowData: incidence matrix has $n bus columns but the C ABI reported $got_n")
    got_skipped <= nb || error(
        "PowerIO.DcPowerFlowData: case has $nb branches but the C ABI reported $got_skipped skipped rows")
    resize!(skipped, got_skipped)
    return b, p_shift, rows, skipped
end

function _one_based_rows(v::Vector{Int64})
    if Int === Int64
        for i in eachindex(v)
            v[i] == typemax(Int64) && error("PowerIO: branch row does not fit in Int")
            v[i] += 1
        end
        return v
    end
    return Int[Int(x) + 1 for x in v]
end

function _dc_incidence_arrow(net::BalancedNetwork, convention, token::AbstractString)
    try
        return _incidence_arrow(net, "DcPowerFlowData")
    catch err
        token == "series" && rethrow()
        _dc_vector_call(net, "DcPowerFlowData", :pio_branch_susceptance,
                        Float64, token, Ptr{Float64}(C_NULL), 0)
        error("PowerIO.DcPowerFlowData: the Arrow incidence table uses :series and " *
              "cannot represent this case under :$(convention): " * sprint(showerror, err))
    end
end

"""
    DcPowerFlowData(net::BalancedNetwork; convention=:series)
    DcPowerFlowData(path; from=nothing, convention=:series)

DC power flow data in PowerModels orientation and sign convention.

- `incidence_matrix.matrix` is the branch by bus matrix `A`, with `+1` at the
  from bus and `-1` at the to bus.
- `branch_susceptance` is `imag(inv(r + im*x))` for `:series`, `-1/(x*tap)`
  for `:matpower`, and `-1/x` for `:reactance_only`.
- `phase_shift_injection` is `A' * (b .* shift)`.
- `branch_rows` maps each row of `A` and each entry of `b` to the parsed branch
  table. `skipped_branch_rows` lists in-service rows omitted because their DC
  denominator is too small.

The bus susceptance matrix and branch susceptance matrix are
`B = A' * Diagonal(b) * A` and `Bf = Diagonal(b) * A`. Bus and branch angle
terms are `p_bus = -B * va + phase_shift_injection` and
`p_branch = -Bf * va`.
"""
struct DcPowerFlowData
    incidence_matrix::IncidenceMatrix{Float64}
    branch_susceptance::Vector{Float64}
    phase_shift_injection::Vector{Float64}
    branch_rows::Vector{Int}
    skipped_branch_rows::Vector{Int}
    convention::Symbol
end

function DcPowerFlowData(net::BalancedNetwork; convention=:series)
    token = _dc_convention_token(convention)
    _, coo, idx_to_bus, bus_to_idx = _dc_incidence_arrow(net, convention, token)
    m, n = Int(coo.col_count), Int(coo.row_count)
    b, p_shift, rows64, skipped64 = _dc_power_flow_fill(net, token, m, n)
    rows = _one_based_rows(rows64)
    skipped = _one_based_rows(skipped64)
    incidence = _incidence_matrix_from_owned_coo!(
        coo, idx_to_bus, bus_to_idx, rows)
    return DcPowerFlowData(incidence, b, p_shift, rows, skipped,
                           _dc_convention_symbol(token))
end

DcPowerFlowData(path::AbstractString; from=nothing, convention=:series) =
    _matrix_from_path(net -> DcPowerFlowData(net; convention=convention),
                      path, "DcPowerFlowData"; from=from)

"""
    branch_susceptance(net::BalancedNetwork; convention=:series)
    branch_susceptance(path; from=nothing, convention=:series)

Return the branch susceptance vector in the same row order as
[`DcPowerFlowData`](@ref). The formulas are `imag(inv(r + im*x))` for
`:series`, `-1/(x*tap)` for `:matpower`, and `-1/x` for `:reactance_only`.
"""
branch_susceptance(net::BalancedNetwork; convention=:series) =
    _dc_vector_fill(net, "branch_susceptance", :pio_branch_susceptance,
                    Float64, _dc_convention_token(convention))

branch_susceptance(path::AbstractString; from=nothing, convention=:series) =
    _matrix_from_path(net -> branch_susceptance(net; convention=convention),
                      path, "branch_susceptance"; from=from)
