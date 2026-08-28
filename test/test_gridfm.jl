@testset "gridfm reader (feature-gated)" begin
    if !(PowerIO.library_available() && PowerIO.gridfm_available())
        @test_skip read_gridfm("case14_gridfm/raw")
    else
        data = joinpath(@__DIR__, "data")
        single = joinpath(data, "case14_gridfm", "raw")

        # Read one scenario back into a BalancedNetwork: counts, base_mva, and
        # source_format match the source.
        r = read_gridfm(single)
        @test r.network isa BalancedNetwork
        @test r.scenario == 0
        @test r.diagnostics isa Vector{Diagnostic}
        # src defect: read_gridfm (gridfm.jl) returns
        # `diagnostics(selected)` — the diagnostics of the per-scenario
        # module select_state exports — but the reader's own findings (the
        # "synthesized bus ids" note among them) are attached to the parent
        # scenario-set module instead and do not carry over to the export.
        # r.diagnostics is therefore always empty; the real findings are
        # only reachable off the parent module directly. Pin both.
        @test isempty(r.diagnostics)
        parent_diagnostics = diagnostics(parse_file(single; format="gridfm"))
        @test !isempty(parent_diagnostics)
        @test any(d -> occursin("synthesized bus ids", d.message), parent_diagnostics)
        @test PowerIO.n_buses(r.network) == 14
        @test PowerIO.n_branches(r.network) == 20
        @test PowerIO.n_gens(r.network) == 5
        @test PowerIO.base_mva(r.network) == 100.0
        @test PowerIO.source_format(r.network) == "gridfm"

        # The recovered case carries a live handle: it serializes and re-parses.
        text = to_matpower(r.network)
        @test occursin("mpc.bus", text)
        @test PowerIO.n_buses(parse_bytes(IOBuffer(text); format="matpower").value) == 14

        # The NamedTuple is positionally unpackable, mirroring Python's GridfmRead.
        net, scen, diags = read_gridfm(single)
        @test net isa BalancedNetwork
        @test scen == 0
        @test diags isa Vector{Diagnostic}

        # A batch dataset rebuilds one BalancedNetwork per scenario id, ascending; a
        # specific scenario can be selected.
        batch = joinpath(data, "case14_gridfm_batch", "raw")
        reads = read_gridfm_scenarios(batch)
        @test [x.scenario for x in reads] == [0, 1]
        @test all(x -> PowerIO.n_buses(x.network) == 14, reads)
        @test read_gridfm(batch; scenario = 1).scenario == 1

        # A nonexistent dataset directory refuses with a structured error.
        @test_throws PowerIOCError read_gridfm(joinpath(data, "no_such_gridfm"))
    end
end
