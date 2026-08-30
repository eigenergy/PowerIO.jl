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
# are v0.1.0 (issue #2); these tables are enough for the ecosystem bridges.

function _maybe_live_handle(net::BalancedNetwork)
    h = getfield(net, :handle)
    return (h === nothing || h.ptr == C_NULL) ? nothing : h
end

# One count off an already-resolved live handle (`pio_balanced_network_n_switches`): the
# pointer-lifetime incantation for a `size_t(handle)` C accessor in one place.
_handle_count(h::BalancedNetworkHandle, sym::Symbol) =
    Int(GC.@preserve h ccall(_library_symbol(getfield(h, :lib), sym),
                             Csize_t, (Ptr{Cvoid},), h.ptr))

# The binding of the v0.7 scalar string accessors (`pio_balanced_network_name`,
# `pio_balanced_network_source_format`), or `nothing` when there is no live handle or the
# resolved library lacks `sym`. The public `network_name` / `source_format`
# stay summary-backed (the summary is cached and its strings come from the
# same Rust fields), so this is the C surface itself; the drift canary in
# test_roundtrip.jl asserts it agrees with the summary values.
function _handle_string(net::BalancedNetwork, sym::Symbol)
    h = _maybe_live_handle(net)
    h === nothing && return nothing
    lib = getfield(h, :lib)
    _exports_symbol(sym, lib) || return nothing
    return GC.@preserve h _string_from((out, cap) -> ccall(
        _library_symbol(lib, sym), Csize_t,
        (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h.ptr, out, cap))
end

function _handle_bus_ids(h::BalancedNetworkHandle)
    lib = getfield(h, :lib)
    n = Int(GC.@preserve h ccall(_library_symbol(lib, :pio_balanced_network_n_buses), Csize_t, (Ptr{Cvoid},), h.ptr))
    return _handle_bus_ids(h, n)
end

function _handle_bus_ids(h::BalancedNetworkHandle, n::Integer)
    lib = getfield(h, :lib)
    ids = Vector{Int64}(undef, n)
    GC.@preserve h begin
        got = ccall(_library_symbol(lib, :pio_balanced_network_bus_ids), Csize_t,
                    (Ptr{Cvoid}, Ptr{Int64}, Csize_t), h.ptr, ids, n)
        _check_filled(got, Int(n), "pio_balanced_network_bus_ids")
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
    return _json_float(_summary(net).base_mva)
end

base_frequency(net::BalancedNetwork) = _json_float(_summary(net).base_frequency)

"""
    network_name(net) -> String

The case name carried through from the source file.
"""
function network_name(net::BalancedNetwork)
    return String(_summary(net).name)
end

"Buses, in source order (1-based ids preserved). See the accessor API note."
buses(net::BalancedNetwork) = net.data.buses::JSON3.Array
"Generators, one per machine (`bus` repeats when a bus has several)."
generators(net::BalancedNetwork) = net.data.generators::JSON3.Array
"Branches (lines and transformers), in source order."
branches(net::BalancedNetwork) = net.data.branches::JSON3.Array
"First-class loads (PSS/E and PowerModels keep several per bus; MATPOWER splits its bus row)."
loads(net::BalancedNetwork) = net.data.loads::JSON3.Array
"First-class bus shunts."
shunts(net::BalancedNetwork) = net.data.shunts::JSON3.Array
"First-class storage units; empty unless the source carries them (PowerModels, egret)."
storage(net::BalancedNetwork) = net.data.storage::JSON3.Array
"Two-terminal HVDC lines (MATPOWER `dcline`); empty unless the source carries them."
hvdc(net::BalancedNetwork) = net.data.hvdc::JSON3.Array
"Ideal switch rows; empty unless the source carries them."
switches(net::BalancedNetwork) = net.data.switches::JSON3.Array

"""
    n_gens(net) -> Int

Number of generator rows (one per machine; `bus` repeats). Matches `pio_balanced_network_n_gens`:
every row, not in-service-filtered.
"""
function n_gens(net::BalancedNetwork)
    return Int(_summary(net).counts.generators)
end

"""
    n_generators(net::BalancedNetwork) -> Int

Number of generator rows. This is the descriptive spelling of [`n_gens`](@ref)
and dispatches across both network families.
"""
n_generators(net::BalancedNetwork) = n_gens(net)

"""
    n_switches(net) -> Int

Number of switch rows (two-terminal ideal switches; PowerModels JSON carries
them). Summary-backed like its count siblings — both summary builders always
emit `counts.switches`, so a missing key is a schema skew and errors loudly.
The dense fast path reads `pio_balanced_network_n_switches` directly (see `to_dense`).
"""
function n_switches(net::BalancedNetwork)
    return Int(_summary(net).counts.switches)
end

"""
    source_format(net) -> String

The format the case was read from, as the lowercase token every `from`
argument accepts, so `to_format(net, source_format(other))` works for every
writable format. Examples include `"matpower"`, `"powermodels-json"`,
`"egret-json"`, `"psse"`, `"powerworld"`, `"pandapower-json"`, `"pslf"`,
`"pypsa-csv"`, `"gridfm"`, `"surge-json"`, `"in-memory"`, and `"normalized"`
(the last is the output of [`to_normalized`](@ref)).
"""
function source_format(net::BalancedNetwork)
    return String(_summary(net).source_format)
end

"""
    reference_bus_id(net) -> Union{Int,Nothing}

The 1-based id of the reference (slack) bus, or `nothing` unless exactly one bus
has `kind == "REF"`. This mirrors the "exactly one" rule of the C ABI's
`pio_balanced_network_ref_bus_index` (which returns a dense 0-based index, not an id), but returns
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
    # v4 folds the count and fill into one `pio_balanced_network_ref_bus_indices(net, out, cap)`
    # (writes up to `cap`, returns the total): size with a null buffer, then fill.
    return GC.@preserve h begin
        n = Int(ccall(_library_symbol(lib, :pio_balanced_network_ref_bus_indices), Csize_t,
                      (Ptr{Cvoid}, Ptr{Int64}, Csize_t), h.ptr, C_NULL, 0))
        out = Vector{Int64}(undef, n)
        _check_filled(ccall(_library_symbol(lib, :pio_balanced_network_ref_bus_indices), Csize_t,
                            (Ptr{Cvoid}, Ptr{Int64}, Csize_t), h.ptr, out, n), n, "pio_balanced_network_ref_bus_indices")
        Vector{Int}(out)
    end
end

"""
    reference_bus_positions(net::BalancedNetwork) -> Vector{Int}

The 1-based positions of every reference bus in dense bus order. These values
index `to_dense(net).bus_ids` directly. [`reference_bus_indices`](@ref) remains
the zero based C index view for compatibility.
"""
reference_bus_positions(net::BalancedNetwork) = reference_bus_indices(net) .+ 1

"""
    n_components(net) -> Int

Number of connected components of the in-service topology, as the C ABI computes it
(`pio_balanced_network_n_islands`). The same quantity as `to_dense(net).n_components`, without
building dense tables. Needs `net`'s live Rust handle (from [`parse_file`](@ref)).
"""
function n_components(net::BalancedNetwork)
    n = _summary(net).topology.n_components
    n === nothing && error("PowerIO.n_components: this BalancedNetwork has no live network handle")
    return Int(n)
end

"""
    n_islands(net::BalancedNetwork) -> Int

Number of electrical islands in the in-service topology. This is the power
system spelling of [`n_components`](@ref).
"""
n_islands(net::BalancedNetwork) = n_components(net)

"""
    is_radial(net) -> Bool

Whether the in-service topology is radial (a forest), as the C ABI computes it
(`pio_balanced_network_is_radial`). The same quantity as `to_dense(net).is_radial`, without building
dense tables. Needs `net`'s live Rust handle (from [`parse_file`](@ref)).
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
