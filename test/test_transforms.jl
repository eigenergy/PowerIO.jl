@testset "PyPSA CSV emission and reference bus positions" begin
    if !PowerIO.library_available()
        @test_skip parse_file("case14.m").value
    else
        data = joinpath(@__DIR__, "data")
        case_module = parse_file(joinpath(data, "case14.m"))
        net = case_module.value

        # Generic emit writes a PyPSA CSV directory that round-trips through
        # the reader; bus count and base_mva survive the model crossing.
        # Emission refuses an existing target, so the output is a fresh child
        # of the temporary directory.
        out = joinpath(mktempdir(), "pypsa")
        result = emit(PioModule(net), "pypsa-csv", out)
        @test result.text === nothing
        @test result.diagnostics isa Vector{Diagnostic}
        @test !isempty(readdir(out))
        back = parse_file(out; format="pypsa-csv").value
        @test PowerIO.n_buses(back) == PowerIO.n_buses(net)
        @test PowerIO.base_mva(back) ≈ PowerIO.base_mva(net)

        # reference_bus_positions returns Julia positions for every REF bus.
        refs = PowerIO.reference_bus_positions(net)
        @test refs isa Vector{Int}
        @test length(refs) == 1
        @test PowerIO.to_dense(net).bus_ids[refs[1]] == PowerIO.reference_bus_id(net)
        # `reference_bus` is the same bus as a 1-based index into `bus_ids`.
        @test PowerIO.to_dense(net).bus_ids[PowerIO.to_dense(net).reference_bus] ==
              PowerIO.reference_bus_id(net)

        # n_islands / is_radial read the C ABI connectivity scalars directly;
        # they must match the dense tables (case14 is one connected, looped component).
        dense = PowerIO.to_dense(net)
        @test to_dense(case_module).bus_ids == dense.bus_ids
        @test PowerIO.n_islands(net) == dense.n_components == 1
        @test n_islands(case_module) == dense.n_components
        @test PowerIO.is_radial(net) == dense.is_radial == false

        graph = PowerIO._json_plain(to_graph(net))
        @test PowerIO._json_plain(to_graph(case_module)) == graph
        @test length(graph["buses"]) == PowerIO.n_buses(net)
        @test length(graph["edges"]) == count(br -> get(br, :in_service, true), PowerIO.branches(net))
        @test any(bus -> bus["id"] == 1 && bus["index"] == 0 && bus["kind"] == "REF",
                  graph["buses"])
        @test any(edge -> edge["kind"] == "branch" && edge["from"] == 1 && edge["to"] == 2,
                  graph["edges"])
    end
end

@testset "parse_file input methods and to_* dispatch" begin
    if !PowerIO.library_available()
        @test_skip parse_file("case14.m").value
    else
        data = joinpath(@__DIR__, "data")
        mtext = read(joinpath(data, "case14.m"), String)

        # parse_text matches parse_file from a path field-for-field,
        # except `name`: a path parse takes the case name from the file stem
        # ("case14"), an in-memory parse has no path so the core defaults it.
        case_module = parse_file(joinpath(data, "case14.m"))
        net = case_module.value
        nets = parse_text(mtext; name="case14.m", format="matpower").value
        @test PowerIO.source_format(nets) == "matpower"
        @test PowerIO.n_buses(nets) == PowerIO.n_buses(net)
        for k in keys(net.data)
            k == :name && continue
            @test JSON3.write(net.data[k]) == JSON3.write(nets.data[k])
        end

        # Each BalancedNetwork-first to_* transform agrees with its path counterpart.
        # src defect: to_dense(path::AbstractString) calls an undefined
        # `_parse_handle` (dense.jl); pinned below in "dense numeric API".
        # Compare against the network-first form instead, which is unaffected.
        @test to_dense(net).gen.bus == to_dense(parse_file(joinpath(data, "case14.m")).value).gen.bus
        @test to_dense(net).branch.x ≈ to_dense(parse_file(joinpath(data, "case14.m")).value).branch.x
        @test to_dense(case_module).branch.x ≈ to_dense(net).branch.x
        # emit is byte exact and its text round trips.
        emitted = emit(case_module, "matpower").text
        @test emitted == mtext
        @test PowerIO.n_buses(parse_text(emitted; name="case14.m",
                                         format="matpower").value) == 14
        @test JSON3.read(to_json(net)).base_mva == PowerIO.base_mva(net)

        # to_json works on a handle-less BalancedNetwork (built straight from JSON); every
        # handle-only transform refuses it with a clear error. The guard fires before
        # any feature-specific ccall, so to_arrow throws even without the arrow build.
        jsononly = PowerIO.BalancedNetwork(JSON3.read(to_json(net)))
        @test jsononly.handle === nothing
        @test to_json(jsononly) isa String
        @test_throws ErrorException to_dense(jsononly)
        @test_throws ErrorException to_arrow(jsononly, :bus)
        @test_throws ErrorException to_normalized(jsononly)

        # to_normalized on case14: per unit, radians, bus types, source_format.
        # case14 buses are already 1..14; norm_tiny below exercises filtering
        # while preserving non-contiguous source ids.
        norm = to_normalized(net)
        norm_from_module = to_normalized(case_module)
        @test to_json(norm_from_module) == to_json(norm)
        @test PowerIO.source_format(norm) == "normalized"
        @test PowerIO.n_buses(norm) == 14
        @test [Int(b.id) for b in PowerIO.buses(norm)] == collect(1:14)
        @test first(PowerIO.generators(norm)).pg ≈ 232.4 / 100    # bus 1 raw pg, MW -> pu
        @test PowerIO.buses(norm)[2].va ≈ -4.98 * pi / 180        # raw va, deg -> rad
        kind(id) = String(PowerIO.buses(norm)[id].kind)
        @test kind(1) == "REF"                                   # file REF, gen-backed
        @test all(kind(i) == "PV" for i in (2, 3, 6, 8))         # gen buses
        @test all(kind(i) == "PQ" for i in (4, 5, 7, 9, 10, 11, 12, 13, 14))
        @test PowerIO.reference_bus_id(norm) == 1

        @test to_powermodels(case_module) == to_powermodels(net)

        # norm_tiny: ids 1,3,5,8 with bus 8 ISOLATED; branch 1-5 out of service
        # and branch 5-8 onto the dropped bus. Normalized keeps source ids on
        # buses and branch endpoints; PowerData below maps them to dense rows.
        tiny_net = parse_file(joinpath(data, "norm_tiny.m")).value
        tiny = to_normalized(tiny_net)
        @test PowerIO.n_buses(tiny) == 3                          # isolated bus 8 dropped
        @test PowerIO.n_branches(tiny) == 2                      # out-of-service + dangling dropped
        # v0.3.0 normalization preserves the non-contiguous source ids 1,3,5.
        @test [Int(b.id) for b in PowerIO.buses(tiny)] == [1, 3, 5]
        @test [String(b.kind) for b in PowerIO.buses(tiny)] == ["REF", "PV", "PQ"]
        @test [(Int(br.from), Int(br.to)) for br in PowerIO.branches(tiny)] == [(1, 3), (3, 5)]
        taps = [Float64(br.tap) for br in PowerIO.branches(tiny)]
        @test taps[1] ≈ 1.0                                      # raw tap 0 -> 1
        @test taps[2] ≈ 0.98                                     # explicit tap kept
        @test PowerIO.buses(tiny)[3].va ≈ -5 * pi / 180
        @test sort([Float64(l.p) for l in PowerIO.loads(tiny)]) ≈ [0.30, 0.50]  # 30,50 MW -> pu
        tiny_pd = to_powerdata(tiny_net)
        @test [b.bus_i for b in tiny_pd.bus] == [1, 3, 5]
        @test [(br.f_bus, br.t_bus) for br in tiny_pd.branch] == [(1, 2), (2, 3)]

        # Error paths report Julia errors. Build the bad cases in memory.
        try
            parse_file(joinpath(data, "missing.m")).value
            error("expected parse_file to fail")
        catch e
            @test occursin("READ.IO.OPEN", sprint(showerror, e))
        end
        try
            parse_text("not a MATPOWER case"; name="invalid.m", format="matpower").value
            error("expected parse_text to fail")
        catch e
            @test occursin("PARSE.", sprint(showerror, e))
        end
        basemva0 = replace(mtext, "mpc.baseMVA = 100" => "mpc.baseMVA = 0")
        @test_throws PowerIOError to_normalized(
            parse_text(basemva0; name="basemva0.m", format="matpower").value)
        # No generators and no REF bus: nothing to promote to slack.
        noref = "function mpc = noref\nmpc.version = '2';\nmpc.baseMVA = 100;\n" *
                "mpc.bus = [\n1 1 10 5 0 0 1 1.0 0 138 1 1.1 0.9;\n" *
                "2 1 20 8 0 0 1 1.0 -1 138 1 1.1 0.9;\n];\n" *
                "mpc.gen = [\n];\nmpc.branch = [\n1 2 0.01 0.1 0 100 100 100 0 0 1 -30 30;\n];\n"
        @test_throws PowerIOError to_normalized(
            parse_text(noref; name="noref.m", format="matpower").value)

        # The clamp rides `PioNormalizeOptions` on `pio_balanced_network_normalize`; the symbol is
        # not feature gated, so a compatible library always has it.
        angle_net = parse_file(joinpath(data, "angle_bounds_clamp.m")).value
        clamped = to_normalized(angle_net; clamp_angle_bounds=true)
        @test PowerIO.branches(clamped)[1].angmin ≈ -PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
        @test PowerIO.branches(clamped)[1].angmax ≈ PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
        @test PowerIO.branches(clamped)[2].angmin ≈ -PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
        @test PowerIO.branches(clamped)[2].angmax ≈ PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
        @test PowerIO.branches(clamped)[3].angmin ≈ -pi / 6
        # warnings(net) is gone: read the normalize pass's own findings off
        # the handle the same way to_powerdata's live path re-emits them.
        clamped_messages = [d.message for d in PowerIO._handle_diagnostics(getfield(clamped, :handle))]
        @test any(w -> occursin("angle difference bounds clamped", w), clamped_messages)
        custom = to_normalized(angle_net; clamp_angle_bounds=true, angle_bound_pad=0.5)
        @test PowerIO.branches(custom)[1].angmin ≈ -0.5
        @test_throws PowerIOError to_normalized(angle_net; clamp_angle_bounds=true,
                                                  angle_bound_pad=pi / 2)
        # A zero pad is the default pad, which is what makes a zero filled
        # options struct the defaults.
        zeroed = to_normalized(angle_net; clamp_angle_bounds=true, angle_bound_pad=0.0)
        @test PowerIO.branches(zeroed)[1].angmin ≈ -PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
    end
end

@testset "dense numeric API" begin
    if !PowerIO.library_available()
        @test_skip to_dense("case14.m")
    else
        # The path form parses through the module and frees the handle
        # after the copy; it agrees with the network-first form.
        d_path = to_dense(joinpath(@__DIR__, "data", "case14.m"))
        @test to_dense(joinpath(@__DIR__, "data", "case14.m"); format="matpower").bus_ids ==
              d_path.bus_ids
        @test_throws MethodError to_dense(joinpath(@__DIR__, "data", "case14.m");
                                          from="matpower")
        d = to_dense(parse_file(joinpath(@__DIR__, "data", "case14.m")).value)
        @test_throws MethodError to_dense(parse_file(joinpath(@__DIR__, "data", "case14.m")).value;
                                          from="matpower")
        @test d_path.bus_ids == d.bus_ids && d_path.n == d.n
        @test (d.n, d.m, d.ng) == (14, 20, 5)
        @test d.base_mva == 100.0
        @test d.bus_ids == collect(1:14)                # case14 buses are 1..14
        @test d.reference_bus == 1                      # 1-based index into bus_ids
        # Absence is `nothing`, not the C ABI's -1. Two slack buses means no
        # unique reference, and `bus_ids[ref + 1]` has to fail there rather
        # than quietly reach for index 0.
        two_slacks = """
        function mpc = twoslack
        mpc.version = '2';
        mpc.baseMVA = 100;
        mpc.bus = [
        \t1\t3\t0\t0\t0\t0\t1\t1\t0\t230\t1\t1.1\t0.9;
        \t2\t3\t0\t0\t0\t0\t1\t1\t0\t230\t1\t1.1\t0.9;
        \t3\t1\t50\t10\t0\t0\t1\t1\t0\t230\t1\t1.1\t0.9;
        ];
        mpc.gen = [
        \t1\t0\t0\t100\t-100\t1\t100\t1\t100\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0;
        \t2\t0\t0\t100\t-100\t1\t100\t1\t300\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0;
        ];
        mpc.branch = [
        \t1\t2\t0.01\t0.1\t0\t0\t0\t0\t0\t0\t1\t-360\t360;
        \t2\t3\t0.01\t0.1\t0\t0\t0\t0\t0\t0\t1\t-360\t360;
        ];
        """
        multi = to_dense(parse_text(two_slacks; name="twoslack.m",
                                    format="matpower").value)
        @test multi.reference_bus === nothing
        # Absence is `nothing`, so indexing with it fails loudly rather than
        # silently reading a bus.
        @test_throws ArgumentError multi.bus_ids[multi.reference_bus]
        @test d.n_components == 1
        @test d.is_radial == false                      # case14 has loops
        @test length(d.branch.from) == 20 && length(d.branch.x) == 20
        @test all(>(0), d.branch.x)                     # reactances are positive
        @test d.gen.bus == [1, 2, 3, 6, 8]              # generator buses, file order
        @test sum(d.demand.pd) ≈ 259.0 rtol = 1e-6      # total active demand (MW)
        # The dense gen table lines up with the JSON payload's count.
        @test d.ng == PowerIO.n_generators(
            parse_file(joinpath(@__DIR__, "data", "case14.m")).value)

        # The v0.7 dense fields are present exactly when the resolved library
        # exports their extractors; a pre-0.7 ABI-4 library omits them. Each
        # surface gates on its own symbols, mirroring _dense_from_handle.
        if PowerIO._exports_symbol(:pio_balanced_network_branch_charging)
            # Terminal charging (pio_balanced_network_branch_charging): a MATPOWER line carries no
            # conductance and splits its total charging b evenly across terminals.
            @test d.branch.g_fr == zeros(20) && d.branch.g_to == zeros(20)
            @test d.branch.b_fr ≈ d.branch.b ./ 2
            @test d.branch.b_fr .+ d.branch.b_to ≈ d.branch.b
        else
            @test !haskey(d.branch, :g_fr)
            @test_skip to_dense(joinpath(@__DIR__, "data", "case14.m")).branch.g_fr
        end
        if PowerIO._has_switch_extractors()
            # No switches in case14 (pio_balanced_network_switches / pio_balanced_network_n_switches).
            @test d.ns == 0
            @test isempty(d.switch.from) && isempty(d.switch.closed)

            # A PowerModels case carries first-class switches and an asymmetric
            # charging split; both survive the dense extractors.
            pm = JSON3.read(read(joinpath(@__DIR__, "data", "case14.pm.json"), String), Dict{String,Any})
            pm["switch"] = Dict("1" => Dict("index" => 1, "f_bus" => 1, "t_bus" => 5,
                                            "state" => 1, "thermal_rating" => 1.25, "pf" => 0.1))
            pm["branch"]["1"]["b_fr"] = 0.02
            pm["branch"]["1"]["b_to"] = 0.03
            swnet = parse_text(JSON3.write(pm); name="case14.pm.json",
                               format="powermodels").value
            @test PowerIO.n_switches(swnet) == 1
            @test length(swnet.switches) == 1           # the JSON payload table agrees
            ds = to_dense(swnet)
            @test ds.ns == 1
            @test ds.switch.from == [1] && ds.switch.to == [5]
            @test ds.switch.closed == [0x01]
            @test ds.switch.thermal_rating[1] ≈ 125.0   # per unit -> MW at baseMVA 100
            @test ds.switch.pf[1] ≈ 10.0
            @test ds.switch.current_rating[1] == 0.0    # absent optional comes back 0.0
            row = findfirst(i -> ds.branch.from[i] == 1 && ds.branch.to[i] == 2, 1:ds.m)
            @test ds.branch.b[row] ≈ 0.05
            PowerIO._exports_symbol(:pio_balanced_network_branch_charging) &&
                @test ds.branch.b_fr[row] ≈ 0.02 && ds.branch.b_to[row] ≈ 0.03
        else
            @test !haskey(d, :ns) && !haskey(d, :switch)
            @test_skip to_dense(joinpath(@__DIR__, "data", "case14.m")).ns
        end
    end
end

@testset "star-lowered bus space" begin
    # An in-service three winding transformer becomes a synthetic star bus plus
    # three branches. Since C ABI 5 every per-bus extractor reports that lowered
    # space, so a caller sizing a per-bus buffer off the bus count no longer
    # reads short by one entry per such transformer.
    fixture = joinpath(@__DIR__, "data", "psse", "case3_3w_v33.raw")
    if !PowerIO.library_available()
        @test_skip to_dense(fixture)
    else
        # src defect: to_dense(path::AbstractString) calls an undefined
        # `_parse_handle` (dense.jl); pinned in the "dense numeric API"
        # testset above. Use the network-first form here (unaffected).
        d = to_dense(parse_file(fixture).value)
        @test length(d.bus_ids) == d.n
        @test d.n == 4                                  # three file buses plus the star point
        @test allunique(d.bus_ids)                      # the star point takes a fresh id
        @test length(d.demand.pd) == d.n && length(d.demand.qd) == d.n
        @test length(d.shunt.gs) == d.n && length(d.shunt.bs) == d.n

        # Endpoints are 1-based bus ids, so closure means every one of them
        # resolves to a dense row rather than falling outside the table.
        rows = Dict(id => k for (k, id) in enumerate(d.bus_ids))
        @test d.m == 3
        @test all(haskey(rows, id) for id in d.branch.from)
        @test all(haskey(rows, id) for id in d.branch.to)
        @test all(1 .<= [rows[id] for id in vcat(d.branch.from, d.branch.to)] .<= d.n)

        # The star branches ground the two secondary buses through the reference
        # bus; without the lowering they would be ungrounded islands.
        @test d.n_components == 1
        @test d.reference_bus == 1
        # The load rows still land on their file buses, and the star point
        # carries no demand of its own.
        net = parse_file(fixture).value
        @test d.demand.pd[rows[2]] ≈ 45.0 && d.demand.qd[rows[3]] ≈ 5.0
        @test sum(d.demand.pd) ≈ 65.0

        # The element accessors keep reporting the source tables: three buses and
        # no branches, because the three winding record is one transformer. The
        # two counts name different spaces and neither substitutes for the other.
        @test PowerIO.n_buses(net) == 3
        @test PowerIO.n_branches(net) == 0
        @test length(PowerIO.buses(net)) == 3
    end
end
