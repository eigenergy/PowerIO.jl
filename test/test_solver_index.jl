@testset "normalize pass source rows" begin
    @test PowerIO.source_rows_available() isa Bool

    if !PowerIO.library_available() || !PowerIO.source_rows_available()
        @info "pio_solver_index_json not exported (needs powerio v0.9); skipping"
        @test_skip PowerIO.source_rows(PowerIO.parse_file(joinpath(@__DIR__, "data", "case9.m")))
    else
        case9 = joinpath(@__DIR__, "data", "case9.m")
        net = PowerIO.parse_file(case9)
        rows = PowerIO.source_rows(net)

        @test propertynames(rows) ==
              (:bus, :load, :shunt, :branch, :switch, :generator, :storage, :hvdc)
        for name in propertynames(rows)
            @test getproperty(rows, name) isa Vector{Union{Nothing,Int}}
        end

        # case9 drops nothing, so every table is its own rows, 1-based.
        @test rows.bus == collect(1:9)
        @test rows.branch == collect(1:9)
        @test rows.generator == collect(1:3)
        # The lengths are the normalized ones, which is what makes the vectors
        # usable as a map: one entry per row of the table they describe.
        @test length(rows.bus) == length(PowerIO.to_powerdata(net).bus)
        @test length(rows.generator) == length(PowerIO.to_powerdata(net).gen)
        @test length(rows.branch) == length(PowerIO.to_powerdata(net).branch)

        # norm_tiny is the fixture the normalize pass was written against: an
        # isolated bus, an out-of-service branch, and a branch onto the dropped
        # bus. The surviving rows keep the case's own row numbers rather than
        # being renumbered, which is the whole point of asking.
        tiny = PowerIO.parse_file(joinpath(@__DIR__, "data", "norm_tiny.m"))
        tiny_rows = PowerIO.source_rows(tiny)
        @test tiny_rows.bus == [1, 2, 3]
        @test tiny_rows.branch == [1, 2]
        @test tiny_rows.generator == [1, 2]
        @test length(tiny_rows.bus) == length(PowerIO.to_powerdata(tiny).bus)
        @test length(tiny_rows.branch) == length(PowerIO.to_powerdata(tiny).branch)
        # Bus 8 is in the case and in no normalized row: a gap, not a shift.
        @test length(tiny_rows.bus) == 3
        @test !(4 in tiny_rows.bus)

        # Every entry is a source row or `nothing`; nothing is a sentinel a
        # caller could index with by accident.
        for name in propertynames(tiny_rows), v in getproperty(tiny_rows, name)
            @test v === nothing || v >= 1
        end

        # 1-based, like every other row number this package reports. The gen
        # source row indexes the case's own generator table.
        @test PowerIO.to_powerdata(tiny).gen[1].bus ==
              Int(PowerIO.generators(tiny)[tiny_rows.generator[1]].bus)

        # A network with no live handle cannot answer: the pass runs in Rust.
        detached = PowerIO.from_json(PowerIO.to_json(net))
        finalize(detached.handle)
        @test_throws ErrorException PowerIO.source_rows(detached)
    end
end
