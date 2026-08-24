@testset "DC incidence parts" begin
    @test PowerIO.incidence_parts_available() isa Bool

    data = joinpath(@__DIR__, "data")

    # The token table is pure Julia, so it is checked whatever the library is.
    @test_throws ArgumentError PowerIO._dc_convention_token(:bogus)
    @test PowerIO._dc_convention_token(:series) == "series"
    @test PowerIO._dc_convention_token(:series_impedance) == "series"
    @test PowerIO._dc_convention_token("Series-Impedance") == "series"
    @test PowerIO._dc_convention_token(:mp) == "matpower"
    @test PowerIO._dc_convention_token(:reactance_only) == "reactance-only"
    # The core deletes both separators rather than folding one into the other,
    # so these three resolve through Python and the CLI and have to resolve
    # here; rewriting `-` to `_` refused them.
    @test PowerIO._dc_convention_token("seriesimpedance") == "series"
    @test PowerIO._dc_convention_token("reactanceonly") == "reactance-only"
    @test PowerIO._dc_convention_token("REACTANCEONLY") == "reactance-only"

    # `nothing` is how this package spells "the default" for `from=`, so it
    # reaches this keyword too. Converting before typing answered it with a
    # `MethodError` naming Base rather than the options.
    @test_throws ArgumentError PowerIO._dc_convention_token(nothing)
    @test_throws ArgumentError PowerIO._dc_convention_token(1)

    # 0.8 spelled `b = 1/x` "paper-pure" and made it the default. The core
    # names the successor rather than resolving it, because the nearest looking
    # option is a different formula; the Julia refusal carries the same hint.
    paper_err = try
        PowerIO._dc_convention_token("paper-pure")
        nothing
    catch e
        e
    end
    @test paper_err isa ArgumentError
    @test occursin("reactance_only", sprint(showerror, paper_err))

    # `calc_incidence_parts` needs `arrow` as well as `matrix` — the matrix
    # crosses as an Arrow table — and `matrix_available()` is the one probe
    # that reports both. Gating on the extractors alone let a `--features
    # matrix` build past the guard and error out mid-testset on `pio_to_arrow`.
    if !PowerIO.library_available() || !PowerIO.matrix_available() ||
       !PowerIO.incidence_parts_available()
        @info "the DC incidence parts need powerio v0.9 --features matrix,arrow; skipping"
        @test_skip PowerIO.branch_susceptance(PowerIO.parse_file(joinpath(data, "case9.m")))
    else
        net = PowerIO.parse_file(joinpath(data, "case9.m"))
        dense = PowerIO.to_dense(joinpath(data, "case9.m"))

        b = PowerIO.branch_susceptance(net)
        reactance = PowerIO.branch_susceptance(net; convention=:reactance_only)
        parts = PowerIO.calc_incidence_parts(net)
        @test b isa Vector{Float64}
        # `b` is in incidence column order, whose length is the column count
        # and not the branch count: an out-of-service branch, a self-loop and a
        # row the DC denominator guard skipped each hold a branch row and no
        # column. case9 has none of the three, so the map is the identity —
        # asserted here rather than assumed, because the formula cross-check
        # below reads the branch table through it.
        @test length(b) == length(parts.branch_rows)
        @test parts.branch_rows == collect(1:length(dense.branch.x))

        # Drift canary for the token table mirrored off `DcConvention::from_token`
        # (powerio/src/dc.rs): every spelling Julia claims has to resolve here,
        # and every token it produces has to be one the C ABI takes.
        for (key, token) in PowerIO._DC_CONVENTIONS
            @test PowerIO._dc_convention_token(key) == token
            @test PowerIO.branch_susceptance(net; convention=key) isa Vector{Float64}
            @test PowerIO.branch_susceptance(net; convention=token) isa Vector{Float64}
        end

        # A positive Laplacian edge weight, which is the sign a consumer
        # negates once knowingly rather than guessing.
        @test all(>(0), b)
        @test all(>(0), reactance)

        # The formula a consumer reimplements today, held to the library's.
        saw_resistive = false
        for k in eachindex(b)
            # Through the column map, not the column index: the two spaces
            # coincide on case9 and nowhere that drops a branch, and reading
            # the branch table at `k` would compare each susceptance against
            # the wrong branch the moment the fixture gains one.
            row = parts.branch_rows[k]
            r, x = dense.branch.r[row], dense.branch.x[row]
            @test b[k] ≈ x / (r^2 + x^2)
            @test reactance[k] ≈ 1 / x
            if r != 0
                saw_resistive = true
                @test b[k] != reactance[k]
            end
        end
        @test saw_resistive

        @test propertynames(parts) ==
              (:matrix, :b, :p_shift, :branch_rows, :skipped_zero_impedance, :convention)
        @test parts.convention == "series"
        @test parts.b == b
        @test isempty(parts.skipped_zero_impedance)
        @test length(parts.p_shift) == length(parts.matrix.idx_to_bus)
        @test all(==(0.0), parts.p_shift)

        # The parts reassemble the library's own matrix. This is the property
        # that makes them worth returning: a consumer differentiating through
        # `B = A * Diagonal(-b .* sw) * A'` gets the same operator the matrix
        # surface would have handed it, with `b` still separable. Exactly, and
        # only on a case with no phase shifter — see the norm_tiny block below.
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

        # The shifter is also where the reassembly identity stops holding, so
        # the docs qualify it rather than stating it flat. `B'` is the fast
        # decoupled matrix and keeps the shift in the off diagonal, which makes
        # it asymmetric; the parts route the same shift into `p_shift` and
        # leave `A * Diagonal(b) * A'` symmetric by construction.
        tiny_A = tiny_parts.matrix.matrix
        tiny_L = tiny_A * spdiagm(0 => tiny_parts.b) * transpose(tiny_A)
        tiny_Bp = PowerIO.calc_bprime_matrix(tiny).matrix
        @test maximum(abs.(Matrix(tiny_L) - Matrix(tiny_Bp))) > 1e-3
        @test maximum(abs.(Matrix(tiny_Bp) - Matrix(transpose(tiny_Bp)))) > 1e-3
        @test Matrix(tiny_L) == Matrix(transpose(tiny_L))

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

        # The Arrow incidence table takes no convention over the C ABI: the
        # library builds it under the default `:series`, the only convention
        # that reads the resistance. A nonfinite `r` beside a usable `x` is
        # therefore a case the requested convention carries and `matrix` cannot,
        # and the refusal has to name the convention that did the refusing —
        # a bare `to_arrow` message points at the caller's instead.
        doc3 = JSON3.read(PowerIO.to_json(net), Dict{String,Any})
        doc3["branches"][1]["r"] = "Infinity"
        infinite_r = PowerIO.from_json(JSON3.write(doc3))
        @test PowerIO.branch_susceptance(infinite_r; convention=:reactance_only) isa
              Vector{Float64}
        arrow_err = try
            PowerIO.calc_incidence_parts(infinite_r; convention=:reactance_only)
            nothing
        catch e
            e
        end
        @test arrow_err !== nothing
        @test occursin("calc_incidence_parts", sprint(showerror, arrow_err))
        @test occursin(":series", sprint(showerror, arrow_err))
        # Under `:series` itself the refusal is the caller's own, and passes
        # through unwrapped.
        series_err = try
            PowerIO.calc_incidence_parts(infinite_r)
            nothing
        catch e
            e
        end
        @test series_err !== nothing
        @test !occursin("whatever `convention` asks for", sprint(showerror, series_err))
        # And a case no convention carries is the caller's own, not a
        # convention mismatch: `poisoned`'s infinite reactance is refused by
        # `:reactance_only` too, so that refusal is the one to report.
        poisoned_err = try
            PowerIO.calc_incidence_parts(poisoned; convention=:reactance_only)
            nothing
        catch e
            e
        end
        @test poisoned_err !== nothing
        @test !occursin("whatever `convention` asks for", sprint(showerror, poisoned_err))
        @test occursin("calc_incidence_parts", sprint(showerror, poisoned_err))

        # Every ccall on a live handle goes to the library that allocated it,
        # not to `_lib()`. `set_library!` is public API for pointing at a local
        # build and can be called while a parsed network is still alive; these
        # two took the configured path instead, so a swapped-in build would
        # have been handed the parsing build's `PioNetwork` pointer, which the
        # integer ABI handshake cannot catch. A path that cannot even be opened
        # makes the difference observable without a second real build.
        try
            PowerIO.set_library!("/nonexistent/libpowerio_capi.so")
            @test PowerIO.branch_susceptance(net) == b
            @test PowerIO.calc_incidence_parts(net).branch_rows == parts.branch_rows
        finally
            PowerIO.clear_library!()
        end

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
