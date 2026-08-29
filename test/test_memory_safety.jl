@testset "memory safety guards" begin
    if !PowerIO.library_available()
        @test_skip parse_file("case14.m").value
    else
        data = joinpath(@__DIR__, "data")
        m = joinpath(data, "case14.m")

        @testset "live handles keep their allocating library" begin
            net = parse_file(m).value
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
                net = parse_file(m).value
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
            net = parse_file(m).value
            @test getfield(net, :data) === nothing
            finalize(getfield(net, :handle))
            @test_throws ErrorException net.data
            err = try; net.data; catch e; e; end
            @test occursin("finalized", sprint(showerror, err))
            @test_throws ErrorException PowerIO.n_buses(net)
            @test_throws ErrorException to_json(net)
            @test_throws ErrorException sprint(show, net)
            # `warnings` reads the live handle, so a finalized handle is a
            # directed error, like the other live reads above.
            @test_throws ErrorException net.warnings

            # Finalizing *after* the first access leaves `data` cached, so the
            # payload-backed reads keep working.
            net2 = parse_file(m).value
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
                    dn = parse_file(dss).value
                    finalize(getfield(dn, :handle))
                    @test_throws ErrorException dn.data
                    derr = try; dn.data; catch e; e; end
                    @test occursin("finalized", sprint(showerror, derr))
                end
            end
        end
    end
end

@testset "free fn resolution is keyed by the exact library passed" begin
    # Two distinct dlopen images of the same build: concurrent resolutions
    # against the two paths must each return the pointer resolved from the
    # path passed on that call, never the other task's.
    primary = PowerIO._lib()
    copy_path = joinpath(mktempdir(), basename(primary))
    cp(primary, copy_path)
    paths = (primary, copy_path)
    results = Vector{Tuple{Ptr{Cvoid},Ptr{Cvoid}}}(undef, 64)
    tasks = [Threads.@spawn begin
                 lib = paths[1 + (i % 2)]
                 got = PowerIO._network_free_fn(lib)
                 want = PowerIO._library_symbol(lib, :pio_balanced_network_release)
                 dist_got = PowerIO._dist_network_free_fn(lib)
                 dist_want = PowerIO._library_symbol(lib, :pio_multiconductor_network_release)
                 results[i] = (got == want ? C_NULL : got,
                               dist_got == dist_want ? C_NULL : dist_got)
             end for i in 1:64]
    foreach(wait, tasks)
    @test all(r -> r == (C_NULL, C_NULL), results)
    rm(dirname(copy_path); recursive=true, force=true)
end
