@testset "PyPSA CSV writer and reference bus indices" begin
    if !PowerIO.library_available()
        @test_skip parse_file("case14.m")
    else
        data = joinpath(@__DIR__, "data")
        net = parse_file(joinpath(data, "case14.m"))

        # write_pypsa_csv_folder writes a directory and round-trips back through
        # the pypsa-csv reader; bus count and base_mva survive the model crossing.
        out = mktempdir()
        dir, warnings = write_pypsa_csv_folder(net, out)
        @test dir == out
        @test warnings isa AbstractVector{<:AbstractString}
        @test !isempty(readdir(out))
        back = parse_file(out; from = "pypsa-csv")
        @test PowerIO.n_buses(back) == PowerIO.n_buses(net)
        @test PowerIO.base_mva(back) ≈ PowerIO.base_mva(net)

        # reference_bus_indices returns the dense indices of every REF bus; case14
        # has the single slack reference_bus_id reports, and the dense index maps
        # back to that 1-based id through bus_ids.
        refs = PowerIO.reference_bus_indices(net)
        @test refs isa Vector{Int}
        @test length(refs) == 1
        @test PowerIO.to_dense(net).bus_ids[refs[1] + 1] == PowerIO.reference_bus_id(net)

        # n_components / is_radial read the C ABI connectivity scalars directly;
        # they must match the dense tables (case14 is one connected, looped component).
        dense = PowerIO.to_dense(net)
        @test PowerIO.n_components(net) == dense.n_components == 1
        @test PowerIO.is_radial(net) == dense.is_radial == false

        graph = PowerIO._json_plain(to_graph(net))
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
        @test_skip parse_file("case14.m")
    else
        data = joinpath(@__DIR__, "data")
        mtext = read(joinpath(data, "case14.m"), String)

        # parse_file from an IO matches parse_file from a path field-for-field,
        # except `name`: a path parse takes the case name from the file stem
        # ("case14"), an in-memory parse has no path so the core defaults it.
        net = parse_file(joinpath(data, "case14.m"))
        nets = parse_file(IOBuffer(mtext), "matpower")
        @test PowerIO.source_format(nets) == "Matpower"
        @test PowerIO.n_buses(nets) == PowerIO.n_buses(net)
        for k in keys(net.data)
            k == :name && continue
            @test JSON3.write(net.data[k]) == JSON3.write(nets.data[k])
        end

        # Each BalancedNetwork-first to_* transform agrees with its path / convert counterpart.
        @test to_dense(net).gen.bus == to_dense(joinpath(data, "case14.m")).gen.bus
        @test to_dense(net).branch.x ≈ to_dense(joinpath(data, "case14.m")).branch.x
        # to_matpower(net) equals the file->MATPOWER conversion (byte-exact) and round-trips.
        @test to_matpower(net) == convert_file(joinpath(data, "case14.m"), "matpower")[1]
        @test PowerIO.n_buses(parse_file(IOBuffer(to_matpower(net)), "matpower")) == 14
        @test JSON3.read(to_json(net)).base_mva == PowerIO.base_mva(net)

        # to_json works on a handle-less BalancedNetwork (built straight from JSON); every
        # handle-only transform refuses it with a clear error. The guard fires before
        # any feature-specific ccall, so to_arrow throws even without the arrow build.
        jsononly = PowerIO.BalancedNetwork(JSON3.read(to_json(net)))
        @test jsononly.handle === nothing
        @test to_json(jsononly) isa String
        @test_throws ErrorException to_dense(jsononly)
        @test_throws ErrorException to_matpower(jsononly)
        @test_throws ErrorException to_arrow(jsononly, :bus)
        @test_throws ErrorException to_normalized(jsononly)

        # to_normalized on case14: per unit, radians, bus types, source_format.
        # case14 buses are already 1..14; norm_tiny below exercises filtering
        # while preserving non-contiguous source ids.
        norm = to_normalized(net)
        @test PowerIO.source_format(norm) == "Normalized"
        @test PowerIO.n_buses(norm) == 14
        @test [Int(b.id) for b in PowerIO.buses(norm)] == collect(1:14)
        @test first(PowerIO.generators(norm)).pg ≈ 232.4 / 100    # bus 1 raw pg, MW -> pu
        @test PowerIO.buses(norm)[2].va ≈ -4.98 * pi / 180        # raw va, deg -> rad
        kind(id) = String(PowerIO.buses(norm)[id].kind)
        @test kind(1) == "REF"                                   # file REF, gen-backed
        @test all(kind(i) == "PV" for i in (2, 3, 6, 8))         # gen buses
        @test all(kind(i) == "PQ" for i in (4, 5, 7, 9, 10, 11, 12, 13, 14))
        @test PowerIO.reference_bus_id(norm) == 1

        # norm_tiny: ids 1,3,5,8 with bus 8 ISOLATED; branch 1-5 out of service
        # and branch 5-8 onto the dropped bus. Normalized keeps source ids on
        # buses and branch endpoints; PowerData below maps them to dense rows.
        tiny_net = parse_file(joinpath(data, "norm_tiny.m"))
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
            parse_file(joinpath(data, "missing.m"))
            error("expected parse_file to fail")
        catch e
            @test occursin("PowerIO.parse_file:", sprint(showerror, e))
        end
        try
            parse_str("not a MATPOWER case", "matpower")
            error("expected parse_str to fail")
        catch e
            @test occursin("PowerIO.parse_str:", sprint(showerror, e))
        end
        basemva0 = replace(mtext, "mpc.baseMVA = 100" => "mpc.baseMVA = 0")
        @test_throws ErrorException to_normalized(parse_file(IOBuffer(basemva0), "matpower"))
        # No generators and no REF bus: nothing to promote to slack.
        noref = "function mpc = noref\nmpc.version = '2';\nmpc.baseMVA = 100;\n" *
                "mpc.bus = [\n1 1 10 5 0 0 1 1.0 0 138 1 1.1 0.9;\n" *
                "2 1 20 8 0 0 1 1.0 -1 138 1 1.1 0.9;\n];\n" *
                "mpc.gen = [\n];\nmpc.branch = [\n1 2 0.01 0.1 0 100 100 100 0 0 1 -30 30;\n];\n"
        @test_throws ErrorException to_normalized(parse_file(IOBuffer(noref), "matpower"))

        if PowerIO._exports_symbol(:pio_normalize_with_options)
            angle_net = parse_file(joinpath(data, "angle_bounds_clamp.m"))
            clamped = to_normalized_with_options(angle_net; clamp_angle_bounds=true)
            @test PowerIO.branches(clamped)[1].angmin ≈ -PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
            @test PowerIO.branches(clamped)[1].angmax ≈ PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
            @test PowerIO.branches(clamped)[2].angmin ≈ -PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
            @test PowerIO.branches(clamped)[2].angmax ≈ PowerIO.POWER_MODELS_ANGLE_BOUND_PAD
            @test PowerIO.branches(clamped)[3].angmin ≈ -pi / 6
            @test any(w -> occursin("angle difference bounds clamped", w),
                      PowerIO.warnings(clamped))
            custom = to_normalized(angle_net; clamp_angle_bounds=true, angle_bound_pad=0.5)
            @test PowerIO.branches(custom)[1].angmin ≈ -0.5
            @test_throws ErrorException to_normalized(angle_net; clamp_angle_bounds=true,
                                                      angle_bound_pad=pi / 2)
        else
            @test_skip to_normalized_with_options(net; clamp_angle_bounds=true)
        end
    end
end

@testset "dense numeric API" begin
    if !PowerIO.library_available()
        @test_skip to_dense("case14.m")
    else
        d = to_dense(joinpath(@__DIR__, "data", "case14.m"))
        @test (d.n, d.m, d.ng) == (14, 20, 5)
        @test d.base_mva == 100.0
        @test d.bus_ids == collect(1:14)                # case14 buses are 1..14
        @test d.reference_bus == 0                      # dense 0-based index of the REF bus
        @test d.n_components == 1
        @test d.is_radial == false                      # case14 has loops
        @test length(d.branch.from) == 20 && length(d.branch.x) == 20
        @test all(>(0), d.branch.x)                     # reactances are positive
        @test d.gen.bus == [1, 2, 3, 6, 8]              # generator buses, file order
        @test sum(d.demand.pd) ≈ 259.0 rtol = 1e-6      # total active demand (MW)
        # The dense gen table lines up with the JSON payload's count.
        @test d.ng == PowerIO.n_gens(parse_file(joinpath(@__DIR__, "data", "case14.m")))

        # The v0.7 dense fields are present exactly when the resolved library
        # exports the extractors; a pre-0.7 ABI-4 library omits them, so gate
        # like the other additive-symbol tests instead of erroring on a
        # missing NamedTuple field.
        if !(PowerIO._exports_symbol(:pio_switches) &&
             PowerIO._exports_symbol(:pio_branch_charging))
            @test !haskey(d, :ns) && !haskey(d, :switch)
            @test_skip to_dense(joinpath(@__DIR__, "data", "case14.m")).ns
        else
            @test d.ns == 0
            # Terminal charging (pio_branch_charging): a MATPOWER line carries no
            # conductance and splits its total charging b evenly across terminals.
            @test d.branch.g_fr == zeros(20) && d.branch.g_to == zeros(20)
            @test d.branch.b_fr ≈ d.branch.b ./ 2
            @test d.branch.b_fr .+ d.branch.b_to ≈ d.branch.b
            # No switches in case14 (pio_switches / pio_n_switches).
            @test isempty(d.switch.from) && isempty(d.switch.closed)

            # A PowerModels case carries first-class switches and an asymmetric
            # charging split; both survive the dense extractors.
            pm = JSON3.read(read(joinpath(@__DIR__, "data", "case14.pm.json"), String), Dict{String,Any})
            pm["switch"] = Dict("1" => Dict("index" => 1, "f_bus" => 1, "t_bus" => 5,
                                            "state" => 1, "thermal_rating" => 1.25, "pf" => 0.1))
            pm["branch"]["1"]["b_fr"] = 0.02
            pm["branch"]["1"]["b_to"] = 0.03
            swnet = parse_str(JSON3.write(pm), "powermodels")
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
            @test ds.branch.b_fr[row] ≈ 0.02 && ds.branch.b_to[row] ≈ 0.03
            @test ds.branch.b[row] ≈ 0.05
        end
    end
end
