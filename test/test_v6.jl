# ABI v6: stored modules, structured errors, DC branch data with borrowed
# array views.

# The v6 entry points ship with powerio releases past 0.9; against the pinned
# 0.9 artifact library (ABI 5) every v6 testset is skipped by symbol probe.
_has_v6 = PowerIO.library_available() &&
    PowerIO._exports_symbol(:pio_module_read_json, PowerIO._lib())

@testset "ABI v6 stored modules and DC data" begin
    if !_has_v6
        @test_skip "the resolved library predates the ABI v6 entry points"
        return
    end
    case9 = joinpath(@__DIR__, "data", "case9.m")

    @testset "module round trip and kind" begin
        m = parse_module(case9)
        @test module_kind(m) == "balanced_network"
        doc = write_module(m)
        @test occursin("\"powerio.module\"", doc)
        back = read_module(doc)
        @test module_kind(back) == "balanced_network"
        inspection = inspect_module(back)
        @test inspection.kind == "balanced_network"
        @test "diagnostics" in inspection.operations
    end

    @testset "structured refusals carry the code" begin
        err = try
            parse_module_str("not a case"; format="matpower")
            nothing
        catch e
            e
        end
        @test err isa PowerIOCError
        @test occursin(".", err.code)
        @test !isempty(err.message)

        m = parse_module(case9)
        err = try
            export_state(m; time_position=0)
            nothing
        catch e
            e
        end
        @test err isa PowerIOCError
        @test err.code == "REQUEST.STATE.NOT_A_COLLECTION"
    end

    @testset "DC data spans, mappings, and PowerModels values" begin
        m = parse_module(case9)
        d = dc_data(m)
        # The result is independently owned: drop the module first.
        finalize(m)
        rows = PowerIO.n_rows(d)
        buses = PowerIO.n_buses(d)
        @test rows == 9 && buses == 9
        b = PowerIO.susceptance(d)
        @test b isa BorrowedVector{Float64}
        @test length(b) == rows
        @test all(>(0), b)
        @test PowerIO.formula(d) == "series_susceptance"
        @test PowerIO.row_ids(d)[1] == "branches:0"
        @test length(PowerIO.bus_ids(d)) == buses
        @test isempty(PowerIO.omitted(d))

        # The view is read only; copy is an ordinary mutable array.
        @test_throws ErrorException b[1] = 0.0
        c = copy(b)
        @test c isa Vector{Float64}
        c[1] = 0.0
        @test b[1] != 0.0

        # p_branch = -b (va_from - va_to), against a hand computed row.
        from = PowerIO.from_indices(d)
        to = PowerIO.to_indices(d)
        va = zeros(buses)
        va[from[1] + 1] = 0.05
        flow = branch_flow(d, va)
        expected = -b[1] * (va[from[1] + 1] - va[to[1] + 1])
        @test isapprox(flow[1], expected; atol=1e-12)
        @test_throws ErrorException branch_flow(d, zeros(buses - 1))

        # The borrowed view roots its owner: the spans survive a GC pass with
        # only the view live.
        view = PowerIO.susceptance(dc_data(parse_module(case9)))
        GC.gc()
        @test length(view) == rows
        @test view[1] > 0
    end

    @testset "series values inventory and export over the module surface" begin
        # A released 0.9 package with operating points upgrades on read and
        # selects by time position.
        pkg = PowerIO.to_package(case9)
        series = Dict(
            "time_axis" => Dict("periods" => 2, "duration_hours" => [1.0, 1.0],
                                "labels" => ["h0", "h1"]),
            "points" => [
                Dict("index" => 0, "updates" => Any[]),
                Dict("index" => 1, "updates" => [Dict(
                    "element" => Dict("table" => "generators",
                                       "source_uid" => "generators:0"),
                    "fields" => Dict("pg" => 95.0),
                )]),
            ],
        )
        pkg = PowerIO.set_operating_points(pkg, series)
        m = read_module(PowerIO.to_json(pkg))
        @test module_kind(m) == "balanced_operating_point_time_series"
        inventory = state_inventory(m)
        @test inventory.keyed_by == "time_position"
        @test [p.label for p in inventory.time_points] == ["h0", "h1"]
        exported = export_state(m; time_position=1)
        @test module_kind(exported) == "balanced_network"
        @test occursin("export_selected_state", write_module(exported))
    end
end

@testset "typed module records and bounded field readers" begin
    if !_has_v6
        @test_skip "the resolved library predates the ABI v6 entry points"
        return
    end
    case9 = joinpath(@__DIR__, "data", "case9.m")
    m = parse_module(case9)
    sources = module_sources(m)
    @test length(sources) == 1
    @test endswith(sources[1].name, "case9.m")
    @test sources[1].byte_length > 0

    lowered_history = module_history(lower_module_to_balanced(
        parse_module_str("New Circuit.c basekv=12.47 bus1=src\n"; format="dss")))
    @test any(e -> e.kind == "transform" && e.name == "lower_multiconductor_to_balanced",
              lowered_history)
    entry = only(filter(e -> e.kind == "transform", lowered_history))
    @test any(a -> occursin("power base", a), entry.assumptions)

    diagnostics = module_diagnostics(m)
    @test diagnostics isa Vector{ModuleDiagnostic}
end

@testset "assembled DC matrices match the equations and the matrix surface" begin
    if !_has_v6
        @test_skip "the resolved library predates the ABI v6 entry points"
        return
    end
    case9 = joinpath(@__DIR__, "data", "case9.m")
    m = parse_module(case9)
    d = dc_data(m)
    rows = PowerIO.n_rows(d)
    buses = PowerIO.n_buses(d)

    a = incidence_matrix(d)
    @test size(a) == (rows, buses)
    @test all(sum(a; dims=2) .== 0)

    b_matrix = susceptance_laplacian(d)
    @test size(b_matrix) == (buses, buses)
    @test b_matrix ≈ b_matrix'  # no shifted branch in case9
    bf = flow_matrix(d)
    @test size(bf) == (rows, buses)

    # p_branch = -Bf va (+ b .* shift, zero here) agrees with the C fill, and
    # p_bus = -B va + p_shift agrees with A' applied to that flow.
    va = collect(range(0.0, 0.08; length=buses))
    flow = branch_flow(d, va)
    @test flow ≈ -(bf * va) atol=1e-12
    @test bus_injection(d, va) ≈ a' * flow atol=1e-12

    # The Laplacian agrees with the branch data it was assembled from: each
    # off diagonal entry is the negated susceptance of the branch joining the
    # pair (case9 has no parallel branches).
    from = PowerIO.from_indices(d)
    to = PowerIO.to_indices(d)
    b = PowerIO.susceptance(d)
    for e in 1:rows
        @test b_matrix[from[e] + 1, to[e] + 1] ≈ -b[e] atol=1e-12
    end
end

@testset "DC data agrees with an independent susceptance computation" begin
    if !_has_v6
        @test_skip "the resolved library predates the ABI v6 entry points"
        return
    end
    case9 = joinpath(@__DIR__, "data", "case9.m")
    d = dc_data(parse_module(case9))
    dense = to_dense(case9)
    b = PowerIO.susceptance(d)
    from = PowerIO.from_indices(d)
    to = PowerIO.to_indices(d)
    branch = dense.branch
    ids = PowerIO.bus_ids(d)
    @test length(b) == length(branch.r)
    for e in 1:length(b)
        r = branch.r[e]
        x = branch.x[e]
        # series susceptance with the PowerModels sign: -imag(1/(r + ix)).
        @test b[e] ≈ -imag(inv(complex(r, x))) atol=1e-12
        # The incidence columns map back to the bus IDs the raw table names.
        @test ids[from[e] + 1] == string(branch.from[e])
        @test ids[to[e] + 1] == string(branch.to[e])
    end
end
