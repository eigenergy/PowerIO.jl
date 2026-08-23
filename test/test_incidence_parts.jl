@testset "DC incidence parts" begin
    @test PowerIO.incidence_parts_available() isa Bool

    data = joinpath(@__DIR__, "data")

    # The token table is pure Julia, so it is checked whatever the library is.
    @test_throws ArgumentError PowerIO._dc_convention_token(:bogus)
    @test_throws ArgumentError PowerIO._dc_convention_token("paper-pure")
    @test PowerIO._dc_convention_token(:series) == "series"
    @test PowerIO._dc_convention_token(:series_impedance) == "series"
    @test PowerIO._dc_convention_token("Series-Impedance") == "series"
    @test PowerIO._dc_convention_token(:mp) == "matpower"
    @test PowerIO._dc_convention_token(:reactance_only) == "reactance-only"

    if !PowerIO.library_available() || !PowerIO.incidence_parts_available()
        @info "the DC incidence part extractors are not exported (needs powerio v0.9 --features matrix); skipping"
        @test_skip PowerIO.branch_susceptance(PowerIO.parse_file(joinpath(data, "case9.m")))
    else
        net = PowerIO.parse_file(joinpath(data, "case9.m"))
        dense = PowerIO.to_dense(joinpath(data, "case9.m"))

        b = PowerIO.branch_susceptance(net)
        reactance = PowerIO.branch_susceptance(net; convention=:reactance_only)
        @test b isa Vector{Float64}
        @test length(b) == length(dense.branch.x)

        # A positive Laplacian edge weight, which is the sign a consumer
        # negates once knowingly rather than guessing.
        @test all(>(0), b)
        @test all(>(0), reactance)

        # The formula a consumer reimplements today, held to the library's.
        saw_resistive = false
        for k in eachindex(b)
            r, x = dense.branch.r[k], dense.branch.x[k]
            @test b[k] ≈ x / (r^2 + x^2)
            @test reactance[k] ≈ 1 / x
            if r != 0
                saw_resistive = true
                @test b[k] != reactance[k]
            end
        end
        @test saw_resistive

        parts = PowerIO.calc_incidence_parts(net)
        @test propertynames(parts) ==
              (:matrix, :b, :p_shift, :branch_rows, :skipped_zero_impedance, :convention)
        @test parts.convention == "series"
        @test parts.b == b
        @test parts.branch_rows == collect(1:length(b))
        @test isempty(parts.skipped_zero_impedance)
        @test length(parts.p_shift) == length(parts.matrix.idx_to_bus)
        @test all(==(0.0), parts.p_shift)

        # The parts reassemble the library's own matrix. This is the property
        # that makes them worth returning: a consumer differentiating through
        # `B = A' * Diagonal(-b .* sw) * A` gets the same operator the matrix
        # surface would have handed it, with `b` still separable.
        A = parts.matrix.matrix
        B = A * spdiagm(0 => parts.b) * transpose(A)
        Bprime = PowerIO.calc_bprime_matrix(net)
        @test maximum(abs.(Matrix(B) - Matrix(Bprime.matrix))) == 0.0

        # norm_tiny carries a phase shifter (branch 2, 2 degrees) and a tap.
        tiny = PowerIO.parse_file(joinpath(data, "norm_tiny.m"))
        tiny_parts = PowerIO.calc_incidence_parts(tiny)
        @test count(!=(0.0), tiny_parts.p_shift) == 2
        @test abs(sum(tiny_parts.p_shift)) < 1e-9
        # ...and reactance-only carries no shifts at all, by definition.
        @test all(==(0.0),
                  PowerIO.calc_incidence_parts(tiny; convention=:reactance_only).p_shift)
        @test any(!=(0.0),
                  PowerIO.calc_incidence_parts(tiny; convention=:matpower).p_shift)
        # The tap is read by `:matpower` alone, so that convention separates
        # from `:series` on the tapped branch and agrees elsewhere.
        tiny_series = PowerIO.branch_susceptance(tiny)
        tiny_mp = PowerIO.branch_susceptance(tiny; convention=:matpower)
        @test tiny_series != tiny_mp

        # A branch the DC denominator guard drops is in the case, in no column,
        # and named by both vectors, so a consumer rebuilding `B` cannot
        # silently disagree with the library.
        doc = JSON3.read(PowerIO.to_json(net), Dict{String,Any})
        doc["branches"][2]["x"] = 0.0
        zeroed = PowerIO.from_json(JSON3.write(doc))
        gapped = PowerIO.calc_incidence_parts(zeroed)
        @test gapped.skipped_zero_impedance == [2]
        @test length(gapped.b) == length(b) - 1
        @test !(2 in gapped.branch_rows)
        @test gapped.branch_rows == [k for k in 1:length(b) if k != 2]

        # The guard #292 added, which a consumer recomputing the formula
        # outside cannot inherit: `1/Inf` is a finite 0.0, so an infinite
        # reactance would otherwise join the Laplacian as a zero weight edge.
        doc2 = JSON3.read(PowerIO.to_json(net), Dict{String,Any})
        doc2["branches"][3]["x"] = "Infinity"
        poisoned = PowerIO.from_json(JSON3.write(doc2))
        err = try
            PowerIO.branch_susceptance(poisoned; convention=:reactance_only)
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("branch_susceptance", sprint(showerror, err))
        # Every C ABI message reads `CODE: message`.
        @test occursin(": ", sprint(showerror, err))

        # An unknown convention is refused before the ccall.
        @test_throws ArgumentError PowerIO.branch_susceptance(net; convention=:bogus)
        @test_throws ArgumentError PowerIO.calc_incidence_parts(net; convention=:paper)

        # The path methods free the handle they opened.
        @test PowerIO.branch_susceptance(joinpath(data, "case9.m")) == b
        @test PowerIO.calc_incidence_parts(joinpath(data, "case9.m")).branch_rows ==
              parts.branch_rows

        # A network with no live handle cannot answer: the pass runs in Rust.
        detached = PowerIO.from_json(PowerIO.to_json(net))
        finalize(detached.handle)
        @test_throws ErrorException PowerIO.branch_susceptance(detached)
    end
end
