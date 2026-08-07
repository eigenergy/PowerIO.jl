@testset "distribution capabilities" begin
    caps = PowerIO.dist_capabilities()
    # The shape comes from one const, so a new upstream flag is a single edit
    # in features.jl rather than four places that can disagree.
    @test keys(caps) == PowerIO._DIST_CAPABILITY_FIELDS
    @test PowerIO._DIST_CAPABILITY_FIELDS ==
          (:dist, :schema_version, PowerIO._DIST_CAPABILITY_KEYS...)
    @test caps.dist == PowerIO.dist_available()
    @test caps.schema_version === nothing || caps.schema_version isa AbstractString
    for k in PowerIO._DIST_CAPABILITY_KEYS
        @test getproperty(caps, k) isa Bool
    end
    # Every fidelity flag has been true since powerio v0.6.2, and the C ABI has
    # not extended the set since. The old gate here pinned `library_version() ==
    # "0.6.2"` and so has asserted nothing since v0.7.0; any library new enough
    # to export the symbol reports the full set.
    if PowerIO.library_available() && PowerIO.dist_available()
        @test caps.schema_version == "1.0.0"
        for k in PowerIO._DIST_CAPABILITY_KEYS
            @test getproperty(caps, k)
        end
    end
end

function _bmopf_doc_from_dss(text)
    bmopf, warnings = convert_str(MulticonductorNetwork, text, "bmopf", "dss")
    return PowerIO._json_plain(JSON3.read(bmopf)), collect(String, warnings)
end

@testset "BMOPF v0.6.2 fidelity gates" begin
    caps = PowerIO.dist_capabilities()
    required = (
        :bmopf_fixed_taps,
        :bmopf_center_tap_leakage,
        :bmopf_delta_wye_leakage,
        :bmopf_delta_roll,
        :bmopf_voltage_source_merge,
        :bmopf_transformer_diagnostics,
    )
    if !(PowerIO.library_available() && PowerIO.dist_available() &&
         all(k -> getproperty(caps, k), required))
        @test_skip "BMOPF v0.6.2 fidelity capabilities not available"
    else
        tap_doc, tap_w = _bmopf_doc_from_dss("""
        New Circuit.c basekv=12.47
        New Transformer.t phases=3 windings=2 buses=[source.1.2.3 load.1.2.3] conns=[wye wye] kvs=[12.47 0.48] kvas=[500 500] xhl=5 taps=[1.025 1.0]
        """)
        # Schema 0.1.0 has no tap slot; powerio keeps taps under the
        # extras escape hatch (extras.transformer.<subtype>.<name>).
        t1 = tap_doc["extras"]["transformer"]["single_phase"]["t_1"]
        @test t1["tap"] == 1.025
        @test !haskey(t1, "tap_min")
        @test !haskey(t1, "tap_max")
        @test !any(w -> occursin("tap", lowercase(w)) && occursin("dropped", lowercase(w)), tap_w)

        ct_doc, _ = _bmopf_doc_from_dss("""
        New Circuit.c basekv=7.2
        New Transformer.ct phases=1 windings=3 buses=[source.1 load.1 load.2] conns=[wye wye wye] kvs=[7.2 0.12 0.12] kvas=[25 25 25] xhl=2 xht=2 xlt=1
        """)
        ct = ct_doc["transformer"]["center_tap"]["ct"]
        @test ct["terminal_map_to"] == ["1", "4", "2"]
        @test ct["v_nom_to"] == 120
        @test ct["x_series_to"] > 0

        dw_doc, dw_w = _bmopf_doc_from_dss("""
        New Circuit.c basekv=12.47
        New Transformer.dw phases=3 windings=2 buses=[source.1.2.3 load.1.2.3.4] conns=[delta wye] kvs=[12.47 0.48] kvas=[500 500] xhl=5
        """)
        # Schema 0.1.0 three phase transformers carry one lumped pair on
        # the wye base; the split _from/_to fields lost their slots.
        dw = dw_doc["transformer"]["delta_wye"]["dw"]
        @test dw["x_series"] > 0
        @test dw["r_series"] > 0
        @test !haskey(dw, "x_series_from")
        @test !haskey(dw, "r_series_from")
        @test !any(w -> occursin("delta_wye", lowercase(w)) ||
                         occursin("leakage", lowercase(w)), dw_w)

        nw_doc, _ = _bmopf_doc_from_dss("""
        New Circuit.c basekv=12.47
        New Transformer.nw phases=3 windings=3 buses=[source.1.2.3 mid.1.2.3 load.1.2.3] conns=[delta wye wye] kvs=[12.47 4.16 0.48] kvas=[1000 1000 1000] xhl=5 xht=6 xlt=2
        """)
        windings = nw_doc["transformer"]["n_winding"]["nw"]["windings"]
        delta_windings = [w for w in windings if get(w, "configuration", nothing) == "DELTA"]
        @test !isempty(delta_windings)
        @test all(w -> get(w, "delta_roll", nothing) == -1, delta_windings)

        src_doc, src_w = _bmopf_doc_from_dss("""
        New Circuit.c basekv=0.4
        New Vsource.sa bus1=b.1 phases=1 basekv=0.23 angle=0
        New Vsource.sb bus1=b.2 phases=1 basekv=0.23 angle=-120
        New Vsource.sc bus1=b.3 phases=1 basekv=0.23 angle=120
        """)
        b_sources = Dict(k => v for (k, v) in src_doc["voltage_source"] if v["bus"] == "b")
        @test length(b_sources) == 1
        src = only(values(b_sources))
        @test src["terminal_map"] == ["1", "2", "3", "4"]
        @test length(src["v_magnitude"]) == length(src["terminal_map"])
        @test length(src["v_angle"]) == length(src["terminal_map"])
        @test !haskey(src_doc["voltage_source"], "sb")
        @test !haskey(src_doc["voltage_source"], "sc")

        _, unsupported_w = _bmopf_doc_from_dss("""
        New Circuit.c basekv=12.47
        New Transformer.r phases=3 windings=2 buses=[source.1.2.3 load.1.2.3] conns=[wye wye] kvs=[12.47 0.48] kvas=[500 500] xhl=5
        New RegControl.rc transformer=r winding=2 vreg=120 band=2
        """)
        @test any(w -> occursin("transformer", lowercase(w)) ||
                       occursin("regcontrol", lowercase(w)) ||
                       occursin("code", lowercase(w)), unsupported_w)
    end
end

@testset "distribution API (feature gated)" begin
    if !(PowerIO.library_available() && PowerIO.dist_available())
        @test_skip parse_file(MulticonductorNetwork, "switch.dss")
    else
        dss = joinpath(@__DIR__, "data", "dist", "switch.dss")
        @test PowerIO.dist_abi_version() == PowerIO.PIO_DIST_ABI_VERSION
        has_dist_summary = PowerIO._exports_symbol(:pio_dist_summary_json)

        # The distribution case shares the transmission verbs: the entry points
        # take MulticonductorNetwork as a leading type marker (the parse(T, x) idiom),
        # to_format / warnings dispatch on the handle.
        net = parse_file(MulticonductorNetwork, dss)
        @test net isa MulticonductorNetwork
        @test getfield(net, :data) === nothing
        @test PowerIO.warnings(net) isa Vector{String}
        @test net.warnings == PowerIO.warnings(net)
        @test getfield(net, :data) === nothing
        @test PowerIO.n_buses(net) == 4
        @test PowerIO.source_format(net) == "dss"
        @test PowerIO.base_frequency(net) == 60.0
        @test net.source_format == "dss"
        @test net.base_frequency == 60.0
        @test getfield(net, :data) === nothing
        @test occursin("MulticonductorNetwork{dss}", sprint(show, net))
        display = sprint(show, MIME"text/plain"(), net)
        @test occursin("MulticonductorNetwork{dss}", display)
        @test occursin("  base_frequency: 60.0 Hz", display)
        @test occursin("  buses: 4", display)
        @test occursin("  data: not materialized", display)
        @test getfield(net, :data) === nothing
        if PowerIO._dist_graph_available()
            graph = PowerIO._json_plain(to_graph(net))
            @test length(graph["buses"]) == 4
            @test any(bus -> bus["id"] == "sourcebus" && bus["has_source"], graph["buses"])
            @test any(edge -> edge["kind"] == "line" && edge["id"] == "feeder" &&
                              edge["from"] == "sourcebus" && edge["to"] == "mid",
                      graph["edges"])
        else
            @test_throws ErrorException to_graph(net)
        end

        # Same-format write echoes the source byte for byte and warns about nothing.
        echo, echo_w = to_format(net, "dss")
        @test echo == read(dss, String)
        @test isempty(echo_w)
        has_dist_summary && @test getfield(net, :data) === nothing

        # A cross-format write exercises a second writer (PMD ENGINEERING JSON)
        # and the fidelity warnings vector.
        pmd, pmd_w = to_format(net, "pmd")
        @test occursin("data_model", pmd)
        @test pmd_w isa AbstractVector{<:AbstractString}
        pmd_net = parse_str(MulticonductorNetwork, pmd, "pmd")
        @test pmd_net isa MulticonductorNetwork
        @test PowerIO.warnings(pmd_net) isa Vector{String}
        @test getfield(pmd_net, :data) === nothing

        if package_available()
            multi_pkg = to_package(net)
            @test multi_pkg isa CompilerPackage
            @test package_model_kind(multi_pkg) == :multiconductor

            z3 = [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
            r3 = [[0.01, 0.0, 0.0], [0.0, 0.01, 0.0], [0.0, 0.0, 0.01]]
            x3 = [[0.10, 0.0, 0.0], [0.0, 0.10, 0.0], [0.0, 0.0, 0.10]]
            ready_pkg = CompilerPackage(JSON3.write((
                schema_version = PowerIO.PIO_PACKAGE_SCHEMA_VERSION,
                producer = (tool = "PowerIO.jl test", version = "0"),
                model_kind = "multiconductor",
                model = (
                    kind = "multiconductor",
                    multiconductor_network = (
                        name = nothing,
                        base_frequency = 60.0,
                        buses = [
                            (id = "sourcebus", terminals = ["1", "2", "3"], grounded = String[],
                             v_min = nothing, v_max = nothing, vpn_min = nothing, vpn_max = nothing,
                             vpp_min = nothing, vpp_max = nothing, vpos_min = nothing,
                             vpos_max = nothing, vneg_max = nothing, vzero_max = nothing,
                             vn_max = nothing, extras = (;)),
                            (id = "loadbus", terminals = ["1", "2", "3"], grounded = String[],
                             v_min = nothing, v_max = nothing, vpn_min = nothing, vpn_max = nothing,
                             vpp_min = nothing, vpp_max = nothing, vpos_min = nothing,
                             vpos_max = nothing, vneg_max = nothing, vzero_max = nothing,
                             vn_max = nothing, extras = (;)),
                        ],
                        linecodes = [(
                            name = "lc", n_conductors = 3, r_series = r3, x_series = x3,
                            g_from = z3, b_from = z3, g_to = z3, b_to = z3,
                            i_max = nothing, s_max = nothing, extras = (;),
                        )],
                        lines = [(
                            name = "l1", bus_from = "sourcebus", bus_to = "loadbus",
                            terminal_map_from = ["1", "2", "3"],
                            terminal_map_to = ["1", "2", "3"],
                            linecode = "lc", length = 1.0, extras = (;),
                        )],
                        switches = [], transformers = [], loads = [], generators = [],
                        shunts = [],
                        sources = [(
                            name = "source", bus = "sourcebus", terminal_map = ["1", "2", "3"],
                            v_magnitude = [240.0, 240.0, 240.0],
                            v_angle = [0.0, -2.0 * pi / 3.0, 2.0 * pi / 3.0],
                            extras = (;),
                        )],
                        untyped = [], commands = [], options = [], warnings = String[],
                        source_format = nothing, extras = (;),
                    ),
                ),
                origin = (kind = "in_memory",),
                validation = (
                    status = "ok",
                    counts = (fatal = 0, error = 0, warning = 0, info = 0, debug = 0),
                ),
            )))
            report = multiconductor_to_balanced_preflight(ready_pkg; base_mva = 50.0)
            @test report.status == "ok"
            @test report.base_mva == 50.0
            lowered = lower_multiconductor_to_balanced(ready_pkg; base_mva = 75.0)
            @test package_model_kind(lowered) == :balanced
            @test lowered.model.balanced_network.base_mva == 75.0
            @test lowered.lowering_history[1].pass == "multiconductor-to-balanced"
            @test PowerIO.n_buses(from_package(ready_pkg)) == 2
        else
            @test_skip to_package(net)
        end

        # The in-memory parser matches the file parser on the round trip.
        net_str = parse_str(MulticonductorNetwork, read(dss, String), "dss")
        @test getfield(net_str, :data) === nothing
        @test first(to_format(net_str, "dss")) == read(dss, String)
        @test getfield(net_str, :data) === nothing

        # convert_file is the one-shot path; dss -> bmopf produces JSON. The
        # Julia signature is (MulticonductorNetwork, path, to; from=...).
        bmopf, bmopf_w = convert_file(MulticonductorNetwork, dss, "bmopf")
        @test !isempty(bmopf)
        @test bmopf_w isa AbstractVector{<:AbstractString}
        bmopf_net = parse_str(MulticonductorNetwork, bmopf, "bmopf")
        @test bmopf_net isa MulticonductorNetwork
        @test PowerIO.warnings(bmopf_net) isa Vector{String}
        bmopf_hinted, _ = convert_file(MulticonductorNetwork, dss, "bmopf"; from="dss")
        @test bmopf_hinted == bmopf
        # convert_str matches convert_file for the same conversion.
        cs, _ = convert_str(MulticonductorNetwork, read(dss, String), "pmd", "dss")
        @test cs == pmd

        gen_dss = joinpath(@__DIR__, "data", "dist", "generator.dss")
        gen_net = parse_file(MulticonductorNetwork, gen_dss)
        gen_pmd, _ = to_format(gen_net, "pmd")
        gen_pmd_doc = PowerIO._json_plain(JSON3.read(gen_pmd))
        @test haskey(gen_pmd_doc, "generator")
        @test haskey(gen_pmd_doc["generator"], "g1")

        gen_bmopf, _ = to_format(gen_net, "bmopf")
        gen_bmopf_doc = PowerIO._json_plain(JSON3.read(gen_bmopf))
        @test haskey(gen_bmopf_doc, "generator")
        @test haskey(gen_bmopf_doc["generator"], "g1")

        grounding = """
        New Circuit.c basekv=0.4
        New Reactor.tx_busgrounding_B179 phases=1 bus1=B179.4 bus2=B179.0 r=0.3 x=0.0
        New Reactor.loadbusgrounding_B3230 phases=1 bus1=B3230.4 bus2=B3230.0 r=10.0 x=0.0
        New Reactor.loadbusgrounding_B2656 phases=1 bus1=B2656.4 bus2=B2656.0 r=10.0 x=0.0
        """
        grounding_net = parse_str(MulticonductorNetwork, grounding, "dss")
        @test !any(w -> occursin("reactor", lowercase(w)), PowerIO.warnings(grounding_net))
        grounding_bmopf, grounding_w = to_format(grounding_net, "bmopf")
        @test !any(w -> occursin("reactor", lowercase(w)) ||
                         occursin("ground", lowercase(w)), grounding_w)
        grounding_doc = PowerIO._json_plain(JSON3.read(grounding_bmopf))
        grounding_sh = grounding_doc["shunt"]
        @test length(grounding_sh) == 3
        @test grounding_sh["tx_busgrounding_B179"]["terminal_map"] == ["4"]
        @test isapprox(grounding_sh["tx_busgrounding_B179"]["G_1_1"], 1 / 0.3; atol=1e-12, rtol=0)
        @test grounding_sh["tx_busgrounding_B179"]["B_1_1"] == 0.0
        @test grounding_sh["loadbusgrounding_B3230"]["G_1_1"] == 0.1

        delta = """
        New Circuit.c basekv=4.16
        New Capacitor.capd bus1=b2.1.2.3 phases=3 conn=delta kvar=900 kv=4.16
        New Reactor.rxd bus1=b3.1.2.3 phases=3 conn=delta kvar=600 kv=4.16
        """
        delta_bmopf, delta_w = convert_str(MulticonductorNetwork, delta, "bmopf", "dss")
        @test !any(w -> occursin("untyped", lowercase(w)) ||
                         occursin("not referenced", lowercase(w)), delta_w)
        delta_doc = PowerIO._json_plain(JSON3.read(delta_bmopf))
        @test delta_doc["shunt"]["capd"]["B_1_2"] < 0.0
        @test delta_doc["shunt"]["rxd"]["B_1_2"] > 0.0

        # The bare verb routes on the format: a .dss path parses into a
        # handle-carrying MulticonductorNetwork, symmetric with the balanced side.
        routed = parse_file(dss)
        @test routed isa MulticonductorNetwork
        @test getfield(routed, :data) === nothing
        @test PowerIO.n_buses(routed) > 0
        @test PowerIO.source_format(routed) == "dss"
        @test routed.source_format == "dss"
        @test PowerIO.base_frequency(routed) > 0
        @test routed.base_frequency > 0
        @test occursin("buses", sprint(show, routed))
        has_dist_summary && @test getfield(routed, :data) === nothing
        @test !isempty(routed.buses)
        materialized = routed.data
        @test getfield(routed, :data) === materialized
        @test routed.data === materialized
        # Materialization must not disturb the retained source: the echo tier
        # still writes the file back byte for byte.
        @test first(to_format(routed, "dss")) == read(dss, String)

        # Bare-verb routing agrees with the marker forms, for every entry point
        # and token spelling.
        dss_text = read(dss, String)
        @test parse_str(dss_text, "dss") isa MulticonductorNetwork
        @test parse_file(IOBuffer(dss_text), "dss") isa MulticonductorNetwork
        @test parse_file(dss; from="OpenDSS") isa MulticonductorNetwork
        @test first(convert_file(dss, "bmopf")) == bmopf
        @test first(convert_str(dss_text, "pmd"; from="dss")) == pmd

        # Every token the Julia routing claims resolves in the core (drift canary
        # for the mirrored name tables in convert.rs / routing.rs / dist.jl):
        # a wrong-format parse failure is fine, an unrecognized token is drift.
        for token in PowerIO._DIST_FORMAT_KEYS
            err = try
                parse_str(MulticonductorNetwork, "not a case", token)
                nothing
            catch e
                sprint(showerror, e)
            end
            @test err === nothing || !occursin("unknown distribution format", err)
        end

        # Every element table the live library counts has a Julia accessor
        # (drift canary for `_MC_TABLE_NAMES` against `DistNetwork` in
        # powerio-dist/src/model.rs). `counts` carries one key per table plus
        # `warnings`, so an upstream table this binding has not grown yet shows
        # up here as an uncovered key rather than as a silently missing
        # accessor — which is exactly how `capacitors` slipped through v0.8.0.
        live = PowerIO._summary(net)
        counted = setdiff(collect(keys(live.counts)), [:warnings])
        @test !isempty(counted)
        @test isempty(setdiff(counted, collect(PowerIO._MC_TABLE_NAMES)))
        # ...and every accessor resolves against a real network, so a name in
        # the list without a method is caught too.
        for name in PowerIO._MC_TABLE_NAMES
            @test getproperty(net, name) !== nothing
        end
        # The display policy list must stay a subset of the tables themselves.
        @test isempty(setdiff(collect(PowerIO._MC_ALWAYS_SHOWN),
                              collect(PowerIO._MC_TABLE_NAMES)))

        # Cross-model requests are directed errors, both directions, and the
        # explicit BalancedNetwork marker bypasses routing to the balanced
        # parser, whose error names the distribution API.
        @test_throws ErrorException convert_file(dss, "matpower")
        @test occursin("lower_multiconductor_to_balanced",
                       try convert_file(dss, "matpower"); "" catch e; sprint(showerror, e) end)
        @test_throws ErrorException convert_file(joinpath(@__DIR__, "data", "case14.m"), "bmopf")
        @test_throws ErrorException convert_str(dss_text, "matpower"; from="dss")
        @test_throws ErrorException to_format(net, "matpower")
        @test_throws ErrorException parse_file(BalancedNetwork, dss)
        @test_throws ErrorException parse_file(dss; from="matpower")
        # The parse_str marker must pin the model too, not route on the token.
        @test_throws ErrorException parse_str(BalancedNetwork, dss_text, "dss")
        mtext = read(joinpath(@__DIR__, "data", "case14.m"), String)
        @test parse_str(BalancedNetwork, mtext, "matpower") isa BalancedNetwork

        # A handle-less MulticonductorNetwork (payload only): accessors and
        # warnings work, the handle transforms refuse directedly.
        bare = MulticonductorNetwork(routed.data)
        @test bare.handle === nothing
        @test PowerIO.n_buses(bare) == PowerIO.n_buses(routed)
        @test PowerIO.warnings(bare) isa Vector{String}
        @test_throws ErrorException to_format(bare, "dss")
        payload_round_trip = MulticonductorNetwork(JSON3.read(JSON3.write(routed.data)))
        @test payload_round_trip.handle === nothing
        @test PowerIO.n_buses(payload_round_trip) == PowerIO.n_buses(routed)
        @test PowerIO.source_format(payload_round_trip) == PowerIO.source_format(routed)
        @test PowerIO.warnings(payload_round_trip) == PowerIO.warnings(bare)

        if !PowerIO._exports_symbol(:pio_dist_from_json)
            @test_skip from_json(MulticonductorNetwork, JSON3.write(routed.data))
        else
            # from_json(MulticonductorNetwork, text) rebuilds a LIVE handle from
            # the model JSON (the inverse of pio_dist_to_json), unlike the
            # payload-only constructor above, so handle transforms work on it.
            rebuilt = from_json(MulticonductorNetwork, JSON3.write(routed.data))
            @test rebuilt isa MulticonductorNetwork
            @test getfield(rebuilt, :handle) !== nothing
            @test PowerIO.n_buses(rebuilt) == PowerIO.n_buses(routed)
            @test PowerIO.warnings(rebuilt) == PowerIO.warnings(routed)
            # The rebuilt handle retains no source text: a same format write is
            # a fresh serialization, so compare through bmopf on both sides.
            @test first(to_format(rebuilt, "bmopf")) == first(to_format(routed, "bmopf"))
            @test_throws ErrorException from_json(MulticonductorNetwork, "not json")
        end
        if package_available()
            @test_throws ErrorException to_package(bare)
        end

        if package_available()
            # from_package returns the model the package holds; the rebuilt
            # handle serializes (fresh serialization, no echo expectation).
            back = from_package(to_package(routed))
            @test back isa MulticonductorNetwork
            @test getfield(back, :data) === nothing
            @test PowerIO.n_buses(back) == PowerIO.n_buses(routed)
            has_dist_summary && @test getfield(back, :data) === nothing
            @test first(to_format(back, "bmopf")) == first(to_format(routed, "bmopf"))
            has_dist_summary && @test getfield(back, :data) === nothing
            # A .pio.json path routes through the package reader to the right
            # model, for both kinds.
            dir = mktempdir()
            mpath = joinpath(dir, "feeder.pio.json")
            write_package(mpath, routed)
            @test parse_file(mpath) isa MulticonductorNetwork
            bpath = joinpath(dir, "case14.pio.json")
            write_package(bpath, parse_file(joinpath(@__DIR__, "data", "case14.m")))
            @test parse_file(bpath) isa BalancedNetwork
        end

        # A distribution flavored bare .json routes automatically off the
        # core's classifier (pio_classify_str).
        @test PowerIO._classify_family(pmd) === :distribution
        dir = mktempdir()
        jpath = joinpath(dir, "feeder.json")
        write(jpath, pmd)
        @test parse_file(jpath) isa MulticonductorNetwork

        # A nonexistent path returns a Julia error, not a fault.
        @test_throws ErrorException parse_file(MulticonductorNetwork, joinpath(@__DIR__, "data", "no_such.dss"))
    end
end
