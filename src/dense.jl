# --- dense numeric surface ----------------------------------------------
#
# The JSON transport above is the rich, lossless view (every field + extras). For
# the matrix-assembly path a consumer wants the numeric tables as dense typed
# arrays without parsing JSON: the C ABI fills caller-allocated buffers
# (`pio_bus_ids` / `pio_branches` / `pio_gens` / `pio_bus_demand` / `pio_bus_shunt`)
# straight from the IndexCore the handle built once at parse, and answers the
# topology scalars (`pio_n_islands` / `pio_is_radial` / `pio_ref_bus_index`) off the same core.
# Raw MATPOWER units throughout: 1-based bus ids in `bus_ids`, branch `from`/`to`,
# and gen `bus` (the same id space — invert `bus_ids` to map an endpoint to a dense
# row), degrees for `shift`, total line charging in `b`, raw `tap` (0 means 1).
#
# Every helper takes the BalancedNetworkHandle and preserves it across its ccalls (the
# raw pointer never travels alone); see `_normalize_handle` for why.

# The v4 extractors take a `cap` and return the total count (write up to `cap`,
# never overflow). The counts come from `pio_n_*` on the same immutable handle, so
# `cap == count`; verifying the return catches an ABI contract violation cheaply
# (the cap/count convention exists precisely so a short fill is detectable). Any
# output pointer may be NULL to skip.
function _check_filled(got, want::Int, what::AbstractString)
    Int(got) == want || error("PowerIO: $what returned $got of $want expected " *
                              "(a cap/count mismatch — incompatible C ABI?)")
    return
end

function _branch_tables(h::BalancedNetworkHandle, m::Int)
    from = Vector{Int64}(undef, m); to = Vector{Int64}(undef, m)
    r = Vector{Float64}(undef, m); x = Vector{Float64}(undef, m); b = Vector{Float64}(undef, m)
    tap = Vector{Float64}(undef, m); shift = Vector{Float64}(undef, m)
    insvc = Vector{UInt8}(undef, m)
    got = GC.@preserve h ccall((:pio_branches, _lib()), Csize_t,
          (Ptr{Cvoid}, Ptr{Int64}, Ptr{Int64}, Ptr{Float64}, Ptr{Float64},
           Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{UInt8}, Csize_t),
          h.ptr, from, to, r, x, b, tap, shift, insvc, m)
    _check_filled(got, m, "pio_branches")
    return (; from, to, r, x, b, tap, shift, in_service = insvc)
end

function _gen_tables(h::BalancedNetworkHandle, ng::Int)
    bus = Vector{Int64}(undef, ng); pg = Vector{Float64}(undef, ng)
    pmax = Vector{Float64}(undef, ng); pmin = Vector{Float64}(undef, ng)
    insvc = Vector{UInt8}(undef, ng)
    got = GC.@preserve h ccall((:pio_gens, _lib()), Csize_t,
          (Ptr{Cvoid}, Ptr{Int64}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Ptr{UInt8}, Csize_t),
          h.ptr, bus, pg, pmax, pmin, insvc, ng)
    _check_filled(got, ng, "pio_gens")
    return (; bus, pg, pmax, pmin, in_service = insvc)
end

function _bus_demand(h::BalancedNetworkHandle, n::Int)
    pd = Vector{Float64}(undef, n); qd = Vector{Float64}(undef, n)
    got = GC.@preserve h ccall((:pio_bus_demand, _lib()), Csize_t,
          (Ptr{Cvoid}, Ptr{Float64}, Ptr{Float64}, Csize_t), h.ptr, pd, qd, n)
    _check_filled(got, n, "pio_bus_demand")
    return (pd, qd)
end

function _bus_shunt(h::BalancedNetworkHandle, n::Int)
    gs = Vector{Float64}(undef, n); bs = Vector{Float64}(undef, n)
    got = GC.@preserve h ccall((:pio_bus_shunt, _lib()), Csize_t,
          (Ptr{Cvoid}, Ptr{Float64}, Ptr{Float64}, Csize_t), h.ptr, gs, bs, n)
    _check_filled(got, n, "pio_bus_shunt")
    return (gs, bs)
end

# Dense numeric extraction off a live handle, shared by the BalancedNetwork and path
# methods. The whole body runs under GC.@preserve h: a dozen ccalls with Julia
# allocations between them, exactly the shape where a finalizer racing the raw
# pointer would be a use after free.
function _dense_from_handle(h::BalancedNetworkHandle)
    GC.@preserve h begin
        p = h.ptr
        n = Int(ccall((:pio_n_buses, _lib()), Csize_t, (Ptr{Cvoid},), p))
        m = Int(ccall((:pio_n_branches, _lib()), Csize_t, (Ptr{Cvoid},), p))
        ng = Int(ccall((:pio_n_gens, _lib()), Csize_t, (Ptr{Cvoid},), p))
        bus_ids = Vector{Int64}(undef, n)
        _check_filled(ccall((:pio_bus_ids, _lib()), Csize_t,
                            (Ptr{Cvoid}, Ptr{Int64}, Csize_t), p, bus_ids, n), n, "pio_bus_ids")
        pd, qd = _bus_demand(h, n)
        gs, bs = _bus_shunt(h, n)
        return (;
            n, m, ng,
            base_mva = ccall((:pio_base_mva, _lib()), Cdouble, (Ptr{Cvoid},), p),
            bus_ids,
            branch = _branch_tables(h, m),
            gen = _gen_tables(h, ng),
            demand = (; pd, qd),
            shunt = (; gs, bs),
            reference_bus = Int(ccall((:pio_ref_bus_index, _lib()), Int64, (Ptr{Cvoid},), p)),
            n_components = Int(ccall((:pio_n_islands, _lib()), Csize_t, (Ptr{Cvoid},), p)),
            is_radial = ccall((:pio_is_radial, _lib()), Cint, (Ptr{Cvoid},), p) != 0,
        )
    end
end

"""
    to_dense(net::BalancedNetwork) -> NamedTuple
    to_dense(path; from=nothing) -> NamedTuple

Pull a case's numeric tables as dense typed arrays straight from the C ABI,
skipping the JSON transport (the fast path for matrix assembly). Takes a parsed
[`BalancedNetwork`](@ref) (via its live handle) or a `path` to parse first (which never
builds the JSON view). Fields:

- `n`, `m`, `ng` — bus / branch / generator counts.
- `base_mva` — system base.
- `bus_ids::Vector{Int64}` — 1-based bus ids in dense order; row `k` of every
  per-bus table is bus `bus_ids[k]`. Invert it to map a 1-based endpoint id to a
  dense row.
- `branch` — NamedTuple of `from, to` (1-based bus ids), `r, x, b, tap, shift`
  (raw MATPOWER units, degrees, total charging, raw tap), and `in_service::Vector{UInt8}`.
- `gen` — NamedTuple of `bus` (1-based id, one row per machine), `pg, pmax, pmin`
  (MW), `in_service`.
- `demand`, `shunt` — NamedTuples of per-bus `(pd, qd)` and `(gs, bs)` in dense order.
- `reference_bus::Int` — dense 0-based index *into `bus_ids`* of the single
  reference bus (not a 1-based id), or `-1` when there is no unique reference
  (none, or several).
- `n_components::Int`, `is_radial::Bool` — connectivity of the in-service topology.

For the rich, lossless element tables (costs, extras, storage, HVDC) use the
accessors on a [`parse_file`](@ref) `BalancedNetwork`; for self-describing columnar export
use [`to_arrow`](@ref).
"""
to_dense(net::BalancedNetwork) = _dense_from_handle(_live_handle(net, "to_dense"))
function to_dense(path::AbstractString; from=nothing)
    h = _parse_handle(path; from=from)
    try
        return _dense_from_handle(h)
    finally
        finalize(h)  # buffers are copied out; free the handle now rather than at GC
    end
end
