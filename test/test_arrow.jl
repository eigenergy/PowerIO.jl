@testset "Arrow export (copy-out default + zero-copy opt-in)" begin
    if !(PowerIO.library_available() && PowerIO.arrow_available())
        @test_skip to_arrow("case14.m", :bus)
    else
        data = joinpath(@__DIR__, "data")
        m = joinpath(data, "case14.m")

        # Default copy=true: a NamedTuple of owned Julia Vectors, no ArrowTable.
        bus = to_arrow(m, :bus)
        @test bus isa NamedTuple
        @test bus.id isa Vector{Int64}
        @test bus.id == collect(1:14)                   # external 1-based bus ids, in order
        # Owned: mutating a returned column can't touch the producer (already
        # freed); a fresh export is unaffected, and GC after release is safe.
        bus.id[1] = -999
        GC.gc()
        @test to_arrow(m, :bus).id[1] == 1
        @test bus.id[2] == 2

        # The Arrow gen table matches the dense extractor on the shared columns.
        d = to_dense(m)
        gen = to_arrow(m, :gen)
        @test gen.bus == d.gen.bus
        @test gen.pg ≈ d.gen.pg

        function optional_arrow(table)
            try
                return to_arrow(m, table)
            catch e
                if occursin("does not support table", sprint(showerror, e))
                    return nothing
                end
                rethrow()
            end
        end

        # Every raw table's row count matches the JSON view's element count.
        net = parse_file(m)
        @test length(to_arrow(m, :shunt).bus) == length(PowerIO.shunts(net))
        @test length(to_arrow(m, :branch).from) == length(PowerIO.branches(net))
        switch = optional_arrow(:switch)
        if switch === nothing
            @test_skip to_arrow(m, :switch)
        else
            @test isempty(switch.from)
        end

        # Normalized solver tables use dense 0-based indices and per unit/radian values.
        solver_bus = optional_arrow(:solver_bus)
        if solver_bus === nothing
            @test_skip to_arrow(m, :solver_bus)
        else
            @test solver_bus.index == collect(0:13)
            @test solver_bus.bus_id == collect(1:14)
            @test solver_bus.source_row[2] == 1
            @test solver_bus.pd[2] ≈ 21.7 / 100.0
            @test solver_bus.is_reference[1] == 0x01

            solver_branch = to_arrow(m, :solver_branch)
            @test length(solver_branch.index) == 20
            @test solver_branch.from_bus_index[1] == 0
            @test solver_branch.to_bus_index[1] == 1

            solver_arc = to_arrow(m, :solver_arc)
            @test length(solver_arc.index) == 40
            @test solver_arc.branch_index[1:2] == [0, 0]
            @test solver_arc.terminal[1:2] == [0, 1]

            solver_gen = to_arrow(m, :solver_gen)
            @test solver_gen.bus_index == [0, 1, 2, 5, 7]
            @test isempty(to_arrow(m, :solver_storage).index)
            @test isempty(to_arrow(m, :solver_hvdc).index)
            @test isempty(to_arrow(m, :solver_switch).index)
        end

        # The BalancedNetwork-first method matches the path method.
        @test to_arrow(net, :bus).id == collect(1:14)

        @test_throws ArgumentError to_arrow(m, :nonesuch)

        # copy=false: the zero-copy ArrowTable path, same values. A column
        # extracted from the table roots the shared buffers on its own, so
        # it survives the table being collected (the old footgun).
        z = to_arrow(m, :bus; copy=false)
        @test z isa ArrowTable
        @test z.id == collect(1:14)
        @test z.id isa PowerIO.ArrowColumn{Int64}
        @test PowerIO.columns(z) isa NamedTuple
        # The raw unsafe_wrap view must not escape its rooting wrapper.
        @test_throws ErrorException z.id.data
        @test collect(z.id) isa Vector{Int64}
        col = z.id
        z = nothing
        GC.gc(); GC.gc()
        @test col == collect(1:14)
        col = nothing
        GC.gc()

        # close releases the producer eagerly: both release callbacks NULL
        # themselves, so a second close (and the later GC finalize) is a
        # no-op. finalize(table) stays a legal no-op for 0.1.0 callers; the
        # buffers free once the columns drop too.
        z2 = to_arrow(m, :bus; copy=false)
        b = getfield(z2, :_buffers)
        @test b.array[].release != C_NULL
        close(z2)
        @test b.array[].release == C_NULL
        @test b.schema[].release == C_NULL
        close(z2)
        finalize(z2)
        @test true
    end
end
