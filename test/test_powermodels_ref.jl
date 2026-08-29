@testset "PowerModels reference utilities" begin
    # Pure parts first: no binary needed.
    @testset "calc_branch_t / calc_branch_y" begin
        branch = Dict{String,Any}("br_r" => 0.01938, "br_x" => 0.05917,
                                  "tap" => 1.0, "shift" => 0.0)
        g, b = PowerIO.calc_branch_y(branch)
        y = inv(complex(0.01938, 0.05917))
        @test g ≈ real(y)
        @test b ≈ imag(y)

        # Zero impedance takes the scalar pseudo-inverse convention: (0, 0).
        @test PowerIO.calc_branch_y(Dict{String,Any}("br_r" => 0.0, "br_x" => 0.0)) == (0.0, 0.0)

        tr, ti = PowerIO.calc_branch_t(Dict{String,Any}("tap" => 0.98, "shift" => pi / 6))
        @test tr ≈ 0.98 * cos(pi / 6)
        @test ti ≈ 0.98 * sin(pi / 6)
    end

    @testset "correct_voltage_angle_differences!" begin
        mk(angmin, angmax) = Dict{String,Any}(
            "branch" => Dict{String,Any}(
                "1" => Dict{String,Any}("angmin" => angmin, "angmax" => angmax)))

        # Branch-only callers keep the PowerModels helper semantics.
        wide = mk(-2pi, 2pi)
        repair_powermodels_angle_bounds!(wide)
        @test wide["branch"]["1"]["angmin"] == -PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
        @test wide["branch"]["1"]["angmax"] == PowerIO.POWER_MODELS_ANGLE_BOUND_PAD

        zero_pad = mk(0.0, 0.0)
        repair_powermodels_angle_bounds!(zero_pad)
        @test zero_pad["branch"]["1"]["angmin"] == -PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
        @test zero_pad["branch"]["1"]["angmax"] == PowerIO.POWER_MODELS_ANGLE_BOUND_PAD

        ok = mk(-0.4, 0.3)
        repair_powermodels_angle_bounds!(ok)
        @test ok["branch"]["1"]["angmin"] == -0.4
        @test ok["branch"]["1"]["angmax"] == 0.3

        branch_custom = mk(-2pi, 2pi)
        repair_powermodels_angle_bounds!(branch_custom; default_pad=0.5)
        @test branch_custom["branch"]["1"]["angmin"] == -0.5

        # A dict without branches is a no-op, not an error.
        @test repair_powermodels_angle_bounds!(Dict{String,Any}()) == Dict{String,Any}()

        pm = to_powermodels(parse_file(joinpath(@__DIR__, "data", "angle_bounds_clamp.m")).value)
        repair_powermodels_angle_bounds!(pm)
        @test pm["branch"]["1"]["angmin"] == -PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
        @test pm["branch"]["1"]["angmax"] == PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
        @test pm["branch"]["2"]["angmin"] == -PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
        @test pm["branch"]["2"]["angmax"] == PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
        @test pm["branch"]["3"]["angmin"] ≈ -pi / 6
        @test pm["branch"]["3"]["angmax"] ≈ pi / 6

        custom = to_powermodels(parse_file(joinpath(@__DIR__, "data", "angle_bounds_clamp.m")).value)
        repair_powermodels_angle_bounds!(custom; default_pad=0.5)
        @test custom["branch"]["1"]["angmin"] == -0.5
        @test custom["branch"]["1"]["angmax"] == 0.5

        dropped = to_powermodels(parse_file(joinpath(@__DIR__, "data", "angle_bounds_clamp.m")).value)
        dropped["branch"]["2"]["br_status"] = 0
        dropped["branch"]["3"]["angmin"] = -2pi
        dropped["branch"]["3"]["angmax"] = 2pi
        repair_powermodels_angle_bounds!(dropped)
        @test dropped["branch"]["1"]["angmin"] == -PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
        @test dropped["branch"]["2"]["angmin"] == -PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
        @test dropped["branch"]["3"]["angmin"] == -PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
    end

    @testset "build_ref" begin
        if !PowerIO.library_available()
            @test_skip PowerIO.build_ref(Dict{String,Any}())
        else
            data = joinpath(@__DIR__, "data")

            # case14 through to_powermodels: counts, arcs, slack, adjacency.
            pm = to_powermodels(parse_file(joinpath(data, "case14.m")).value)
            ref = build_powermodels_ref(pm)
            @test length(ref[:bus]) == 14
            @test length(ref[:gen]) == 5
            @test length(ref[:branch]) == 20
            @test length(ref[:load]) == 11
            @test length(ref[:shunt]) == 1
            @test length(ref[:arcs_from]) == 20
            @test length(ref[:arcs]) == 40
            @test collect(keys(ref[:ref_buses])) == [1]
            @test ref[:baseMVA] == 100.0
            @test sort(ref[:bus_gens][1]) isa Vector{Int}
            @test sum(length, values(ref[:bus_arcs])) == 40
            @test sum(length, values(ref[:bus_loads])) == 11

            # case14 ships ±360° bounds, so every surviving branch clamps on
            # the ref copies, never on the input dict.
            @test all(br["angmin"] == -1.0472 && br["angmax"] == 1.0472
                      for (_, br) in ref[:branch])
            @test pm["branch"]["1"]["angmin"] ≈ -2pi
            # Rows of the other tables are shared with the input, not copied.
            @test ref[:bus][1] === pm["bus"]["1"]

            # norm_tiny: bus 8 is ISOLATED (bus_type 4) and two branches are
            # out of service or dangle onto the dropped bus; the ref filters
            # all of them and keeps the non-contiguous source ids.
            tiny = build_powermodels_ref(to_powermodels(parse_file(joinpath(data, "norm_tiny.m")).value))
            @test sort(collect(keys(tiny[:bus]))) == [1, 3, 5]
            @test length(tiny[:branch]) == 2
            @test all(br["f_bus"] in keys(tiny[:bus]) && br["t_bus"] in keys(tiny[:bus])
                      for (_, br) in tiny[:branch])

            # Every branch in the ref feeds the calc helpers.
            for (_, br) in ref[:branch]
                g, b = PowerIO.calc_branch_y(br)
                @test isfinite(g) && isfinite(b)
                tr, ti = PowerIO.calc_branch_t(br)
                @test isfinite(tr) && isfinite(ti)
            end
        end
    end
end
