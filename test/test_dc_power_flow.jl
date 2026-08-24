using SparseArrays

@testset "PowerModels DC definitions" begin
    @test PowerIO.dc_power_flow_available() isa Bool
    data = joinpath(@__DIR__, "data")

    @test_throws ArgumentError PowerIO._dc_convention_token(:bogus)
    @test_throws ArgumentError PowerIO._dc_convention_token(nothing)
    @test_throws ArgumentError PowerIO._dc_convention_token(:paper)
    @test PowerIO._dc_convention_token(:series_impedance) == "series"
    @test PowerIO._dc_convention_token(:reactance_only) == "reactance-only"

    if !PowerIO.library_available() || !PowerIO.matrix_available() ||
       !PowerIO.dc_power_flow_available()
        @info "DC power flow data needs powerio v0.9 --features matrix,arrow; skipping"
        @test_skip PowerIO.DcPowerFlowData(joinpath(data, "case9.m"))
    else
        net = PowerIO.parse_file(joinpath(data, "case9.m"))
        dense = PowerIO.to_dense(net)
        dc = PowerIO.DcPowerFlowData(net)
        A = dc.incidence_matrix.matrix
        b = dc.branch_susceptance

        @test dc.convention == :series
        @test dc.incidence_matrix isa PowerIO.IncidenceMatrix{Float64}
        @test propertynames(dc) ==
              (:incidence_matrix, :branch_susceptance, :phase_shift_injection,
               :branch_rows, :skipped_branch_rows, :convention)
        @test size(A) == (length(dc.branch_rows), length(dc.incidence_matrix.idx_to_bus))
        @test dc.incidence_matrix.branch_rows === dc.branch_rows
        @test dc.branch_rows == collect(1:length(dense.branch.x))
        @test isempty(dc.skipped_branch_rows)

        # PowerModels orientation: branches by buses, +1 from and -1 to.
        for e in axes(A, 1)
            row = dc.branch_rows[e]
            from = dc.incidence_matrix.bus_to_idx[Int(dense.branch.from[row])]
            to = dc.incidence_matrix.bus_to_idx[Int(dense.branch.to[row])]
            @test A[e, from] == 1.0
            @test A[e, to] == -1.0
            @test count(!iszero, A[e, :]) == 2
        end

        # PowerModels branch series definition.
        for e in eachindex(b)
            row = dc.branch_rows[e]
            r, x = dense.branch.r[row], dense.branch.x[row]
            @test b[e] ≈ imag(inv(r + im * x))
        end
        @test PowerIO.branch_susceptance(net) == b

        D = spdiagm(0 => b)
        expected_B = sparse(transpose(A) * D * A)
        expected_Bf = sparse(D * A)
        B = PowerIO.calc_susceptance_matrix(net).matrix
        Bf = PowerIO.calc_branch_susceptance_matrix(net)
        @test B == expected_B
        @test Bf == expected_Bf
        @test Matrix(B) == Matrix(transpose(B))

        va = collect(range(-0.07, 0.05; length=size(A, 2)))
        p_bus = -B * va + dc.phase_shift_injection
        p_branch = -Bf * va
        @test p_branch == -(D * A) * va
        @test p_bus ≈ transpose(A) * p_branch + dc.phase_shift_injection

        # Phase shifts stay outside the symmetric bus susceptance matrix.
        shifted = PowerIO.parse_file(joinpath(data, "norm_tiny.m"))
        shifted_dense = PowerIO.to_dense(shifted)
        shifted_dc = PowerIO.DcPowerFlowData(shifted)
        shifted_A = shifted_dc.incidence_matrix.matrix
        shift = [deg2rad(shifted_dense.branch.shift[row]) for row in shifted_dc.branch_rows]
        @test shifted_dc.phase_shift_injection ≈
              transpose(shifted_A) * (shifted_dc.branch_susceptance .* shift)
        shifted_B = PowerIO.calc_susceptance_matrix(shifted).matrix
        @test Matrix(shifted_B) == Matrix(transpose(shifted_B))
        @test any(!iszero, shifted_dc.phase_shift_injection)
        @test all(iszero,
                  PowerIO.DcPowerFlowData(shifted; convention=:reactance_only).
                      phase_shift_injection)

        # The other formulas include the effective tap only where specified.
        matpower = PowerIO.DcPowerFlowData(shifted; convention=:matpower)
        reactance = PowerIO.DcPowerFlowData(shifted; convention=:reactance_only)
        for e in eachindex(matpower.branch_susceptance)
            row = matpower.branch_rows[e]
            x = shifted_dense.branch.x[row]
            tap = shifted_dense.branch.tap[row] == 0 ? 1.0 : shifted_dense.branch.tap[row]
            @test matpower.branch_susceptance[e] ≈ -1 / (x * tap)
            @test reactance.branch_susceptance[e] ≈ -1 / x
        end

        # Negative reactance reverses the ordinary sign.
        doc = JSON3.read(PowerIO.to_json(net), Dict{String,Any})
        doc["branches"][1]["x"] = -abs(dense.branch.x[1])
        negative_x = PowerIO.from_json(JSON3.write(doc))
        negative_dc = PowerIO.DcPowerFlowData(negative_x)
        first_row = findfirst(==(1), negative_dc.branch_rows)
        @test first_row !== nothing
        @test negative_dc.branch_susceptance[first_row] > 0
        @test negative_dc.branch_susceptance[first_row] ≈
              imag(inv(dense.branch.r[1] - im * abs(dense.branch.x[1])))

        # A skipped row is named and absent from A and b.
        doc["branches"][2]["x"] = 0.0
        skipped = PowerIO.DcPowerFlowData(PowerIO.from_json(JSON3.write(doc)))
        @test skipped.skipped_branch_rows == [2]
        @test !(2 in skipped.branch_rows)
        @test size(skipped.incidence_matrix.matrix, 1) == length(skipped.branch_susceptance)

        @test PowerIO.DcPowerFlowData(joinpath(data, "case9.m")).branch_rows == dc.branch_rows
        @test PowerIO.calc_incidence_matrix(net).matrix == A

        detached = PowerIO.from_json(PowerIO.to_json(net))
        finalize(detached.handle)
        @test_throws ErrorException PowerIO.DcPowerFlowData(detached)
    end
end
