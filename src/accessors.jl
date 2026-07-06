# --- accessor API -------------------------------------------------------
#
# The v0.0.1 API bridges read: the parsed element tables plus a few scalars.
# Element field names mirror the Rust `BalancedNetwork` (powerio/src/network.rs) and are
# the stable binding policy: raw MATPOWER units (MW/MVAr, degrees), 1-based bus ids,
# out-of-service elements retained, so a consumer normalizes as it sees fit:
#
#   bus:     id, kind ∈ {"PQ","PV","REF","ISOLATED"}, vm, va (deg), base_kv,
#            vmax, vmin, area, zone, name, extras
#   gen:     bus, pg, qg, pmax, pmin, qmax, qmin, vg, mbase, in_service,
#            cost (`nothing`, or {model, startup, shutdown, ncost, coeffs}),
#            caps (ordered 11-element nullable array
#            [pc1, pc2, qc1min, qc1max, qc2min, qc2max, ramp_agc, ramp_10,
#            ramp_30, ramp_q, apf])
#   branch:  from, to, r, x, b, rate_a, rate_b, rate_c, tap, shift (deg),
#            in_service, angmin (deg), angmax (deg), extras
#   load:    bus, p (MW), q (MVAr), in_service, extras
#   shunt:   bus, g, b, in_service, extras
#   storage: bus, ps, qs, energy, energy_rating, charge_rating, discharge_rating,
#            charge_efficiency, discharge_efficiency, thermal_rating, qmin, qmax,
#            r, x, p_loss, q_loss, in_service, extras
#   hvdc:    from, to, in_service, pf, pt, qf, qt, vf, vt, pmin, pmax, qminf,
#            qmaxf, qmint, qmaxt, loss0, loss1, extras
#
# Plus scalars: `base_mva`, `network_name`, `source_format`, `reference_bus_id`.
# The fully typed struct mirroring `network.rs` and the dense-extraction fast path
# are v0.1.0 (issue #2); these views are enough for the ecosystem bridges.

function _maybe_live_handle(net::BalancedNetwork)
    h = getfield(net, :handle)
    return (h === nothing || h.ptr == C_NULL) ? nothing : h
end

function _handle_count(net::BalancedNetwork, sym::Symbol)
    h = _maybe_live_handle(net)
    h === nothing && return nothing
    lib = getfield(h, :lib)
    return Int(GC.@preserve h ccall(_library_symbol(lib, sym), Csize_t, (Ptr{Cvoid},), h.ptr))
end

function _handle_bus_ids(h::BalancedNetworkHandle)
    lib = getfield(h, :lib)
    n = Int(GC.@preserve h ccall(_library_symbol(lib, :pio_n_buses), Csize_t, (Ptr{Cvoid},), h.ptr))
    return _handle_bus_ids(h, n)
end

function _handle_bus_ids(h::BalancedNetworkHandle, n::Integer)
    lib = getfield(h, :lib)
    ids = Vector{Int64}(undef, n)
    GC.@preserve h begin
        got = ccall(_library_symbol(lib, :pio_bus_ids), Csize_t,
                    (Ptr{Cvoid}, Ptr{Int64}, Csize_t), h.ptr, ids, n)
        _check_filled(got, Int(n), "pio_bus_ids")
    end
    return ids
end

function n_buses(net::BalancedNetwork)
    return Int(_summary(net).counts.buses)
end

function n_branches(net::BalancedNetwork)
    return Int(_summary(net).counts.branches)
end

function base_mva(net::BalancedNetwork)
    return Float64(_summary(net).base_mva)
end

base_frequency(net::BalancedNetwork) = Float64(_summary(net).base_frequency)

"""
    network_name(net) -> String

The case name carried through from the source file.
"""
function network_name(net::BalancedNetwork)
    return String(_summary(net).name)
end

"Buses, in source order (1-based ids preserved). See the accessor API note."
buses(net::BalancedNetwork) = net.data.buses
"Generators, one per machine (`bus` repeats when a bus has several)."
generators(net::BalancedNetwork) = net.data.generators
"Branches (lines and transformers), in source order."
branches(net::BalancedNetwork) = net.data.branches
"First-class loads (PSS/E and PowerModels keep several per bus; MATPOWER splits its bus row)."
loads(net::BalancedNetwork) = net.data.loads
"First-class bus shunts."
shunts(net::BalancedNetwork) = net.data.shunts
"First-class storage units; empty unless the source carries them (PowerModels, egret)."
storage(net::BalancedNetwork) = net.data.storage
"Two-terminal HVDC lines (MATPOWER `dcline`); empty unless the source carries them."
hvdc(net::BalancedNetwork) = net.data.hvdc

"""
    n_gens(net) -> Int

Number of generator rows (one per machine; `bus` repeats). Matches `pio_n_gens`:
every row, not in-service-filtered.
"""
function n_gens(net::BalancedNetwork)
    return Int(_summary(net).counts.generators)
end

"""
    source_format(net) -> String

The format the case was read from, verbatim from the Rust `SourceFormat` enum.
Examples include `"Matpower"`, `"PowerModelsJson"`, `"EgretJson"`, `"Psse"`,
`"PowerWorld"`, `"PandapowerJson"`, `"Pslf"`, `"PypsaCsv"`, `"Gridfm"`,
`"SurgeJson"`, `"InMemory"`, and `"Normalized"` (the last is the output of
[`to_normalized`](@ref)).
"""
function source_format(net::BalancedNetwork)
    return String(_summary(net).source_format)
end

"""
    reference_bus_id(net) -> Union{Int,Nothing}

The 1-based id of the reference (slack) bus, or `nothing` unless exactly one bus
has `kind == "REF"`. This mirrors the "exactly one" rule of the C ABI's
`pio_ref_bus_index` (which returns a dense 0-based index, not an id), but returns
the 1-based id space the other accessors use.
"""
function reference_bus_id(net::BalancedNetwork)
    refs = _summary(net).topology.reference_bus_ids
    refs === nothing && return nothing
    length(refs) == 1 || return nothing
    return Int(refs[1])
end

"""
    reference_bus_indices(net) -> Vector{Int}

The dense `[0, n)` indices of every reference (slack) bus, in dense bus order.
Unlike [`reference_bus_id`](@ref) — which returns a single 1-based id and only
when exactly one bus is `REF` — this returns all of them (zero, one, or many) as
dense indices. Map an index back to a 1-based id with `to_dense(net).bus_ids`.
Needs `net`'s live Rust handle (from [`parse_file`](@ref)).
"""
function reference_bus_indices(net::BalancedNetwork)
    h = _live_handle(net, "reference_bus_indices")
    lib = getfield(h, :lib)
    # v4 folds the count and fill into one `pio_ref_bus_indices(net, out, cap)`
    # (writes up to `cap`, returns the total): size with a null buffer, then fill.
    return GC.@preserve h begin
        n = Int(ccall(_library_symbol(lib, :pio_ref_bus_indices), Csize_t,
                      (Ptr{Cvoid}, Ptr{Int64}, Csize_t), h.ptr, C_NULL, 0))
        out = Vector{Int64}(undef, n)
        _check_filled(ccall(_library_symbol(lib, :pio_ref_bus_indices), Csize_t,
                            (Ptr{Cvoid}, Ptr{Int64}, Csize_t), h.ptr, out, n), n, "pio_ref_bus_indices")
        Vector{Int}(out)
    end
end

"""
    n_components(net) -> Int

Number of connected components of the in-service topology, as the C ABI computes it
(`pio_n_islands`). The same quantity as `to_dense(net).n_components`, without
building the dense view. Needs `net`'s live Rust handle (from [`parse_file`](@ref)).
"""
function n_components(net::BalancedNetwork)
    n = _summary(net).topology.n_components
    n === nothing && error("PowerIO.n_components: this BalancedNetwork has no live network handle")
    return Int(n)
end

"""
    is_radial(net) -> Bool

Whether the in-service topology is radial (a forest), as the C ABI computes it
(`pio_is_radial`). The same quantity as `to_dense(net).is_radial`, without building
the dense view. Needs `net`'s live Rust handle (from [`parse_file`](@ref)).
"""
function is_radial(net::BalancedNetwork)
    value = _summary(net).topology.is_radial
    value === nothing && error("PowerIO.is_radial: this BalancedNetwork has no live network handle")
    return Bool(value)
end

"""
    bus_type_code(kind) -> Int

Map the canonical bus-type string (`"PQ"`, `"PV"`, `"REF"`, `"ISOLATED"`) to the
MATPOWER code (1, 2, 3, 4). The strings are the Rust core's `BusType::as_str`
values.
"""
function bus_type_code(kind::AbstractString)
    kind == "PQ"       && return 1
    kind == "PV"       && return 2
    kind == "REF"      && return 3
    kind == "ISOLATED" && return 4
    throw(ArgumentError("PowerIO: unknown bus type $(repr(kind))"))
end
