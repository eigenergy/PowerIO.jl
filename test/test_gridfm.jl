@testset "gridfm reader (feature-gated)" begin
    if !(PowerIO.library_available() && PowerIO.gridfm_available())
        @test_skip parse_file("case14_gridfm/raw"; format="gridfm")
    else
        data = joinpath(@__DIR__, "data")
        single = joinpath(data, "case14_gridfm", "raw")

        scenarios = parse_file(single; format="gridfm")
        @test scenarios isa PioModule{ScenarioSet{BalancedNetwork}}
        @test keys(scenarios) == ["0"]
        @test scenarios.diagnostics isa Vector{Diagnostic}
        @test any(d -> occursin("synthesized bus ids", d.message),
                  scenarios.diagnostics)

        selected = scenarios["0"]
        @test selected isa PioModule{BalancedNetwork}
        @test n_buses(selected) == 14
        @test n_branches(selected) == 20
        @test n_generators(selected) == 5
        @test base_mva(selected) == 100.0
        @test source_format(selected) == "gridfm"

        text = emit(selected, "matpower").text
        @test occursin("mpc.bus", text)
        @test n_buses(parse_text(text; name="case14.m", format="matpower")) == 14

        batch = joinpath(data, "case14_gridfm_batch", "raw")
        batch_scenarios = parse_file(batch; format="gridfm")
        @test batch_scenarios isa PioModule{ScenarioSet{BalancedNetwork}}
        @test keys(batch_scenarios) == ["0", "1"]
        @test all(id -> n_buses(batch_scenarios[id]) == 14,
                  keys(batch_scenarios))

        @test_throws PowerIOError parse_file(joinpath(data, "no_such_gridfm");
                                             format="gridfm")
    end
end
