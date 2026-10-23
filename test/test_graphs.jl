@testset "network islands" begin
    @testset "pure connected-components primitive" begin
        # Output follows source bus-table order, not numeric sorting or DFS order.
        bus_ids = [50, 10, 20, 99, 30]
        edges = [(10, 20), (20, 50), (50, 10), (99, 99)]
        @test PowerIO._connected_components(bus_ids, edges) ==
              [[50, 10, 20], [99], [30]]
        @test PowerIO._connected_components(Int[], Tuple{Int,Int}[]) ==
              Vector{Vector{Int}}()
        @test_throws ArgumentError PowerIO._connected_components([1, 1], Tuple{Int,Int}[])
        @test_throws ArgumentError PowerIO._connected_components([1, 2], [(1, 3)])
    end

    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable for network-island integration tests"
    else
        @testset "balanced case and module overload" begin
            m = parse(fixture("case9.m"))
            expected = [Int[b.id for b in m.value.buses]]
            @test network_islands(m.value) == expected
            @test network_islands(m) == expected
            @test network_islands(m.value; include_switches=false) == expected
            @test all(isempty(island) == false for island in network_islands(m.value))
        end

        @testset "in-service three-winding transformers connect winding buses" begin
            net = parse(fixture("psse", "case3_3w_v33.raw")).value
            islands = network_islands(net)
            island_for_bus = Dict(bus_id => i for (i, island) in enumerate(islands)
                                  for bus_id in island)
            @test sort!(vcat(islands...)) == sort!([bus.id for bus in net.buses])
            for transformer in net.transformers_3w
                transformer.in_service || continue
                isempty(transformer.windings) && continue
                first_bus = transformer.windings[1].bus_id
                for winding in transformer.windings
                    @test island_for_bus[winding.bus_id] == island_for_bus[first_bus]
                end
            end
        end
    end
end
