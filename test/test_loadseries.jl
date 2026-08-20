# minimal whitespace-delimited writer so the test needs no DelimitedFiles dep
function writedlm_ws(path, m::AbstractMatrix)
    open(path, "w") do io
        for i in axes(m, 1)
            println(io, join((string(m[i, j]) for j in axes(m, 2)), " "))
        end
    end
end

@testset "LoadSeries" begin
    if !PowerIO.library_available()
        @test_skip PowerIO.LoadSeries(parse_file("case14.m"), [1.0])
    else
        m = joinpath(@__DIR__, "data", "case14.m")
        net = parse_file(m)
        data = parse_ac_power_data(net)
        base = data.baseMVA[]
        base_pd = [b.pd for b in data.bus]      # per unit
        base_qd = [b.qd for b in data.bus]
        mult = [1.0, 1.1, 0.9]
        pd_mw = (base_pd .* base) * transpose(mult)   # 14 × 3, MW
        qd_mw = (base_qd .* base) * transpose(mult)

        s = PowerIO.LoadSeries(net, pd_mw, qd_mw)
        @test s isa PowerIO.LoadSeries{Float64}
        @test PowerIO.n_periods(s) == 3
        @test PowerIO.n_buses(s) == 14
        @test s.bus_ids == collect(1:14)         # alignment recorded
        @test s.base_mva == 100.0
        @test size(s.pd) == (14, 3)
        @test occursin("14 buses, 3 periods", sprint(show, s))

        # each period is the base per-unit loads times the multiplier
        @test s.pd[:, 1] ≈ base_pd atol = 1e-10
        @test s.pd[:, 2] ≈ 1.1 .* base_pd atol = 1e-10
        @test s.qd[:, 3] ≈ 0.9 .* base_qd atol = 1e-10

        # demands_mw inverts the per-unit conversion for MW interfaces
        mw = demands_mw(s)
        @test mw.pd ≈ pd_mw atol = 1e-8
        @test mw.qd ≈ qd_mw atol = 1e-8

        # the curve constructor is the same series, and scales loads only
        sc = PowerIO.LoadSeries(net, mult)
        @test sc.pd ≈ s.pd
        @test sc.qd ≈ s.qd

        # id-keyed construction matches the positional matrix
        pd_by_id = Dict(id => pd_mw[k, :] for (k, id) in enumerate(s.bus_ids))
        qd_by_id = Dict(id => qd_mw[k, :] for (k, id) in enumerate(s.bus_ids))
        @test PowerIO.LoadSeries(net, pd_by_id, qd_by_id).pd ≈ s.pd

        # validation: clear errors, no silent misalignment
        @test_throws DimensionMismatch PowerIO.LoadSeries(net, pd_mw[1:5, :], qd_mw)
        @test_throws DimensionMismatch PowerIO.LoadSeries(net, pd_mw, qd_mw[:, 1:2])
        bad = copy(pd_mw); bad[1, 1] = NaN
        @test_throws ArgumentError PowerIO.LoadSeries(net, bad, qd_mw)
        @test_throws ArgumentError PowerIO.LoadSeries(net, Float64[])  # empty curve
        # the curve constructor validates finiteness like the matrix path (no silent NaN)
        @test_throws ArgumentError PowerIO.LoadSeries(net, [1.0, NaN, 0.9])
        short_id = Dict(id => pd_mw[k, :] for (k, id) in enumerate(s.bus_ids) if id != 1)
        @test_throws ArgumentError PowerIO.LoadSeries(net, short_id, qd_by_id)

        # the GPU-facing T flows through the id-table build (no Float64 intermediate)
        s32 = PowerIO.LoadSeries(net, pd_by_id, qd_by_id; T=Float32)
        @test s32 isa PowerIO.LoadSeries{Float32}
        @test s32.pd isa Matrix{Float32}
        @test PowerIO.LoadSeries(net, pd_mw, qd_mw, Float32) isa
              PowerIO.LoadSeries{Float32}
        @test PowerIO.LoadSeries(net, mult, Float32) isa PowerIO.LoadSeries{Float32}
        @test PowerIO.LoadSeries(net, pd_by_id, qd_by_id, Float32) isa
              PowerIO.LoadSeries{Float32}
        @test Core.Compiler.return_type(
            PowerIO.LoadSeries,
            Tuple{typeof(net),typeof(pd_mw),typeof(qd_mw),Type{Float32}},
        ) == PowerIO.LoadSeries{Float32}
        @test Core.Compiler.return_type(
            PowerIO.LoadSeries,
            Tuple{typeof(net),typeof(mult),Type{Float32}},
        ) == PowerIO.LoadSeries{Float32}
        @test Core.Compiler.return_type(
            PowerIO.LoadSeries,
            Tuple{typeof(net),typeof(pd_by_id),typeof(qd_by_id),Type{Float32}},
        ) == PowerIO.LoadSeries{Float32}
        # an empty bus set gives a clear error, not a bare "invalid Array dimensions"
        @test_throws ArgumentError PowerIO._matrix_from_id_table(
            Dict{Int,Vector{Float64}}(), Int[], :Pd, Float64)

        # reading the delimited files matches an in-memory build of the same numbers
        dir = mktempdir()
        pdf = joinpath(dir, "load.Pd"); qdf = joinpath(dir, "load.Qd")
        writedlm_ws(pdf, pd_mw); writedlm_ws(qdf, qd_mw)
        sf = PowerIO.read_load_series(net, pdf, qdf)
        @test sf.pd ≈ s.pd
        @test sf.qd ≈ s.qd
        @test PowerIO.read_load_series(net, pdf, qdf, Float32) isa
              PowerIO.LoadSeries{Float32}
        @test Core.Compiler.return_type(
            PowerIO.read_load_series,
            Tuple{typeof(net),typeof(pdf),typeof(qdf),Type{Float32}},
        ) == PowerIO.LoadSeries{Float32}
        @test_throws ArgumentError PowerIO.read_load_series(net, joinpath(dir, "nope.Pd"), qdf)

        # A series aligns to `parse_ac_power_data`'s bus rows. The alignment now
        # comes off the normalized view directly instead of a second
        # `to_powerdata` build, so pin the two against each other on a case with
        # an isolated bus, which normalization drops.
        drops = """
        function mpc = drops
        mpc.baseMVA = 100;
        mpc.bus = [
            1 3 10 4 0 0 1 1 0 138 1 1.1 0.9;
            2 1 20 8 0 0 1 1 0 138 1 1.1 0.9;
            3 4 30 9 0 0 1 1 0 138 1 1.1 0.9;
        ];
        mpc.gen = [
            1 50 0 50 -50 1 100 1 100 0;
        ];
        mpc.branch = [
            1 2 0.01 0.1 0 100 100 100 0 0 1 -30 30;
        ];
        mpc.gencost = [
            2 0 0 3 0.01 20 0;
        ];
        """
        dnet = parse_str(drops, "matpower")
        dref = to_powerdata(dnet)
        dbase, dids, dpd, dqd = PowerIO._load_alignment(dnet, Float64)
        @test dids == Int[b.bus_i for b in dref.bus]
        @test dids == [1, 2]
        @test dpd ≈ Float64[b.pd for b in dref.bus]
        @test dqd ≈ Float64[b.qd for b in dref.bus]
        @test dbase == dref.baseMVA
        @test PowerIO.LoadSeries(dnet, [1.0]).bus_ids == dids
    end
end
