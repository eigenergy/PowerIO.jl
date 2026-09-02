# Graph projections of both network types as plain Julia values.

"""
    to_graph(net::BalancedNetwork) -> NamedTuple
    to_graph(net::MulticonductorNetwork) -> NamedTuple

The bus graph of a network. `buses` lists every bus with its `id`, 1-based
`index` in the bus table, and for balanced networks its `kind` and `name`.
`edges` lists the connections that carry power: in-service branches for a
balanced network; lines, closed switches, and transformer winding pairs for a
multiconductor network. Each edge has a `kind`, its 1-based `index` in the
source table, and `from` and `to` bus ids. Parallel elements stay separate
edges.
"""
function to_graph(net::BalancedNetwork)
    buses = [(; id = b.id, index = k, kind = b.bus_type, name = something(b.name, ""))
             for (k, b) in enumerate(net.buses)]
    edges = [(; kind = "branch", index = k, from = br.from_bus_id, to = br.to_bus_id)
             for (k, br) in enumerate(net.branches) if br.in_service]
    return (; buses, edges)
end

function to_graph(net::MulticonductorNetwork)
    buses = [(; id = b.id, index = k) for (k, b) in enumerate(net.buses)]
    edges = NamedTuple{(:kind, :index, :from, :to),Tuple{String,Int,String,String}}[]
    for (k, line) in enumerate(net.lines)
        push!(edges, (; kind = "line", index = k, from = line.bus_from, to = line.bus_to))
    end
    for (k, sw) in enumerate(net.switches)
        sw.open && continue
        push!(edges, (; kind = "switch", index = k, from = sw.bus_from, to = sw.bus_to))
    end
    for (k, xf) in enumerate(net.transformers)
        windings = xf.windings
        for w in 2:length(windings)
            push!(edges, (; kind = "transformer", index = k, from = windings[1].bus, to = windings[w].bus))
        end
    end
    return (; buses, edges)
end

to_graph(m::PioModule{<:Union{BalancedNetwork,MulticonductorNetwork}}) = to_graph(m.value)
