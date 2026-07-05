@testset "memory safety guards" begin
    if !PowerIO.library_available()
        @test_skip parse_file("case14.m")
    else
        data = joinpath(@__DIR__, "data")
        m = joinpath(data, "case14.m")

        @testset "live handles keep their allocating library" begin
            net = parse_file(m)
            bus_ids = to_dense(net).bus_ids
            has_arrow = PowerIO.arrow_available()
            missing_lib = joinpath(mktempdir(), "not-libpowerio_capi.$(Libdl.dlext)")
            PowerIO.set_library!(missing_lib)
            try
                GC.gc(); GC.gc()
                @test to_dense(net).bus_ids == bus_ids
                @test PowerIO.reference_bus_indices(net) == [0]
                @test occursin("mpc.bus", to_matpower(net))
                if has_arrow
                    @test to_arrow(net, :bus).id[1] == 1
                end
            finally
                PowerIO.clear_library!()
            end
            @test PowerIO.library_available()
        end

        @testset "handle access under GC" begin
            for _ in 1:50
                net = parse_file(m)
                d = to_dense(net)
                GC.gc(); GC.gc()
                @test d.n == 14
                @test d.m == 20
                @test PowerIO.n_components(net) >= 1
                json = to_json(net)
                net = nothing
                GC.gc(); GC.gc()
                @test occursin("base_mva", json)
            end
        end

        @testset "Arrow column lifetimes" begin
            if !PowerIO.arrow_available()
                @test_skip to_arrow(m, :bus)
            else
                for _ in 1:20
                    copied = to_arrow(m, :bus)
                    GC.gc(); GC.gc()
                    @test copied.id[1] == 1

                    t = to_arrow(m, :bus; copy=false)
                    col = t.id
                    t = nothing
                    GC.gc(); GC.gc()
                    @test col[1] == 1
                    @test collect(col) == collect(1:14)

                    closed = to_arrow(m, :bus; copy=false)
                    closed_col = closed.id
                    close(closed)
                    @test_throws ErrorException closed_col[1]
                    @test_throws ErrorException collect(closed_col)

                    col = nothing
                    closed_col = nothing
                    GC.gc(); GC.gc()
                end
            end
        end
    end
end
