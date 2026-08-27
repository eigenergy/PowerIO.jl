@testset "gridfm reader (feature-gated)" begin
    if !(PowerIO.library_available() && PowerIO.gridfm_available())
        @test_skip read_gridfm("case14_gridfm/raw")
    else
        data = joinpath(@__DIR__, "data")
        single = joinpath(data, "case14_gridfm", "raw")

        # Read one scenario back into a BalancedNetwork: counts, base_mva, and
        # source_format match the source, and the lossy read reports warnings.
        r = read_gridfm(single)
        @test r.network isa BalancedNetwork
        @test r.scenario == 0
        @test r.warnings isa Vector{String}
        @test !isempty(r.warnings)
        # The lossy read's warnings attach to the handle (v4 pio_warnings), not
        # a per-call buffer: the synthesized-bus-ids note is the signature one.
        @test any(w -> occursin("synthesized bus ids", w), r.warnings)
        @test PowerIO.n_buses(r.network) == 14
        @test PowerIO.n_branches(r.network) == 20
        @test PowerIO.n_gens(r.network) == 5
        @test PowerIO.base_mva(r.network) == 100.0
        @test PowerIO.source_format(r.network) == "gridfm"

        # The recovered case carries a live handle: it serializes and re-parses.
        text = to_matpower(r.network)
        @test occursin("mpc.bus", text)
        @test PowerIO.n_buses(PowerIO.parse(IOBuffer(text); from="matpower", value_type=BalancedNetwork)) == 14

        # The NamedTuple is positionally unpackable, mirroring Python's GridfmRead.
        net, scen, warns = read_gridfm(single)
        @test net isa BalancedNetwork
        @test scen == 0
        @test warns isa Vector{String}

        # A batch dataset rebuilds one BalancedNetwork per scenario id, ascending; a
        # specific scenario can be selected.
        batch = joinpath(data, "case14_gridfm_batch", "raw")
        reads = read_gridfm_scenarios(batch)
        @test [x.scenario for x in reads] == [0, 1]
        @test all(x -> PowerIO.n_buses(x.network) == 14, reads)
        @test read_gridfm(batch; scenario = 1).scenario == 1

        # A nonexistent dataset directory returns a Julia error, not a fault.
        @test_throws ErrorException read_gridfm(joinpath(data, "no_such_gridfm"))
    end
end
