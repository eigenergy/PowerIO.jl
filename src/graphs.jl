# --- graph projections -----------------------------------------------------

"""
    to_graph(net::BalancedNetwork)

Return the bus and in-service branch graph projection as a JSON3 object.
`buses` includes every bus in dense order with source bus ids preserved; `edges`
are in-service branches, with parallel branches kept as separate edges.
"""
function to_graph(net::BalancedNetwork)
    buses_out = [(;
        id = Int(b.id),
        index = i - 1,
        kind = String(b.kind),
        name = (n = get(b, :name, nothing); n === nothing ? "" : String(n)),
    ) for (i, b) in pairs(net.data.buses)]

    edges_out = NamedTuple[]
    for (i, br) in pairs(net.data.branches)
        get(br, :in_service, true) || continue
        push!(edges_out, (;
            kind = "branch",
            index = i - 1,
            from = Int(br.from),
            to = Int(br.to),
        ))
    end

    return JSON3.read(JSON3.write((; buses = buses_out, edges = edges_out)))
end

"""
    to_graph(net::MulticonductorNetwork)

Return the collapsed bus and terminal graph projection as a JSON3 object.
Needs a live handle from [`parse_file`](@ref) or [`parse_bytes`](@ref), and a
library exporting `pio_multiconductor_network_graph_json`.
"""
function to_graph(net::MulticonductorNetwork)
    h = _live_dist_handle(net, "to_graph")
    lib = getfield(h, :lib)
    _ensure_dist_compatible(lib)
    _exports_symbol(:pio_multiconductor_network_graph_json, lib) || error(
        "PowerIO.to_graph: the C ABI at \"$lib\" does not export " *
        "pio_multiconductor_network_graph_json. Update the powerio-capi artifact or local library.")
    err = zeros(UInt8, _ERRLEN)
    s = GC.@preserve h ccall(_library_symbol(lib, :pio_multiconductor_network_graph_json), Cstring,
                             (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
                             h.ptr, err, length(err))
    s == C_NULL && error("PowerIO.to_graph: " * _cstr(err))
    text = _take_string(lib, s)
    return JSON3.read(text)
end
