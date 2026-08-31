# The multiconductor handle's own findings, read without materializing
# `net.data` — the distribution sibling of the balanced `_handle_diagnostics`
# helper (capi.jl), built here from the same public primitives since there is
# no `warnings(net)` function any more (for either model) and the payload
# property `net.warnings` would force `net.data` to materialize.
function _mc_diag_messages(net::MulticonductorNetwork)
    return [d.message for d in PioModule(net).diagnostics]
end

@testset "PioModule wraps existing multiconductor values without reparsing" begin
    if !(PowerIO.library_available() && PowerIO.dist_available())
        @test_skip "distribution API not available"
    else
        source = "New Circuit.c basekv=12.47 bus1=source\n"
        parsed = parse_text(source; name="generated.dss", format="dss")
        wrapped = PioModule(parsed.value)
        @test wrapped isa PioModule{MulticonductorNetwork}
        @test wrapped.diagnostics == parsed.diagnostics
        result = emit(wrapped, "dss")
        @test result.text == source
        @test isempty(result.diagnostics)
    end
end

# NOTE: the "distribution capabilities" testset that used to live here is
# deleted. It tested `PowerIO.dist_capabilities()`, `PowerIO._DIST_CAPABILITY_FIELDS`,
# `PowerIO._DIST_CAPABILITY_KEYS`, and `PowerIO._DIST_CAPABILITY_V08_KEYS`, none of
# which exist any more. `pio_dist_capabilities_json` and `pio_dist_abi_version` are
# also gone from the generated C header (powerio-capi/include/powerio.h): this is a
# removed C ABI surface, not a Julia binding gap. `build_info()`'s `features` and
# `foreign_schemas` cover the "what can this build do" question generally, but carry
# none of the granular v0.6.2/v0.8 BMOPF fidelity flags (`bmopf_fixed_taps`,
# `bmopf_center_tap_leakage`, ...) the deleted testset gated on; there is nothing to
# port them to.

function _bmopf_doc_from_dss(text)
    module_ = parse_text(text; name="fixture.dss", format="dss")
    result = emit(module_, "bmopf")
    return PowerIO._json_plain(JSON3.read(result.text)),
           [d.message for d in result.diagnostics]
end

@testset "BMOPF v0.6.2 fidelity gates" begin
    if !(PowerIO.library_available() && PowerIO.dist_available())
        @test_skip "distribution API not available"
    else
        tap_doc, tap_w = _bmopf_doc_from_dss("""
        New Circuit.c basekv=12.47
        New Transformer.t phases=3 windings=2 buses=[source.1.2.3 load.1.2.3] conns=[wye wye] kvs=[12.47 0.48] kvas=[500 500] xhl=5 taps=[1.025 1.0]
        """)
        # Schema 0.1.0 has no tap slot. A 0.8-era writer relocates taps to
        # the extras escape hatch (extras.transformer.<subtype>.<name>); a
        # 0.7-era writer keeps them on the subtype object. The fidelity
        # gate is home-independent: the tap survives with its value, and no
        # tap bounds are fabricated in either home.
        typed = tap_doc["transformer"]["single_phase"]["t_1"]
        overflow = get(get(get(tap_doc, "extras", Dict()), "transformer", Dict()),
                       "single_phase", Dict())
        t1 = haskey(overflow, "t_1") ? overflow["t_1"] : typed
        @test t1["tap"] == 1.025
        @test !haskey(t1, "tap_min") && !haskey(typed, "tap_min")
        @test !haskey(t1, "tap_max") && !haskey(typed, "tap_max")
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
        # the wye base (a 0.8-era writer); a 0.7-era writer still emits the
        # split _from/_to fields. The fidelity gate is shape-independent:
        # the leakage survives as positive series impedance in exactly one
        # of the two shapes, with no leakage warning.
        dw = dw_doc["transformer"]["delta_wye"]["dw"]
        lumped = haskey(dw, "x_series")
        @test lumped ? dw["x_series"] > 0 : dw["x_series_to"] > 0
        @test lumped ? dw["r_series"] > 0 : dw["r_series_to"] > 0
        @test lumped == !haskey(dw, "x_series_from")
        @test lumped == !haskey(dw, "r_series_from")
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
        @test_skip parse_file("switch.dss")
    else
        dss = joinpath(@__DIR__, "data", "dist", "switch.dss")

        # The distribution case shares the transmission verbs: the bare verb
        # routes on format/extension, emit dispatches on the module, and
        # findings come from the module surface.
        case_module = parse_file(dss)
        net = case_module.value
        @test net isa MulticonductorNetwork
        @test getfield(net, :data) === nothing
        @test _mc_diag_messages(net) isa Vector{String}
        @test getfield(net, :data) === nothing
        @test PowerIO.n_buses(net) == 4
        @test n_buses(case_module) == n_buses(net)
        @test n_generators(case_module) == n_generators(net)
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
        g = to_graph(net)
        @test !isempty(g.buses)
        @test to_graph(case_module) == g

        # Module sources are input records; voltage sources are electrical
        # elements. The explicit names keep the two meanings separate.
        input_rows = module_sources(case_module)
        @test length(input_rows) == 1

        # Same-format write echoes the source byte for byte and finds nothing.
        echo = emit(case_module, "dss")
        @test echo.text == read(dss, String)
        @test isempty(echo.diagnostics)
        @test getfield(net, :data) === nothing
        @test voltage_sources(case_module) == voltage_sources(net)

        # A cross-format write exercises a second writer (PMD ENGINEERING JSON)
        # and the fidelity findings vector.
        pmd = emit(case_module, "pmd")
        @test occursin("data_model", pmd.text)
        @test pmd.diagnostics isa Vector{Diagnostic}
        pmd_net = parse_text(pmd.text; name="feeder.pmd.json", format="pmd").value
        @test pmd_net isa MulticonductorNetwork
        @test _mc_diag_messages(pmd_net) isa Vector{String}
        @test getfield(pmd_net, :data) === nothing

        # The module surface owns the explicit lowering: parse the case to a
        # module, inspect readiness, lower, and take the balanced value. The
        # fixture is three phase with no neutral, the shape the lowering
        # supports.
        lowerable = """
        Clear
        Set DefaultBaseFrequency=60
        New Circuit.feeder basekv=0.416 pu=1.0 phases=3 bus1=sourcebus MVAsc3=2000 MVAsc1=2100
        New Linecode.lc3 nphases=3 basefreq=60 units=km
        ~ rmatrix = (0.211 | 0.049 0.211 | 0.049 0.049 0.211)
        ~ xmatrix = (0.747 | 0.673 0.747 | 0.651 0.673 0.747)
        ~ cmatrix = (10.0 | 0.0 10.0 | 0.0 0.0 10.0)
        ~ normamps=185
        New Line.l1 bus1=sourcebus.1.2.3 bus2=loadbus.1.2.3 phases=3 linecode=lc3 length=0.4 units=km
        New Load.la bus1=loadbus.1.2.3 phases=3 conn=wye kv=0.416 kw=24 pf=0.95 model=1
        """
        m = parse_text(lowerable; name="lowerable.dss", format="dss")
        @test kind(m) == "multiconductor_network"
        readiness = to_balanced_report(m; base_mva = 50.0)
        @test readiness isa JSON3.Object
        @test readiness.ready isa Bool
        @test readiness.diagnostics isa JSON3.Array
        lowered = to_balanced(m; base_mva = 75.0)
        @test kind(lowered) == "balanced_network"
        bal = lowered.value
        @test bal isa BalancedNetwork
        @test PowerIO.base_mva(bal) == 75.0

        # The in-memory parser matches the file parser on the round trip.
        text_module = parse_text(read(dss, String); name="switch.dss", format="dss")
        net_str = text_module.value
        @test getfield(net_str, :data) === nothing
        @test emit(text_module, "dss").text == read(dss, String)
        @test getfield(net_str, :data) === nothing

        bmopf = emit(case_module, "bmopf")
        @test !isempty(bmopf.text)
        @test bmopf.diagnostics isa Vector{Diagnostic}
        # BMOPF is the IEEE BMOPF Taskforce calculation format: it parses
        # back as an McAcOpfInstance module, not a bare MulticonductorNetwork.
        bmopf_module = parse_text(bmopf.text; name="feeder.bmopf.json", format="bmopf")
        @test bmopf_module isa PioModule{McAcOpfInstance}
        @test bmopf_module.diagnostics isa Vector{Diagnostic}

        gen_dss = joinpath(@__DIR__, "data", "dist", "generator.dss")
        gen_module = parse_file(gen_dss)
        gen_net = gen_module.value
        gen_pmd = emit(gen_module, "pmd")
        gen_pmd_doc = PowerIO._json_plain(JSON3.read(gen_pmd.text))
        @test haskey(gen_pmd_doc, "generator")
        @test haskey(gen_pmd_doc["generator"], "g1")

        gen_bmopf = emit(gen_module, "bmopf")
        gen_bmopf_doc = PowerIO._json_plain(JSON3.read(gen_bmopf.text))
        @test haskey(gen_bmopf_doc, "generator")
        @test haskey(gen_bmopf_doc["generator"], "g1")

        grounding = """
        New Circuit.c basekv=0.4
        New Reactor.tx_busgrounding_B179 phases=1 bus1=B179.4 bus2=B179.0 r=0.3 x=0.0
        New Reactor.loadbusgrounding_B3230 phases=1 bus1=B3230.4 bus2=B3230.0 r=10.0 x=0.0
        New Reactor.loadbusgrounding_B2656 phases=1 bus1=B2656.4 bus2=B2656.0 r=10.0 x=0.0
        """
        grounding_module = parse_text(grounding; name="grounding.dss", format="dss")
        grounding_net = grounding_module.value
        @test !any(w -> occursin("reactor", lowercase(w)), _mc_diag_messages(grounding_net))
        grounding_bmopf = emit(grounding_module, "bmopf")
        grounding_w = [d.message for d in grounding_bmopf.diagnostics]
        @test !any(w -> occursin("reactor", lowercase(w)) ||
                         occursin("ground", lowercase(w)), grounding_w)
        grounding_doc = PowerIO._json_plain(JSON3.read(grounding_bmopf.text))
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
        delta_module = parse_text(delta; name="delta.dss", format="dss")
        delta_net = delta_module.value
        delta_bmopf = emit(delta_module, "bmopf")
        delta_w = [d.message for d in delta_bmopf.diagnostics]
        @test !any(w -> occursin("untyped", lowercase(w)) ||
                         occursin("not referenced", lowercase(w)), delta_w)
        delta_doc = PowerIO._json_plain(JSON3.read(delta_bmopf.text))
        @test delta_doc["shunt"]["capd"]["B_1_2"] < 0.0
        @test delta_doc["shunt"]["rxd"]["B_1_2"] > 0.0

        # The bare verb routes on the format: a .dss path parses into a
        # handle-carrying MulticonductorNetwork, symmetric with the balanced side.
        routed = parse_file(dss).value
        @test routed isa MulticonductorNetwork
        @test getfield(routed, :data) === nothing
        @test PowerIO.n_buses(routed) > 0
        @test PowerIO.source_format(routed) == "dss"
        @test routed.source_format == "dss"
        @test PowerIO.base_frequency(routed) > 0
        @test routed.base_frequency > 0
        @test occursin("buses", sprint(show, routed))
        @test getfield(routed, :data) === nothing
        @test !isempty(routed.buses)
        materialized = routed.data
        @test getfield(routed, :data) === materialized
        @test routed.data === materialized
        # Materialization must not disturb the retained source: the echo tier
        # still writes the file back byte for byte.
        @test emit(PioModule(routed), "dss").text == read(dss, String)

        # Bare-verb routing agrees with explicit format hints, for every entry
        # point and token spelling.
        dss_text = read(dss, String)
        @test parse_text(dss_text; name="switch.dss", format="dss").value isa MulticonductorNetwork
        @test parse_file(dss; format="OpenDSS").value isa MulticonductorNetwork
        @test emit(PioModule(routed), "bmopf").text == bmopf.text
        @test emit(PioModule(routed), "pmd").text == pmd.text

        # Every table the live library counts must appear in
        # `_MC_TABLE_NAMES` (drift canary against upstream `DistNetwork`).
        live = PowerIO._summary(net)
        counted = setdiff(collect(keys(live.counts)), [:warnings])
        @test !isempty(counted)
        @test isempty(setdiff(counted, collect(PowerIO._MC_TABLE_NAMES)))
        # Every accessor must return a countable table that agrees with the
        # live summary, so a renamed or typo'd tuple entry cannot hide
        # behind the missing-key empty fallback.
        for name in PowerIO._MC_TABLE_NAMES
            public_name = name === :sources ? :voltage_sources : name
            table = getproperty(net, public_name)
            @test table isa Union{JSON3.Array,Tuple{}}
            if haskey(live.counts, name)
                @test length(table) == Int(live.counts[name])
            end
        end
        # The display policy list must stay a subset of the tables themselves.
        @test isempty(setdiff(collect(PowerIO._MC_ALWAYS_SHOWN),
                              collect(PowerIO._MC_TABLE_NAMES)))

        # Cross-model requests are directed errors, both directions.
        @test_throws PowerIOError emit(case_module, "matpower")
        # There is no more explicit type-marker parse form to force a wrong
        # expected model and watch it refuse; parse_file/parse_text always
        # detect and dispatch on the source's own kind. The equivalent
        # positive coverage is that a .dss source always resolves to
        # MulticonductorNetwork (asserted throughout this testset) and never
        # to BalancedNetwork. Forcing the wrong reader by format token still
        # refuses, structurally:
        @test_throws PowerIOError parse_file(dss; format="matpower")
        @test_throws PowerIOError parse_text(dss_text; name="switch.dss", format="matpower")
        mtext = read(joinpath(@__DIR__, "data", "case14.m"), String)
        @test parse_text(mtext; name="case14.m", format="matpower").value isa BalancedNetwork

        # A handle-less MulticonductorNetwork (payload only): accessors and
        # scalar accessors work; live handle operations refuse directedly.
        bare = MulticonductorNetwork(routed.data)
        @test bare.handle === nothing
        @test PowerIO.n_buses(bare) == PowerIO.n_buses(routed)
        @test :warnings ∉ propertynames(bare)
        @test_throws ErrorException PioModule(bare)
        payload_round_trip = MulticonductorNetwork(JSON3.read(JSON3.write(routed.data)))
        @test payload_round_trip.handle === nothing
        @test PowerIO.n_buses(payload_round_trip) == PowerIO.n_buses(routed)
        @test PowerIO.source_format(payload_round_trip) == PowerIO.source_format(routed)
        @test :warnings ∉ propertynames(payload_round_trip)

        if !PowerIO._exports_symbol(:pio_multiconductor_network_from_json)
            @test_skip from_json(MulticonductorNetwork, JSON3.write(routed.data))
        else
            # from_json(MulticonductorNetwork, text) rebuilds a LIVE handle from
            # the model JSON (the inverse of pio_multiconductor_network_to_json), unlike the
            # payload-only constructor above, so handle transforms work on it.
            rebuilt = from_json(MulticonductorNetwork, JSON3.write(routed.data))
            @test rebuilt isa MulticonductorNetwork
            @test getfield(rebuilt, :handle) !== nothing
            @test PowerIO.n_buses(rebuilt) == PowerIO.n_buses(routed)
            @test _mc_diag_messages(rebuilt) == _mc_diag_messages(routed)
            # The rebuilt handle retains no source text: a same format write is
            # a fresh serialization, so compare through bmopf on both sides.
            @test emit(PioModule(rebuilt), "bmopf").text ==
                  emit(PioModule(routed), "bmopf").text
            @test_throws PowerIOError from_json(MulticonductorNetwork, "not json")
        end
        # The stored module carries the multiconductor value both ways, and a
        # .pio.json path routes through the universal parse to the right kind.
        begin
            m2 = parse_text(read(dss, String); name="switch.dss", format="dss")
            routed_doc = to_json(m2)
            back_module = parse_text(routed_doc; name="feeder.pio.json")
            back = back_module.value
            @test back isa MulticonductorNetwork
            @test getfield(back, :data) === nothing
            @test PowerIO.n_buses(back) == PowerIO.n_buses(net)
            @test emit(back_module, "bmopf").text == emit(case_module, "bmopf").text
            dir = mktempdir()
            mpath = joinpath(dir, "feeder.pio.json")
            write(mpath, routed_doc)
            @test parse_file(mpath).value isa MulticonductorNetwork
        end

        # A distribution flavored bare .json routes automatically off the
        # core's classifier (pio_classify_str).
        @test PowerIO._classify_family(pmd.text) === :distribution
        dir = mktempdir()
        jpath = joinpath(dir, "feeder.json")
        write(jpath, pmd.text)
        @test parse_file(jpath).value isa MulticonductorNetwork

        # A nonexistent path refuses with a structured error.
        @test_throws PowerIOError parse_file(joinpath(@__DIR__, "data", "no_such.dss"))
    end
end
