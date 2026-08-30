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
        m = PowerIO.parse_module(case9)
        @test PowerIO.module_kind(m) == "balanced_network"
        doc = PowerIO.write_module(m)
        @test occursin("\"powerio.module\"", doc)
        back = PowerIO.read_module(doc)
        @test PowerIO.module_kind(back) == "balanced_network"
        inspection = PowerIO.inspect_module(back)
        @test inspection.kind == "balanced_network"
        @test "diagnostics" in inspection.operations
    end

    @testset "structured refusals carry the code" begin
        err = try
            PowerIO.parse_module_str("not a case"; format="matpower")
            nothing
        catch e
            e
        end
        @test err isa PowerIOCError
        @test occursin(".", err.code)
        @test !isempty(err.message)
        @test startswith(sprint(showerror, err), "PowerIOError [")

        m = PowerIO.parse_module(case9)
        err = try
            PowerIO.export_state(m; time_position=0)
            nothing
        catch e
            e
        end
        @test err isa PowerIOCError
        @test err.code == "REQUEST.STATE.NOT_A_COLLECTION"
    end

    @testset "DC data spans, mappings, and PowerModels values" begin
        m = PowerIO.parse_module(case9)
        d = dc_data(m)
        # The result is independently owned: drop the module first.
        finalize(m)
        rows = PowerIO.n_rows(d)
        buses = PowerIO.n_buses(d)
        @test rows == 9 && buses == 9
        b = PowerIO.susceptance(d)
        @test b isa BorrowedVector{Float64}
        @test length(b) == rows
        # PowerModels sign: imag(inv(r + im*x)) is negative for an inductive
        # branch, and case9 has no shunt susceptance or capacitive branch.
        @test all(<(0), b)
        shift = PowerIO.shift(d)
        @test shift isa BorrowedVector{Float64}
        @test length(shift) == rows
        @test all(iszero, shift)  # case9 has no phase shifting transformer
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
        view = PowerIO.susceptance(dc_data(PowerIO.parse_module(case9)))
        GC.gc()
        @test length(view) == rows
        @test view[1] < 0

        # Every formula carries the PowerModels sign: negative susceptance
        # for an inductive branch, exactly as the docstring states.
        for f in ("series_susceptance", "tap_adjusted_reactance", "reactance_only")
            vals = PowerIO.susceptance(dc_data(PowerIO.parse_module(case9); formula=f))
            @test all(<(0.0), vals)
        end
    end

    @testset "series values inventory and export over the module surface" begin
        # A released 0.9 package with operating points upgrades on read and
        # selects by time position. The document is hand authored: the 0.9
        # writer is gone, and the frozen layout is the upgrade specification.
        network_json = JSON3.read(to_json(parse_file(case9).value))
        legacy = JSON3.write(Dict(
            "powerio_version" => "0.9.0",
            "producer" => Dict("tool" => "PowerIO.jl test", "version" => "0"),
            "model_kind" => "balanced",
            "model" => Dict("kind" => "balanced", "balanced_network" => network_json),
            "origin" => Dict("kind" => "in_memory"),
            "validation" => Dict("status" => "ok",
                                 "counts" => Dict("fatal" => 0, "error" => 0,
                                                  "warning" => 0, "info" => 0,
                                                  "debug" => 0)),
            "operating_points" => Dict(
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
            ),
        ))
        m = PowerIO.read_module(legacy)
        @test PowerIO.module_kind(m) == "balanced_operating_point_time_series"
        inventory = state_inventory(m)
        @test inventory.keyed_by == "time_position"
        @test [p.label for p in inventory.time_points] == ["h0", "h1"]
        exported = PowerIO.export_state(m; time_position=1)
        @test PowerIO.module_kind(exported) == "balanced_network"
        # time_position is zero based: position 1 selects the SECOND time
        # point ("h1"), whose update set pg to 95.0. Read it back off the
        # exported network's own generator so an off by one silently landing
        # on "h0" (pg unchanged) cannot pass.
        exported_value = JSON3.read(PowerIO.write_module(exported)).value
        @test exported_value.kind == "balanced_network"
        exported_net = from_json(JSON3.write(exported_value.data))
        @test Float64(first(PowerIO.generators(exported_net)).pg) ≈ 95.0
        @test occursin("export_selected_state", PowerIO.write_module(exported))
    end

    @testset "select_state and state_inventory are one based on the module surface" begin
        # Same legacy 0.9 upgrade fixture as above, wrapped as the typed
        # PioModule surface select_state and state_inventory serve.
        network_json = JSON3.read(to_json(parse_file(case9).value))
        legacy = JSON3.write(Dict(
            "powerio_version" => "0.9.0",
            "producer" => Dict("tool" => "PowerIO.jl test", "version" => "0"),
            "model_kind" => "balanced",
            "model" => Dict("kind" => "balanced", "balanced_network" => network_json),
            "origin" => Dict("kind" => "in_memory"),
            "validation" => Dict("status" => "ok",
                                 "counts" => Dict("fatal" => 0, "error" => 0,
                                                  "warning" => 0, "info" => 0,
                                                  "debug" => 0)),
            "operating_points" => Dict(
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
            ),
        ))
        pio = PowerIO._wrap_module(PowerIO.read_module(legacy))
        @test pio isa PioModule{TimeSeries{OperatingPoint{BalancedNetwork}}}

        inventory = state_inventory(pio)
        @test [p.position for p in inventory.time_points] == [1, 2]
        @test first(inventory.time_points).position == 1

        # select_state(time=<inventory position>) selects the point the
        # inventory names, with no off by one against export_state's own
        # zero based time_position.
        selected = select_state(pio; time=first(inventory.time_points).position)
        @test kind(selected) == "balanced_network"

        # An out of range time restates the position in one based terms: the
        # caller's own `time`, not the zero based export_state offset.
        err = try
            select_state(pio; time=99)
            nothing
        catch e
            e
        end
        @test err isa PowerIOCError
        @test err.code == "REQUEST.STATE.OUT_OF_RANGE"
        @test occursin("99", err.message)
        @test count(err.code, sprint(showerror, err)) == 1
    end

    @testset "select_state refuses a multiconductor operating point series" begin
        # A multiconductor time series selects and reads in place; static
        # materialization is not implemented, and the refusal must name the
        # one based `time` the caller passed, same as the balanced case.
        dss_text = "Clear\nNew Circuit.c basekv=12.47 bus1=src\n"
        mc_data = JSON3.read(PowerIO.write_module(PowerIO.parse_module_str(dss_text; format="dss"))).value.data
        doc = JSON3.write(Dict(
            "schema" => "powerio.module",
            "version" => 1,
            "producer" => Dict("name" => "powerio", "version" => "0"),
            "value" => Dict(
                "kind" => "multiconductor_operating_point_time_series",
                "data" => Dict(
                    "network" => mc_data,
                    "time_points" => [
                        Dict("label" => "h0", "duration" => Dict("secs" => 3600, "nanos" => 0)),
                        Dict("label" => "h1", "duration" => Dict("secs" => 3600, "nanos" => 0)),
                    ],
                    "quantities" => Dict(),
                ),
            ),
        ))
        pio = PowerIO._wrap_module(PowerIO.read_module(doc))
        @test pio isa PioModule{TimeSeries{OperatingPoint{MulticonductorNetwork}}}
        @test !applicable(length, pio)
        @test !applicable(getindex, pio, 1)
        @test length(state_inventory(pio).time_points) == 2
        err = try
            select_state(pio; time=1)
            nothing
        catch e
            e
        end
        @test err isa PowerIOCError
        @test err.code == "REQUEST.STATE.UNBOUND_EXPORT"
    end
end

@testset "DC data string and span lengths agree with their count accessors (3W bus table)" begin
    if !_has_v6
        @test_skip "the resolved library predates the ABI v6 entry points"
        return
    end
    # An in service three winding transformer becomes a synthetic star bus:
    # the string tables (row_ids, bus_ids, omitted) are separate arrays from
    # the count accessors (n_rows, n_buses, n_omitted) on the Rust side, and a
    # rebuild is in flight to keep them in step for this fixture. This
    # testset may only pass once that rebuild is in the resolved library.
    fixture = joinpath(@__DIR__, "data", "psse", "case3_3w_v33.raw")
    d = dc_data(parse_file(fixture))
    rows = PowerIO.n_rows(d)
    buses = PowerIO.n_buses(d)

    @test length(PowerIO.row_ids(d)) == rows
    @test length(PowerIO.bus_ids(d)) == buses
    @test length(PowerIO.from_indices(d)) == rows
    @test length(PowerIO.to_indices(d)) == rows
    @test length(PowerIO.susceptance(d)) == rows
    @test length(PowerIO.shift_injection(d)) == buses
    @test all(!isempty, PowerIO.row_ids(d))
    @test all(!isempty, PowerIO.bus_ids(d))
    for (id, reason) in PowerIO.omitted(d)
        @test !isempty(id)
        @test !isempty(reason)
    end

    a = incidence_matrix(d)
    @test size(a) == (rows, buses)
    b_matrix = susceptance_laplacian(d)
    @test size(b_matrix) == (buses, buses)
    bf = flow_matrix(d)
    @test size(bf) == (rows, buses)
    @test length(bus_injection(d, zeros(buses))) == buses
end

@testset "phase shift bus injection matches the sign corrected equations" begin
    if !_has_v6
        @test_skip "the resolved library predates the ABI v6 entry points"
        return
    end
    # p_shift = A' * (b .* shift) and p_branch = -Bf * va + b .* shift, so
    # the KCL identity A' * p_branch == p_bus holds elementwise.
    shifted = """
    function mpc = case2shift
    mpc.version = '2';
    mpc.baseMVA = 100;
    mpc.bus = [
    \t1\t3\t0\t0\t0\t0\t1\t1.0\t0\t230\t1\t1.1\t0.9;
    \t2\t1\t50\t10\t0\t0\t1\t1.0\t0\t230\t1\t1.1\t0.9;
    ];
    mpc.gen = [
    \t1\t100\t0\t100\t-100\t1\t100\t1\t200\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0;
    ];
    mpc.branch = [
    \t1\t2\t0.01\t0.1\t0\t0\t0\t0\t1\t5\t1\t-360\t360;
    ];
    """
    d = dc_data(parse_file(IOBuffer(shifted); name="case2shift.m", format="matpower"))
    @test any(!iszero, PowerIO.shift_injection(d))

    a = incidence_matrix(d)
    va = [0.0, -0.03]
    p_branch = branch_flow(d, va)
    p_bus = bus_injection(d, va)
    @test a' * p_branch ≈ p_bus atol=1e-10

    # The documented equation is the computed one, elementwise: the shift
    # term is included, and the shift free expression differs.
    b = copy(PowerIO.susceptance(d))
    row_shift = copy(PowerIO.shift(d))
    from = copy(PowerIO.from_indices(d))
    to = copy(PowerIO.to_indices(d))
    dva = va[from .+ 1] .- va[to .+ 1]
    @test p_branch ≈ -b .* dva .+ b .* row_shift atol=1e-12
    @test !(p_branch ≈ -b .* dva)
end

@testset "canonical DC positions, matrices, and phase shifted flow" begin
    if !_has_v6
        @test_skip "the resolved library predates the ABI v6 entry points"
        return
    end

    # Three buses, two generators at the reference bus, and one ten degree
    # phase shifter. This is the binding copy of PowerIO's API conformance
    # case, kept inline so the language packages exercise the same contract
    # without a second fixture file.
    source = """
    function mpc = api_conformance
    mpc.version = '2';
    mpc.baseMVA = 100;
    mpc.bus = [
        1 3  0  0 0 0 1 1.0 0 230 1 1.1 0.9;
        2 1 30 10 0 0 1 1.0 0 230 1 1.1 0.9;
        3 1 20  5 0 0 1 1.0 0 230 1 1.1 0.9;
    ];
    mpc.gen = [
        1 25 0 30 -30 1.0 100 1 100 0;
        1 15 0 20 -20 1.0 100 1  80 0;
    ];
    mpc.branch = [
        1 2 0.01 0.1 0 250 250 250 0  0 1 -30 30;
        1 3 0.02 0.2 0 250 250 250 0 10 1 -30 30;
    ];
    mpc.gencost = [
        2 0 0 3 0.01 1.0 0;
        2 0 0 3 0.02 0.5 0;
    ];
    """
    m = parse_file(IOBuffer(source); name="api_conformance.m", format="matpower")
    @test n_buses(m) == 3
    @test n_generators(m) == n_gens(m) == 2
    @test all(g -> Int(g.bus) == 1, generators(m))
    @test reference_bus_indices(m) == [0]
    @test reference_bus_positions(m) == [1]
    @test n_islands(m) == n_components(m) == 1

    # Raw DcData remains as 0.10 compatibility. These assertions pin its
    # positions, orientation, and signs against the canonical module methods
    # checked below.
    d = dc_data(m)
    @test PowerIO.n_rows(d) == n_branches(d) == 2
    @test branch_ids(d) == row_ids(d) == ["branches:0", "branches:1"]
    @test bus_ids(d) == ["1", "2", "3"]
    @test collect(from_indices(d)) == [0, 0]
    @test collect(PowerIO.to_indices(d)) == [1, 2]
    @test from_bus_positions(d) == [1, 1]
    @test to_bus_positions(d) == [2, 3]

    b = [-0.1 / (0.01^2 + 0.1^2), -0.2 / (0.02^2 + 0.2^2)]
    row_shift = [0.0, 10pi / 180]
    @test collect(susceptance(d)) ≈ b atol=1e-12
    @test collect(shift(d)) ≈ row_shift atol=1e-12

    a = [1.0 -1.0 0.0; 1.0 0.0 -1.0]
    b_bus = [b[1] + b[2] -b[1] -b[2];
             -b[1] b[1] 0.0;
             -b[2] 0.0 b[2]]
    b_branch = [b[1] -b[1] 0.0; b[2] 0.0 -b[2]]
    p_shift = a' * (b .* row_shift)

    @test Matrix(incidence_matrix(d)) == a
    @test Matrix(susceptance_laplacian(d)) ≈ b_bus atol=1e-12
    @test Matrix(flow_matrix(d)) ≈ b_branch atol=1e-12
    @test collect(shift_injection(d)) ≈ p_shift atol=1e-12
    @test b_bus ≈ b_bus' atol=1e-12

    va = [0.1, 0.0, -0.05]
    expected_branch = -b_branch * va + b .* row_shift
    expected_bus = -b_bus * va + p_shift
    @test branch_flow(d, va) ≈ expected_branch atol=1e-12
    @test bus_injection(d, va) ≈ expected_bus atol=1e-12
    @test a' * expected_branch ≈ expected_bus atol=1e-12

    # Module calculations use the canonical branch by bus DC matrices. The
    # BalancedNetwork and path calc_incidence_matrix overloads retain their
    # 0.10 bus by branch orientation until 1.0.
    @test calc_incidence_matrix(m) == incidence_matrix(d)
    @test calc_bus_susceptance_matrix(m) == susceptance_laplacian(d)
    @test calc_branch_susceptance_matrix(m) == flow_matrix(d)
    @test calc_phase_shift_injection(m) ≈ p_shift atol=1e-12
    @test calc_branch_flow_dc(m, va) ≈ expected_branch atol=1e-12
    @test -calc_bus_susceptance_matrix(m) * va +
          calc_phase_shift_injection(m) ≈ expected_bus atol=1e-12
    if matrix_available() && arrow_available()
        @test Matrix(calc_incidence_matrix(m)) == a
    end

    omitted_source = replace(
        source,
        "1 3 0.02 0.2 0 250 250 250 0 10 1 -30 30;" =>
            "1 3 0.02 0.2 0 250 250 250 0 10 0 -30 30;",
    )
    partial = parse_file(
        IOBuffer(omitted_source);
        name="api_conformance_partial.m",
        format="matpower",
    )
    @test length(omitted(dc_data(partial))) == 1
    for operation in (
        () -> calc_incidence_matrix(partial),
        () -> calc_branch_susceptance_matrix(partial),
        () -> calc_branch_flow_dc(partial, va),
    )
        err = try
            operation()
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("branches:1", sprint(showerror, err))
    end
    @test size(calc_bus_susceptance_matrix(partial)) == (3, 3)
    @test length(calc_phase_shift_injection(partial)) == 3
end

@testset "typed module records" begin
    if !_has_v6
        @test_skip "the resolved library predates the ABI v6 entry points"
        return
    end
    case9 = joinpath(@__DIR__, "data", "case9.m")
    m = parse_file(case9)
    rows = module_sources(m)
    alias_rows = sources(m)
    @test length(alias_rows) == length(rows)
    @test only(alias_rows).name == only(rows).name
    @test only(alias_rows).byte_length == only(rows).byte_length
    @test length(rows) == 1
    @test endswith(rows[1].name, "case9.m")
    @test rows[1].byte_length > 0

    dist_module = parse_bytes(codeunits("New Circuit.c basekv=12.47 bus1=src\n");
                              name="inline.dss", format="dss")
    @test to_balanced_report(dist_module) == lowering_readiness(dist_module)
    lowered = to_balanced(dist_module)
    @test to_json(lowered) == to_json(lower_to_balanced(dist_module))
    lowered_history = history(lowered)
    @test any(e -> e.kind == "transform" && e.name == "lower_multiconductor_to_balanced",
              lowered_history)
    entry = only(filter(e -> e.kind == "transform", lowered_history))
    @test any(a -> occursin("power base", a), entry.assumptions)

    # A source row decodes whether `format` is stated, stated as an explicit
    # null (the capi JSON spelling), or absent (the DTO spelling).
    for (row, want) in (
        (JSON3.read("""{"id":"h0","name":"case9.m","byte_length":9,"format":"matpower"}"""), "matpower"),
        (JSON3.read("""{"id":"h0","name":"case9.m","byte_length":9,"format":null}"""), nothing),
        (JSON3.read("""{"id":"h0","name":"case9.m","byte_length":9}"""), nothing),
    )
        record = ModuleSource(String(row.id), String(row.name), Int(row.byte_length),
                              PowerIO._record_string(row, :format))
        @test record.format == want
    end
end

@testset "assembled DC matrices match the equations and the matrix surface" begin
    if !_has_v6
        @test_skip "the resolved library predates the ABI v6 entry points"
        return
    end
    case9 = joinpath(@__DIR__, "data", "case9.m")
    m = parse_file(case9)
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
    d = dc_data(parse_file(case9))
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
        # series susceptance with the PowerModels sign: imag(1/(r + ix)),
        # negative for an inductive branch.
        @test b[e] ≈ imag(inv(complex(r, x))) atol=1e-12
        # The incidence columns map back to the bus IDs the raw table names.
        @test ids[from[e] + 1] == string(branch.from[e])
        @test ids[to[e] + 1] == string(branch.to[e])
    end
end

@testset "module_kind and formula outlive their GC.@preserve scope" begin
    if !_has_v6
        @test_skip "the resolved library predates the ABI v6 entry points"
        return
    end
    # Every module/DcData handle below exists only as an inline argument, with
    # no local binding keeping it alive past the ccall: if the GC.@preserve
    # around the ccall does not also cover the unsafe_string read, an
    # interleaved collection frees the handle before its name is read back.
    case9 = joinpath(@__DIR__, "data", "case9.m")
    dss_text = "New Circuit.c basekv=12.47 bus1=src\n"
    for _ in 1:200
        GC.gc()
        @test PowerIO.module_kind(PowerIO.parse_module_str(dss_text; format="dss")) == "multiconductor_network"
        GC.gc()
        @test PowerIO.formula(PowerIO.dc_data(PowerIO.parse_module(case9))) == "series_susceptance"
    end
end

@testset "BorrowedVector rejects access once its owner is released" begin
    if !_has_v6
        @test_skip "the resolved library predates the ABI v6 entry points"
        return
    end
    d = PowerIO.dc_data(PowerIO.parse_module(joinpath(@__DIR__, "data", "case9.m")))
    v = PowerIO.susceptance(d)
    @test length(v) == PowerIO.n_rows(d)
    @test v[1] isa Float64
    @test v[1:3] isa Vector{Float64}
    @test collect(v) isa Vector{Float64}
    before = copy(v)
    @test before == collect(v)

    # The owner is still reachable through `d`: a GC pass changes nothing.
    GC.gc()
    @test v[1] == before[1]

    finalize(d)
    @test_throws ErrorException v[1]
    @test_throws ErrorException v[1:3]
    @test_throws ErrorException collect(v)
    @test_throws ErrorException copy(v)
end

@testset "read_module, parse_module, parse_module_str keep working against ABI 6" begin
    if !_has_v6
        @test_skip "the resolved library predates the ABI v6 entry points"
        return
    end
    case9 = joinpath(@__DIR__, "data", "case9.m")
    @test PowerIO.module_kind(PowerIO.parse_module(case9)) == "balanced_network"
    @test PowerIO.module_kind(PowerIO.parse_module_str(read(case9, String); format="matpower")) == "balanced_network"
    @test PowerIO.module_kind(PowerIO.read_module(PowerIO.write_module(PowerIO.parse_module(case9)))) == "balanced_network"
end

@testset "read_module, parse_module, parse_module_str preflight the library" begin
    if !PowerIO.library_available()
        @test_skip "no library resolved in this environment"
        return
    end
    if _has_v6
        @test_skip "the resolved library already exports the ABI v6 entry points; needs one that predates them (e.g. the pinned ABI 5 artifact, POWERIO_CAPI unset) to exercise the missing-export path"
    else
        case9 = joinpath(@__DIR__, "data", "case9.m")
        cases = ((:pio_module_read_json, () -> PowerIO.read_module("{}")),
                 (:pio_parse_file, () -> PowerIO.parse_module(case9)),
                 (:pio_parse_str, () -> PowerIO.parse_module_str("not a case"; format="matpower")))
        for (sym, thunk) in cases
            err = try
                thunk()
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin(String(sym), sprint(showerror, err))
        end
    end
    # No library in this environment reports an ABI version outside
    # `_ACCEPTED_ABI_VERSIONS`, so the out of window branch of the preflight
    # (as opposed to the in window but export short branch just above) has no
    # live fixture to exercise here.
    @test_skip "no library in this environment reports an ABI version outside _ACCEPTED_ABI_VERSIONS"
end

@testset "the new v6 refusal codes decode correctly" begin
    if !_has_v6
        @test_skip "the resolved library predates the ABI v6 entry points"
        return
    end
    case9 = joinpath(@__DIR__, "data", "case9.m")
    m = PowerIO.parse_module(case9)

    # Reachable through the public API: dc_data does not validate its
    # `formula` keyword or the module's value kind before the ccall.
    err = try
        dc_data(m; formula="nodal_admittance")
        nothing
    catch e
        e
    end
    @test err isa PowerIOCError
    @test err.code == "REQUEST.CAPI.UNKNOWN_FORMULA"

    mc = PowerIO.parse_module_str(
        "Clear\nNew Circuit.tiny basekv=12.47 bus1=src\n" *
        "New Line.l1 bus1=src bus2=a length=1\nSet VoltageBases=[12.47]\n";
        format="dss")
    err = try
        dc_data(mc)
        nothing
    catch e
        e
    end
    @test err isa PowerIOCError
    @test err.code == "REQUEST.CAPI.NOT_A_BALANCED_NETWORK"
    # This class of refusal does not code-prefix its message; showerror must
    # still render the code exactly once.
    @test count(err.code, sprint(showerror, err)) == 1

    # REQUEST.FORMAT.UNKNOWN does code-prefix its message ("CODE: text");
    # showerror must strip that prefix rather than render the code twice.
    format_err = try
        PowerIO.parse_module_str("not a case"; format="totally-unknown-format")
        nothing
    catch e
        e
    end
    @test format_err isa PowerIOCError
    @test format_err.code == "REQUEST.FORMAT.UNKNOWN"
    @test startswith(format_err.message, format_err.code * ":")
    @test count(format_err.code, sprint(showerror, format_err)) == 1

    # BIND.CAPI.NULL_HANDLE (a NULL module handle) and
    # REQUEST.CAPI.SELECTOR_CONFLICT (export_state given both or neither
    # selector) are C ABI refusals the safe wrappers already refuse first:
    # `_module_ptr` raises its own released-handle error before any ccall
    # sees a NULL pointer, and export_state's keyword check rejects both
    # conflicting combinations before it dispatches. Neither can surface
    # through the public API; exercised here with a direct ccall to confirm
    # PowerIOCError decodes these two codes correctly as well.
    lib = PowerIO._lib()
    err_ref = Ref{Ptr{Cvoid}}(C_NULL)
    s = ccall(PowerIO._library_symbol(lib, :pio_module_write_json), Cstring,
              (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), C_NULL, err_ref)
    @test s == C_NULL
    @test err_ref[] != C_NULL
    @test PowerIO._v6_error(lib, err_ref[]).code == "BIND.CAPI.NULL_HANDLE"

    err_ref = Ref{Ptr{Cvoid}}(C_NULL)
    ptr = ccall(PowerIO._library_symbol(lib, :pio_module_export_state), Ptr{Cvoid},
                (Ptr{Cvoid}, Int64, Cstring, Ref{Ptr{Cvoid}}), PowerIO._module_ptr(m),
                Int64(0), "s1", err_ref)
    @test ptr == C_NULL
    @test err_ref[] != C_NULL
    @test PowerIO._v6_error(lib, err_ref[]).code == "REQUEST.CAPI.SELECTOR_CONFLICT"
end

@testset "parse_file(io::IO) and PowerIOError carries native diagnostics" begin
    if !_has_v6
        @test_skip "the resolved library predates the ABI v6 entry points"
        return
    end
    case9 = joinpath(@__DIR__, "data", "case9.m")

    # The IO method reads once and parses the bytes; it must agree with a
    # path parse of the same file.
    io_module = open(case9) do io
        parse_file(io; name="case9.m", format="matpower")
    end
    @test io_module isa PioModule{BalancedNetwork}
    @test kind(io_module) == "balanced_network"
    @test PowerIO.n_buses(io_module.value) == PowerIO.n_buses(parse_file(case9).value)

    # A malformed source refuses with a PowerIOError whose diagnostics are
    # native Diagnostic records, not JSON or strings.
    err = try
        parse_file(IOBuffer("not a case"); name="invalid.m", format="matpower")
        nothing
    catch e
        e
    end
    @test err isa PowerIOError
    @test err isa PowerIOCError  # released 0.10 alias
    @test !isempty(err.code)
    @test err.diagnostics isa Vector{Diagnostic}
    @test !isempty(err.diagnostics)
    @test all(d -> d isa Diagnostic && d.severity isa Symbol, err.diagnostics)
end
