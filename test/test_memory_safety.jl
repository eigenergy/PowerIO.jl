@testset "memory safety guards" begin
    if !PowerIO.library_available()
        @test_skip PowerIO.parse("case14.m"; value_type=BalancedNetwork)
    else
        data = joinpath(@__DIR__, "data")
        m = joinpath(data, "case14.m")

        @testset "live handles keep their allocating library" begin
            net = PowerIO.parse(m; value_type=BalancedNetwork)
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
                net = PowerIO.parse(m; value_type=BalancedNetwork)
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

        @testset "finalize before first data access" begin
            # `data` is lazy: reading it after the handle is finalized re-materializes
            # through a freed handle, so the data-backed accessors must raise a clear
            # "finalized" error rather than a confusing "reparse it" one or a segfault.
            net = PowerIO.parse(m; value_type=BalancedNetwork)
            @test getfield(net, :data) === nothing
            finalize(getfield(net, :handle))
            @test_throws ErrorException net.data
            err = try; net.data; catch e; e; end
            @test occursin("finalized", sprint(showerror, err))
            @test_throws ErrorException PowerIO.n_buses(net)
            @test_throws ErrorException to_json(net)
            @test_throws ErrorException sprint(show, net)
            # `warnings` reads only the handle (never `data`), so a finalized handle
            # yields an empty list, not an error.
            @test PowerIO.warnings(net) == String[]

            # Finalizing *after* the first access leaves `data` cached, so the
            # payload-backed reads keep working.
            net2 = PowerIO.parse(m; value_type=BalancedNetwork)
            n = PowerIO.n_buses(net2)
            cached = net2.data
            finalize(getfield(net2, :handle))
            @test PowerIO.n_buses(net2) == n
            @test net2.data === cached
            @test JSON3.read(to_json(net2)) isa JSON3.Object
        end

        if PowerIO.dist_available()
            @testset "multiconductor finalize before first data access" begin
                # Same lazy-data contract as BalancedNetwork; the error must name
                # the finalized case identically for consistency.
                dss = joinpath(data, "dist", "switch.dss")
                if isfile(dss)
                    dn = PowerIO.parse_file(MulticonductorNetwork, dss)
                    finalize(getfield(dn, :handle))
                    @test_throws ErrorException dn.data
                    derr = try; dn.data; catch e; e; end
                    @test occursin("finalized", sprint(showerror, derr))
                end
            end
        end
    end
end
