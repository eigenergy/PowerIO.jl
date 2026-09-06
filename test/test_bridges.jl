# Minimal whitespace delimited writer so the test needs no DelimitedFiles dependency.
function writedlm_ws(path, m::AbstractMatrix)
    open(path, "w") do io
        for i in axes(m, 1)
            println(io, join((string(m[i, j]) for j in axes(m, 2)), " "))
        end
    end
end

@testset "bridges" begin
    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        m = parse(fixture("case14.m"))
        net = m.value

        @testset "PowerModels" begin
            data = to_powermodels(m)
            @test data isa Dict{String,Any}
            @test data["baseMVA"] == 100.0
            @test Set(keys(data["bus"])) == Set(string.(1:14))
            @test length(data["gen"]) == 5
            @test length(data["branch"]) == 20
            @test data["bus"]["1"]["bus_type"] == 3
            @test to_powermodels(net) == data
            reached_through_module_only = parse(fixture("pypsa", "series")).value[1]
            @test_throws ArgumentError to_powermodels(reached_through_module_only)

            back = from_powermodels(data)
            @test back isa PioModule{BalancedNetwork}
            @test length(back.value.buses) == 14
            @test to_powermodels(back) == data
            @test from_powermodels(JSON3.write(data)) isa PioModule{BalancedNetwork}

            ref = build_powermodels_ref(data)
            @test Set(keys(ref)) == Set([:baseMVA, :bus, :gen, :branch, :load, :shunt, :arcs_from, :arcs_to,
                                         :arcs, :bus_arcs, :bus_gens, :bus_loads, :bus_shunts, :ref_buses])
            @test ref[:baseMVA] == 100.0
            @test length(ref[:bus]) == 14 && length(ref[:branch]) == 20
            @test length(ref[:arcs]) == 40
            @test keys(ref[:ref_buses]) == Set([1])
            @test all(-pi / 2 < br["angmin"] < br["angmax"] < pi / 2 for (_, br) in ref[:branch])
            @test sort(reduce(vcat, values(ref[:bus_gens]))) == 1:5
            # The repair touched copies, not the caller's rows.
            @test data["branch"]["1"]["angmin"] ≈ -2pi
            @test data["branch"]["1"]["angmax"] ≈ 2pi

            repaired = repair_powermodels_angle_bounds!(deepcopy(data))
            @test repaired["branch"]["1"]["angmin"] == -PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
            zero_band = Dict{String,Any}("branch" => Dict{String,Any}("1" => Dict{String,Any}("angmin" => 0.0, "angmax" => 0.0)))
            repair_powermodels_angle_bounds!(zero_band; default_pad=0.5)
            @test zero_band["branch"]["1"]["angmin"] == -0.5 && zero_band["branch"]["1"]["angmax"] == 0.5
            @test PowerIO.calc_branch_t(Dict{String,Any}("tap" => 2.0, "shift" => 0.0)) == (2.0, 0.0)
            @test PowerIO.calc_branch_y(Dict{String,Any}("br_r" => 0.0, "br_x" => 0.5)) == (0.0, -2.0)
            @test PowerIO.calc_branch_y(Dict{String,Any}("br_r" => 0.0, "br_x" => 0.0)) == (0.0, 0.0)
        end

        @testset "ExaModelsPower" begin
            pd = to_powerdata(net)
            @test pd.version == "2"
            @test pd.baseMVA == 100.0
            @test length(pd.bus) == 14 && length(pd.gen) == 5 && length(pd.branch) == 20
            @test length(pd.arc) == 40 && isempty(pd.storage)
            @test [b.bus_i for b in pd.bus] == 1:14
            @test count(b -> b.type == 3, pd.bus) == 1
            @test pd.bus[1].type == 3
            @test pd.bus[2].pd ≈ 21.7 / 100 && pd.bus[2].qd ≈ 12.7 / 100
            @test pd.bus[9].bs ≈ 19.0 / 100
            @test all(b.vmax == 1.06 for b in pd.bus)
            g = pd.gen[1]
            @test g.bus == 1 && g.pg ≈ 2.324 && g.status == 1
            @test g.model_poly && g.n == 3
            @test g.c[1] ≈ 0.0430292599 * 100^2 && g.c[2] ≈ 20.0 * 100 && g.c[3] == 0.0
            br = pd.branch[1]
            @test (br.f_bus, br.t_bus) == (1, 2)
            @test br.tap == 1.0 && br.shift == 0.0
            @test br.b_fr + br.b_to ≈ 0.0528
            @test br.angmin ≈ -2pi && br.angmax ≈ 2pi
            @test br.f_idx == 1 && br.t_idx == 21
            @test br.c5 ≈ br.c7 && br.c6 ≈ br.c8   # unity tap: symmetric terminal terms
            xfmr = pd.branch[8]                     # branch 4-7, tap 0.978
            @test (xfmr.f_bus, xfmr.t_bus) == (4, 7)
            @test xfmr.tap ≈ 0.978
            @test pd.arc[1] == (; i = 1, bus = 1, rate_a = br.rate_a)
            @test pd.arc[21] == (; i = 21, bus = 2, rate_a = br.rate_a)
            @test to_powerdata(m) == pd
            @test to_powerdata(fixture("case14.m")) == pd
            @test to_powerdata(net; T=Float32).baseMVA isa Float32
            @test_throws ArgumentError to_powerdata(fixture("dist", "switch.dss"))

            # Angles are radians throughout the layout (#138); the generator
            # row carries the source cost model (#142).
            @test all(b.va ≈ deg2rad(src.va_degrees) for (b, src) in zip(pd.bus, net.buses))
            @test all(g.model == 2 for g in pd.gen)

            # An out of service row cannot refuse the conversion (#143).
            oos = parse(fixture("oos_cubic_cost.m")).value
            @test !oos.generators[2].in_service
            pdo = to_powerdata(oos)
            @test [g.status for g in pdo.gen] == [1, 0]
            @test pdo.gen[1].model_poly && pdo.gen[1].n == 3
            @test pdo.gen[2].model == 2 && pdo.gen[2].c == (0.0, 0.0, 0.0)
            @test to_powerdata(oos; strict=false).gen[2].status == 0

            # A zero impedance branch follows the DC calculation convention (#140).
            tie = parse(fixture("zero_impedance.m")).value
            err = try
                to_powerdata(tie)
                nothing
            catch e
                e
            end
            @test err isa PowerIOError && err.code == "BUILD.OPERATOR.ZERO_IMPEDANCE"
            # `strict=false` relaxes the field checks, not the zero impedance one.
            @test_throws PowerIOError to_powerdata(tie; strict=false)
            lax = try
                to_powerdata(tie; strict=false)
                nothing
            catch e
                e
            end
            @test lax isa PowerIOError && lax.code == "BUILD.OPERATOR.ZERO_IMPEDANCE"
            opened = to_powerdata(tie; zero_impedance=:open)
            @test opened.branch[1].c1 == 0.0 && opened.branch[1].c3 == 0.0
            @test opened.branch[1].c6 ≈ 0.01 && opened.branch[1].c8 ≈ 0.01
            @test_throws ArgumentError to_powerdata(tie; zero_impedance=:drop)

            ac = to_ac_power_data(net)
            @test ac.baseMVA == [100.0]
            @test ac.ref_buses == [1]
            @test length(ac.vmax) == 14 && length(ac.pmax) == 5 && length(ac.angmax) == 20
            @test length(ac.rate_a) == 40
            @test ac.vm0 == [b.vm for b in pd.bus]
            @test ac.pg0[1] ≈ 2.324
            @test isempty(ac.emax)
            @test to_ac_power_data(m) == ac
            @test to_ac_power_data(fixture("case14.m")) == ac
        end

        @testset "LoadSeries" begin
            data = to_ac_power_data(net)
            base = data.baseMVA[]
            base_pd = [b.pd for b in data.bus]
            base_qd = [b.qd for b in data.bus]
            mult = [1.0, 1.1, 0.9]
            pd_mw = (base_pd .* base) * transpose(mult)
            qd_mw = (base_qd .* base) * transpose(mult)

            s = PowerIO.LoadSeries(net, pd_mw, qd_mw)
            @test s isa PowerIO.LoadSeries{Float64}
            @test PowerIO.n_periods(s) == 3
            @test s.bus_ids == 1:14
            @test s.base_mva == 100.0
            @test size(s.pd) == (14, 3)
            @test occursin("14 buses, 3 periods", sprint(show, s))
            @test s.pd[:, 1] ≈ base_pd atol = 1e-10
            @test s.pd[:, 2] ≈ 1.1 .* base_pd atol = 1e-10
            @test s.qd[:, 3] ≈ 0.9 .* base_qd atol = 1e-10
            mw = PowerIO.demands_mw(s)
            @test mw.pd ≈ pd_mw atol = 1e-8
            @test mw.qd ≈ qd_mw atol = 1e-8

            curve = PowerIO.LoadSeries(net, mult)
            @test curve.pd ≈ s.pd atol = 1e-10
            @test curve.qd ≈ s.qd atol = 1e-10
            @test PowerIO.LoadSeries(net, mult; T=Float32) isa PowerIO.LoadSeries{Float32}
            @test_throws ArgumentError PowerIO.LoadSeries(net, Float64[])
            @test_throws ArgumentError PowerIO.LoadSeries(net, [1.0, Inf])

            by_id_pd = Dict(id => pd_mw[k, :] for (k, id) in enumerate(s.bus_ids))
            by_id_qd = Dict(id => qd_mw[k, :] for (k, id) in enumerate(s.bus_ids))
            tabled = PowerIO.LoadSeries(net, by_id_pd, by_id_qd)
            @test tabled.pd ≈ s.pd atol = 1e-10
            missing_bus = delete!(copy(by_id_pd), 14)
            @test_throws ArgumentError PowerIO.LoadSeries(net, missing_bus, by_id_qd)
            ragged = copy(by_id_pd)
            ragged[14] = ragged[14][1:2]
            @test_throws DimensionMismatch PowerIO.LoadSeries(net, ragged, by_id_qd)

            @test_throws DimensionMismatch PowerIO.LoadSeries(net, pd_mw[1:13, :], qd_mw[1:13, :])
            @test_throws DimensionMismatch PowerIO.LoadSeries(net, pd_mw, qd_mw[:, 1:2])
            bad = copy(pd_mw)
            bad[1, 1] = NaN
            @test_throws ArgumentError PowerIO.LoadSeries(net, bad, qd_mw)

            mktempdir() do dir
                pd_path = joinpath(dir, "case14.Pd")
                qd_path = joinpath(dir, "case14.Qd")
                writedlm_ws(pd_path, pd_mw)
                writedlm_ws(qd_path, qd_mw)
                read_back = PowerIO.read_load_series(net, pd_path, qd_path)
                @test read_back.pd ≈ s.pd atol = 1e-10
                @test read_back.qd ≈ s.qd atol = 1e-10
                @test_throws ArgumentError PowerIO.read_load_series(net, joinpath(dir, "missing"), qd_path)
                short = joinpath(dir, "short.Pd")
                writedlm_ws(short, pd_mw[1:13, :])
                @test_throws DimensionMismatch PowerIO.read_load_series(net, short, qd_path)
                ragged_path = joinpath(dir, "ragged.Pd")
                write(ragged_path, "1 2 3\n4 5\n")
                @test_throws DimensionMismatch PowerIO.read_load_series(net, ragged_path, qd_path)
            end
        end
    end
end
