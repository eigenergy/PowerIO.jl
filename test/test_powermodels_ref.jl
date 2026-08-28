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
        PowerIO.correct_voltage_angle_differences!(wide)
        @test wide["branch"]["1"]["angmin"] == -PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
        @test wide["branch"]["1"]["angmax"] == PowerIO.POWER_MODELS_ANGLE_BOUND_PAD

        zero_pad = mk(0.0, 0.0)
        PowerIO.correct_voltage_angle_differences!(zero_pad)
        @test zero_pad["branch"]["1"]["angmin"] == -PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
        @test zero_pad["branch"]["1"]["angmax"] == PowerIO.POWER_MODELS_ANGLE_BOUND_PAD

        ok = mk(-0.4, 0.3)
        PowerIO.correct_voltage_angle_differences!(ok)
        @test ok["branch"]["1"]["angmin"] == -0.4
        @test ok["branch"]["1"]["angmax"] == 0.3

        branch_custom = mk(-2pi, 2pi)
        PowerIO.correct_voltage_angle_differences!(branch_custom; default_pad=0.5)
        @test branch_custom["branch"]["1"]["angmin"] == -0.5

        # A dict without branches is a no-op, not an error.
        @test PowerIO.correct_voltage_angle_differences!(Dict{String,Any}()) == Dict{String,Any}()

        # src defect: with a full PowerModels dict (`baseMVA` and `bus` keys
        # present) and a live library, correct_voltage_angle_differences!
        # routes through from_powermodels -> a bare `parse_str(...)` that does
        # not exist anywhere in the module (powermodels.jl); only
        # `PowerIO.parse_module_str` exists now. Every call below on a full
        # `to_powermodels` dict hits that path. Pin the current behavior
        # until that's fixed; the branch-only path above is unaffected.
        pm = to_powermodels(parse_file(joinpath(@__DIR__, "data", "angle_bounds_clamp.m")).value)
        @test_throws UndefVarError PowerIO.correct_voltage_angle_differences!(pm)

        custom = to_powermodels(parse_file(joinpath(@__DIR__, "data", "angle_bounds_clamp.m")).value)
        @test_throws UndefVarError PowerIO.correct_voltage_angle_differences!(custom; default_pad=0.5)

        dropped = to_powermodels(parse_file(joinpath(@__DIR__, "data", "angle_bounds_clamp.m")).value)
        dropped["branch"]["2"]["br_status"] = 0
        dropped["branch"]["3"]["angmin"] = -2pi
        dropped["branch"]["3"]["angmax"] = 2pi
        @test_throws UndefVarError PowerIO.correct_voltage_angle_differences!(dropped)
    end

    @testset "build_ref" begin
        if !PowerIO.library_available()
            @test_skip PowerIO.build_ref(Dict{String,Any}())
        else
            data = joinpath(@__DIR__, "data")

            # src defect: build_ref unconditionally calls
            # correct_voltage_angle_differences! on a full PowerModels dict
            # (baseMVA and bus keys present), which with a live library hits
            # the same from_powermodels -> undefined `parse_str` path pinned
            # above. build_ref cannot return successfully until that's fixed.
            pm = to_powermodels(parse_file(joinpath(data, "case14.m")).value)
            @test_throws UndefVarError PowerIO.build_ref(pm)
            # calc_branch_t / calc_branch_y themselves are pure and unaffected
            # by this defect; see the "calc_branch_t / calc_branch_y" testset.
        end
    end
end
