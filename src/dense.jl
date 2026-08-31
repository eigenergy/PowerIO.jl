# --- dense numeric API ---------------------------------------------------
#
# The JSON transport above is the rich, lossless payload (every field + extras). For
# the matrix-assembly path a consumer wants the numeric tables as dense typed
# arrays without parsing JSON: the C ABI fills caller-allocated buffers
# (`pio_balanced_network_bus_ids` / `pio_balanced_network_branches` / `pio_balanced_network_branch_charging` / `pio_balanced_network_switches` /
# `pio_balanced_network_gens` / `pio_balanced_network_bus_demand` / `pio_balanced_network_bus_shunt`)
# straight from the IndexCore the handle built once at parse, and answers the
# topology scalars (`pio_balanced_network_n_islands` / `pio_balanced_network_is_radial` / `pio_balanced_network_ref_bus_index`) off the same core.
# Raw MATPOWER units throughout: 1-based bus ids in `bus_ids`, branch `from`/`to`,
# and gen `bus` (the same id space — invert `bus_ids` to map an endpoint to a dense
# row), degrees for `shift`, total line charging in `b`, raw `tap` (0 means 1).
#
# Every helper takes the BalancedNetworkHandle and preserves it across its ccalls (the
# raw pointer never travels alone); see `_normalize_handle` for why.

# The v4 extractors take a `cap` and return the total count (write up to `cap`,
# never overflow). The counts come from `pio_n_*` on the same immutable handle, so
# `cap == count`; verifying the return catches an ABI mismatch cheaply
# (the cap/count convention exists precisely so a short fill is detectable). Any
# output pointer may be NULL to skip.
function _check_filled(got, want::Int, what::AbstractString)
    Int(got) == want || error("PowerIO: $what returned $got of $want expected " *
                              "(a cap/count mismatch — incompatible C ABI?)")
    return
end

function _branch_tables(h::BalancedNetworkHandle, m::Int)
    lib = getfield(h, :lib)
    from = Vector{Int64}(undef, m); to = Vector{Int64}(undef, m)
    r = Vector{Float64}(undef, m); x = Vector{Float64}(undef, m); b = Vector{Float64}(undef, m)
    tap = Vector{Float64}(undef, m); shift = Vector{Float64}(undef, m)
    insvc = Vector{UInt8}(undef, m)
    got = GC.@preserve h ccall(_library_symbol(lib, :pio_balanced_network_branches), Csize_t,
          (Ptr{Cvoid}, Ptr{Int64}, Ptr{Int64}, Ptr{Float64}, Ptr{Float64},
           Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{UInt8}, Csize_t),
          h.ptr, from, to, r, x, b, tap, shift, insvc, m)
    _check_filled(got, m, "pio_balanced_network_branches")
    return (; from, to, r, x, b, tap, shift, in_service = insvc)
end

# Per-branch terminal charging (`pio_balanced_network_branch_charging`, powerio v0.7): the
# asymmetric pi model split behind the branch table's total `b`. Per unit.
function _branch_charging(h::BalancedNetworkHandle, m::Int)
    lib = getfield(h, :lib)
    g_fr = Vector{Float64}(undef, m); b_fr = Vector{Float64}(undef, m)
    g_to = Vector{Float64}(undef, m); b_to = Vector{Float64}(undef, m)
    got = GC.@preserve h ccall(_library_symbol(lib, :pio_balanced_network_branch_charging), Csize_t,
          (Ptr{Cvoid}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Csize_t),
          h.ptr, g_fr, b_fr, g_to, b_to, m)
    _check_filled(got, m, "pio_balanced_network_branch_charging")
    return (; g_fr, b_fr, g_to, b_to)
end

# The one predicate for the v0.7 switch surface, shared by `to_dense` and
# `n_switches` so a partial library cannot make the two disagree: both symbols
# ship together, so requiring both is the conservative read.
_has_switch_extractors(lib::AbstractString=_lib()) =
    _exports_symbol(:pio_balanced_network_n_switches, lib) && _exports_symbol(:pio_balanced_network_switches, lib)

# The switch table (`pio_balanced_network_switches`, powerio v0.7). `from`/`to` are 1-based bus
# ids; absent optional ratings and terminal flows come back as 0.0.
function _switch_tables(h::BalancedNetworkHandle, ns::Int)
    lib = getfield(h, :lib)
    from = Vector{Int64}(undef, ns); to = Vector{Int64}(undef, ns)
    closed = Vector{UInt8}(undef, ns)
    thermal_rating = Vector{Float64}(undef, ns); current_rating = Vector{Float64}(undef, ns)
    pf = Vector{Float64}(undef, ns); qf = Vector{Float64}(undef, ns)
    pt = Vector{Float64}(undef, ns); qt = Vector{Float64}(undef, ns)
    got = GC.@preserve h ccall(_library_symbol(lib, :pio_balanced_network_switches), Csize_t,
          (Ptr{Cvoid}, Ptr{Int64}, Ptr{Int64}, Ptr{UInt8}, Ptr{Float64}, Ptr{Float64},
           Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Csize_t),
          h.ptr, from, to, closed, thermal_rating, current_rating, pf, qf, pt, qt, ns)
    _check_filled(got, ns, "pio_balanced_network_switches")
    return (; from, to, closed, thermal_rating, current_rating, pf, qf, pt, qt)
end

function _gen_tables(h::BalancedNetworkHandle, ng::Int)
    lib = getfield(h, :lib)
    bus = Vector{Int64}(undef, ng); pg = Vector{Float64}(undef, ng)
    pmax = Vector{Float64}(undef, ng); pmin = Vector{Float64}(undef, ng)
    insvc = Vector{UInt8}(undef, ng)
    got = GC.@preserve h ccall(_library_symbol(lib, :pio_balanced_network_gens), Csize_t,
          (Ptr{Cvoid}, Ptr{Int64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{UInt8}, Csize_t),
          h.ptr, bus, pg, pmax, pmin, insvc, ng)
    _check_filled(got, ng, "pio_balanced_network_gens")
    return (; bus, pg, pmax, pmin, in_service = insvc)
end

function _bus_demand(h::BalancedNetworkHandle, n::Int)
    lib = getfield(h, :lib)
    pd = Vector{Float64}(undef, n); qd = Vector{Float64}(undef, n)
    got = GC.@preserve h ccall(_library_symbol(lib, :pio_balanced_network_bus_demand), Csize_t,
          (Ptr{Cvoid}, Ptr{Float64}, Ptr{Float64}, Csize_t), h.ptr, pd, qd, n)
    _check_filled(got, n, "pio_balanced_network_bus_demand")
    return (pd, qd)
end

function _bus_shunt(h::BalancedNetworkHandle, n::Int)
    lib = getfield(h, :lib)
    gs = Vector{Float64}(undef, n); bs = Vector{Float64}(undef, n)
    got = GC.@preserve h ccall(_library_symbol(lib, :pio_balanced_network_bus_shunt), Csize_t,
          (Ptr{Cvoid}, Ptr{Float64}, Ptr{Float64}, Csize_t), h.ptr, gs, bs, n)
    _check_filled(got, n, "pio_balanced_network_bus_shunt")
    return (gs, bs)
end

# The C ABI reports "no unique reference bus" as -1, having no option type.
# Julia has one, and `reference_bus_id` already uses it. The index itself shifts
# to 1 based here: it indexes `bus_ids`, and this is Julia.
_optional_index(raw::Int64) = raw < 0 ? nothing : Int(raw) + 1

# Dense numeric extraction off a live handle, shared by the BalancedNetwork and path
# methods. The whole body runs under GC.@preserve h: a dozen ccalls with Julia
# allocations between them, exactly the case where a finalizer racing the raw
# pointer would be a use after free.
function _dense_from_handle(h::BalancedNetworkHandle)
    GC.@preserve h begin
        lib = getfield(h, :lib)
        p = h.ptr
        n = Int(ccall(_library_symbol(lib, :pio_balanced_network_n_buses), Csize_t, (Ptr{Cvoid},), p))
        m = Int(ccall(_library_symbol(lib, :pio_balanced_network_n_branches), Csize_t, (Ptr{Cvoid},), p))
        ng = Int(ccall(_library_symbol(lib, :pio_balanced_network_n_gens), Csize_t, (Ptr{Cvoid},), p))
        bus_ids = Vector{Int64}(undef, n)
        _check_filled(ccall(_library_symbol(lib, :pio_balanced_network_bus_ids), Csize_t,
                            (Ptr{Cvoid}, Ptr{Int64}, Csize_t), p, bus_ids, n), n, "pio_balanced_network_bus_ids")
        pd, qd = _bus_demand(h, n)
        gs, bs = _bus_shunt(h, n)
        # The v0.7 extractors are guarded per symbol: a pre-v0.7 ABI-4 library
        # still serves every field it can export, and the new fields are absent
        # rather than fabricated (a v0.6.3 handle can hold switches and an
        # asymmetric charging split it has no way to export).
        branch = _branch_tables(h, m)
        if _exports_symbol(:pio_balanced_network_branch_charging, lib)
            branch = merge(branch, _branch_charging(h, m))
        end
        dense = (;
            n, m, ng,
            base_mva = ccall(_library_symbol(lib, :pio_balanced_network_base_mva), Cdouble, (Ptr{Cvoid},), p),
            bus_ids,
            branch,
            gen = _gen_tables(h, ng),
            demand = (; pd, qd),
            shunt = (; gs, bs),
            # The C -1 is "no unique reference"; Julia spells absence
            # `nothing`, as `reference_bus_id` already does.
            reference_bus = _optional_index(
                ccall(_library_symbol(lib, :pio_balanced_network_ref_bus_index), Int64, (Ptr{Cvoid},), p)),
            n_components = Int(ccall(_library_symbol(lib, :pio_balanced_network_n_islands), Csize_t, (Ptr{Cvoid},), p)),
            is_radial = ccall(_library_symbol(lib, :pio_balanced_network_is_radial), Cint, (Ptr{Cvoid},), p) != 0,
        )
        if _has_switch_extractors(lib)
            ns = _handle_count(h, :pio_balanced_network_n_switches)
            dense = merge(dense, (; ns, switch = _switch_tables(h, ns)))
        end
        return dense
    end
end

"""
    to_dense(net::BalancedNetwork) -> NamedTuple
    to_dense(path; format=nothing) -> NamedTuple

Pull a case's numeric tables as dense typed arrays straight from the C ABI,
skipping the JSON transport (the fast path for matrix assembly). Takes a parsed
[`BalancedNetwork`](@ref) (via its live handle) or a `path` to parse first (which never
builds the JSON payload). Fields:

- `n`, `m`, `ng` — bus / branch / generator counts.
- `base_mva` — system base.
- `bus_ids::Vector{Int64}` — 1-based bus ids in dense order; row `k` of every
  per-bus table is bus `bus_ids[k]`. Invert it to map a 1-based endpoint id to a
  dense row.
- `branch` — NamedTuple of `from, to` (1-based bus ids), `r, x, b, tap, shift`
  (raw MATPOWER units, degrees, total charging, raw tap), `in_service::Vector{UInt8}`,
  and, with a powerio v0.7 library, the terminal charging split
  `g_fr, b_fr, g_to, b_to` (per unit; `b_fr + b_to` recovers `b`, and a
  symmetric MATPOWER line splits as `b/2`).
- `gen` — NamedTuple of `bus` (1-based id, one row per machine), `pg, pmax, pmin`
  (MW), `in_service`.
- `demand`, `shunt` — NamedTuples of per-bus `(pd, qd)` and `(gs, bs)` in dense order.
- `reference_bus::Union{Int,Nothing}` — index *into `bus_ids`* of the single
  reference bus, so `bus_ids[reference_bus]` is its id, or `nothing` when there
  is no unique reference (none, or several). The C ABI spells absence `-1` and
  counts its indices from zero; both are translated here, so this is a 1-based
  Julia index and indexes `bus_ids` directly. The C ABI and Python binding keep
  their zero based index spaces.
- `n_components::Int`, `is_radial::Bool` — connectivity of the in-service topology.
- `ns`, `switch` (the last two fields, powerio v0.7 library) — switch count and
  the switch table: `from, to` (1-based bus ids), `closed::Vector{UInt8}`,
  `thermal_rating, current_rating, pf, qf, pt, qt` (absent optionals are 0.0).
  Empty unless the source carries switches (PowerModels JSON).

The v0.7 fields (`ns`, `switch`, the charging columns) are present exactly when
the resolved library exports their extractors; an older ABI-4 library returns
the tuple without them instead of erroring or fabricating values.

For the rich, lossless element tables (costs, extras, storage, HVDC) use the
accessors on a [`parse_file`](@ref) `BalancedNetwork`; for self-describing columnar export
use [`to_arrow`](@ref).
"""
to_dense(net::BalancedNetwork) = _dense_from_handle(_live_handle(net, "to_dense"))
function to_dense(path::AbstractString;
                  format::Union{AbstractString,Nothing}=nothing)
    net = _parse_balanced(path; format)
    h = _live_handle(net, "to_dense")
    try
        return _dense_from_handle(h)
    finally
        finalize(h)  # buffers are copied out; free the handle now rather than at GC
    end
end
