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
        pd = PowerIO.to_powerdata(net)
        @test length(rows.bus) == length(pd.bus)
        @test length(rows.generator) == length(pd.gen)
        @test length(rows.branch) == length(pd.branch)

        # norm_tiny is the fixture the normalize pass was written against: an
        # isolated bus, an out-of-service branch, and a branch onto the dropped
        # bus. What it pins is which rows survive and how many — every row it
        # drops is the last of its table, so `[1,2,3]` and `[1,2]` are equally
        # what a renumbering would produce.
        tiny = PowerIO.parse_file(joinpath(@__DIR__, "data", "norm_tiny.m"))
        tiny_rows = PowerIO.source_rows(tiny)
        tiny_pd = PowerIO.to_powerdata(tiny)
        @test tiny_rows.bus == [1, 2, 3]
        @test tiny_rows.branch == [1, 2]
        @test tiny_rows.generator == [1, 2]
        @test length(tiny_rows.bus) == length(tiny_pd.bus)
        @test length(tiny_rows.branch) == length(tiny_pd.branch)

        # A dropped row leaves a gap; the rows after it keep the numbers the
        # case gave them. That is the whole point of asking, and no fixture
        # above separates it from a renumbering — it takes a case that drops an
        # *interior* row, which case9 with branch 4 out of service is. A
        # renumbering answers `1:8` here.
        doc = JSON3.read(PowerIO.to_json(net), Dict{String,Any})
        doc["branches"][4]["in_service"] = false
        gapped_rows = PowerIO.source_rows(PowerIO.from_json(JSON3.write(doc)))
        @test gapped_rows.branch == [1, 2, 3, 5, 6, 7, 8, 9]

        # `to_dense` is a *different* row space and these vectors do not index
        # it: its tables are the handle's parse-time core, which still holds
        # the isolated bus and the out-of-service branch the pass drops. Pinned
        # on the one fixture where they disagree, so the alignment cannot be
        # re-derived from case9, where nothing is dropped and they coincide.
        @test length(PowerIO.to_dense(tiny).bus_ids) == 4
        @test length(tiny_rows.bus) != length(PowerIO.to_dense(tiny).bus_ids)

        # Every entry is a source row or `nothing`; nothing is a sentinel a
        # caller could index with by accident.
        for name in propertynames(tiny_rows), v in getproperty(tiny_rows, name)
            @test v === nothing || v >= 1
        end

        # 1-based, like every other row number this package reports. The gen
        # source row indexes the case's own generator table.
        @test tiny_pd.gen[1].bus ==
              Int(PowerIO.generators(tiny)[tiny_rows.generator[1]].bus)

        # The ccall and the string free both go to the library that allocated
        # the handle, not to `_lib()`. `set_library!` can swap the configured
        # build while this network is alive, and reading its pointer through
        # another build is a type confusion the integer ABI handshake cannot
        # see; freeing the returned document through another allocator is worse
        # still. A path that cannot be opened makes the difference observable
        # without a second real build.
        try
            PowerIO.set_library!("/nonexistent/libpowerio_capi.so")
            @test PowerIO.source_rows(net).bus == collect(1:9)
        finally
            PowerIO.clear_library!()
        end

        # A network with no live handle cannot answer: the pass runs in Rust.
        detached = PowerIO.from_json(PowerIO.to_json(net))
        finalize(detached.handle)
        @test_throws ErrorException PowerIO.source_rows(detached)
    end
end
