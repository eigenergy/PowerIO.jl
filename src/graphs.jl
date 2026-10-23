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


"""
    network_islands(net::BalancedNetwork; include_switches=true,
                    include_transformers_3w=true) -> Vector{Vector{Int}}
    network_islands(m::PioModule{BalancedNetwork}; kwargs...)

Find the connected AC islands of a balanced network and return each island as
source bus IDs. Islands and bus IDs within each island follow the network's bus
table order, making the result deterministic.

In-service branches always connect their terminal buses. When
`include_switches=true` (the default), closed switches also connect their
terminal buses. When `include_transformers_3w=true` (the default), each
in-service three-winding transformer connects all of its winding buses.
Out-of-service branches and three-winding transformers, open switches, and
HVDC links do not join AC islands. A bus with no included connections is
returned as a one-bus island.

This is a structural connectivity check, not a power-flow solvability test.
"""
function network_islands(net::BalancedNetwork;
                         include_switches::Bool=true,
                         include_transformers_3w::Bool=true)
    buses = collect(net.buses)
    bus_ids = [bus.id for bus in buses]
    edges = Tuple{Int,Int}[]

    for branch in net.branches
        branch.in_service || continue
        push!(edges, (branch.from_bus_id, branch.to_bus_id))
    end

    if include_switches
        for switch in net.switches
            switch.closed || continue
            push!(edges, (switch.from_bus_id, switch.to_bus_id))
        end
    end

    if include_transformers_3w
        for transformer in net.transformers_3w
            transformer.in_service || continue
            windings = transformer.windings
            length(windings) < 2 && continue
            first_bus = windings[1].bus_id
            for winding in windings[2:end]
                push!(edges, (first_bus, winding.bus_id))
            end
        end
    end

    return _connected_components(bus_ids, edges)
end

network_islands(m::PioModule{BalancedNetwork}; kwargs...) =
    network_islands(m.value; kwargs...)

# Pure-Julia connected-components primitive, kept separate so its ordering and
# edge-case behavior can be tested without loading the native C library.
function _connected_components(bus_ids::AbstractVector{<:Integer},
                               edges::AbstractVector{<:Tuple{<:Integer,<:Integer}})
    ids = Int.(bus_ids)
    length(unique(ids)) == length(ids) ||
        throw(ArgumentError("network_islands requires unique source bus IDs"))
    row = Dict(id => i for (i, id) in enumerate(ids))
    adjacency = [Int[] for _ in ids]

    for (from_id, to_id) in edges
        from = get(row, Int(from_id), 0)
        to = get(row, Int(to_id), 0)
        from != 0 && to != 0 ||
            throw(ArgumentError("network connectivity references an unknown source bus ID"))
        push!(adjacency[from], to)
        push!(adjacency[to], from)
    end

    seen = falses(length(ids))
    components = Vector{Vector{Int}}()
    for start in eachindex(ids)
        seen[start] && continue
        stack = [start]
        seen[start] = true
        component_rows = Int[]
        while !isempty(stack)
            current = pop!(stack)
            push!(component_rows, current)
            for neighbor in adjacency[current]
                if !seen[neighbor]
                    seen[neighbor] = true
                    push!(stack, neighbor)
                end
            end
        end
        sort!(component_rows)
        push!(components, ids[component_rows])
    end
    return components
end
