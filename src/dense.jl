# `to_dense`: the balanced tables as dense typed arrays, for matrix assembly
# and solver bridges that want columns rather than element structs.

"""
    to_dense(net::BalancedNetwork) -> NamedTuple
    to_dense(m::PioModule{BalancedNetwork}) -> NamedTuple

The balanced tables as dense arrays. Fields:

- `n`, `m`, `ng`, `ns`: bus, branch, generator, and switch counts.
- `base_mva`: system base.
- `bus_ids::Vector{Int}`: source bus ids in table order; row `k` of every per
  bus table is bus `bus_ids[k]`.
- `branch`: `from`, `to` (bus ids), `r`, `x`, `b` (per unit; `b` is the total
  charging), `g_fr`, `b_fr`, `g_to`, `b_to` (terminal split), `tap` (source
  value, 0 means 1), `shift` (degrees), `in_service::Vector{Bool}`.
- `gen`: `bus`, `pg`, `qg`, `pmax`, `pmin`, `qmax`, `qmin` (MW and MVAr),
  `vg` (per unit), `mbase` (MVA), `in_service`.
- `demand`, `shunt`: per bus sums of in-service loads (`pd`, `qd`) and shunts
  (`gs`, `bs`), in MW and MVAr at nominal voltage.
- `reference_bus`: the 1-based row of the single `"REF"` bus, or `nothing`
  when there is none or several.
- `switch`: `from`, `to`, `closed::Vector{Bool}`, `thermal_rating`,
  `current_rating`, `pf`, `qf`, `pt`, `qt` (absent optionals are 0.0).
"""
function to_dense(net::BalancedNetwork)
    buses = collect(net.buses)
    branches = collect(net.branches)
    gens = collect(net.generators)
    switches = collect(net.switches)
    bus_ids = [b.id for b in buses]
    row = Dict(id => k for (k, id) in enumerate(bus_ids))
    n = length(buses)

    pd = zeros(n); qd = zeros(n)
    for l in net.loads
        l.in_service || continue
        k = row[l.bus_id]
        pd[k] += l.p_mw
        qd[k] += l.q_mvar
    end
    gs = zeros(n); bs = zeros(n)
    for s in net.shunts
        s.in_service || continue
        k = row[s.bus_id]
        gs[k] += s.conductance_mw
        bs[k] += s.susceptance_mvar
    end
    refs = findall(b -> b.bus_type == "REF", buses)
    zero_if_nothing(x) = x === nothing ? 0.0 : x

    return (;
        n, m = length(branches), ng = length(gens), ns = length(switches),
        base_mva = net.base_mva,
        bus_ids,
        branch = (;
            from = [b.from_bus_id for b in branches], to = [b.to_bus_id for b in branches],
            r = [b.resistance_pu for b in branches], x = [b.reactance_pu for b in branches],
            b = [b.total_charging_susceptance_pu for b in branches],
            g_fr = [b.from_conductance_pu for b in branches], b_fr = [b.from_susceptance_pu for b in branches],
            g_to = [b.to_conductance_pu for b in branches], b_to = [b.to_susceptance_pu for b in branches],
            tap = [b.tap_ratio for b in branches], shift = [b.phase_shift_degrees for b in branches],
            in_service = [b.in_service for b in branches],
        ),
        gen = (;
            bus = [g.bus_id for g in gens],
            pg = [g.active_power_mw for g in gens], qg = [g.reactive_power_mvar for g in gens],
            pmax = [g.active_power_max_mw for g in gens], pmin = [g.active_power_min_mw for g in gens],
            qmax = [g.reactive_power_max_mvar for g in gens], qmin = [g.reactive_power_min_mvar for g in gens],
            vg = [g.voltage_setpoint_pu for g in gens], mbase = [g.machine_base_mva for g in gens],
            in_service = [g.in_service for g in gens],
        ),
        demand = (; pd, qd),
        shunt = (; gs, bs),
        reference_bus = length(refs) == 1 ? refs[1] : nothing,
        switch = (;
            from = [s.from_bus_id for s in switches], to = [s.to_bus_id for s in switches],
            closed = [s.closed for s in switches],
            thermal_rating = [zero_if_nothing(s.thermal_rating_mva) for s in switches],
            current_rating = [zero_if_nothing(s.current_rating_a) for s in switches],
            pf = [zero_if_nothing(s.from_active_power_mw) for s in switches],
            qf = [zero_if_nothing(s.from_reactive_power_mvar) for s in switches],
            pt = [zero_if_nothing(s.to_active_power_mw) for s in switches],
            qt = [zero_if_nothing(s.to_reactive_power_mvar) for s in switches],
        ),
    )
end

to_dense(m::PioModule{BalancedNetwork}) = to_dense(m.value)
