@testset "distribution surface (feature-gated)" begin
    if !(PowerIO.library_available() && PowerIO.dist_available())
        @test_skip parse_file(MulticonductorNetwork, "switch.dss")
    else
        dss = joinpath(@__DIR__, "data", "dist", "switch.dss")
        @test PowerIO.dist_abi_version() == PowerIO.PIO_DIST_ABI_VERSION

        # The distribution case shares the transmission verbs: the entry points
        # take MulticonductorNetwork as a leading type marker (the parse(T, x) idiom),
        # to_format / warnings dispatch on the handle.
        net = parse_file(MulticonductorNetwork, dss)
        @test net isa MulticonductorNetwork
        @test PowerIO.warnings(net) isa Vector{String}

        # Same-format write echoes the source byte for byte and warns about nothing.
        echo, echo_w = to_format(net, "dss")
        @test echo == read(dss, String)
        @test isempty(echo_w)

        # A cross-format write exercises a second writer (PMD ENGINEERING JSON)
        # and the fidelity warnings vector.
        pmd, pmd_w = to_format(net, "pmd")
        @test occursin("data_model", pmd)
        @test pmd_w isa AbstractVector{<:AbstractString}
        pmd_net = parse_str(MulticonductorNetwork, pmd, "pmd")
        @test pmd_net isa MulticonductorNetwork
        @test PowerIO.warnings(pmd_net) isa Vector{String}

        if package_available()
            multi_pkg = to_package(net)
            @test multi_pkg isa CompilerPackage
            @test package_model_kind(multi_pkg) == :multiconductor

            z3 = [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
            r3 = [[0.01, 0.0, 0.0], [0.0, 0.01, 0.0], [0.0, 0.0, 0.01]]
            x3 = [[0.10, 0.0, 0.0], [0.0, 0.10, 0.0], [0.0, 0.0, 0.10]]
            ready_pkg = CompilerPackage(JSON3.write((
                schema = PowerIO.PIO_PACKAGE_SCHEMA_URL,
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
                             vpp_min = nothing, vpp_max = nothing, vsym_min = nothing,
                             vsym_max = nothing, extras = (;)),
                            (id = "loadbus", terminals = ["1", "2", "3"], grounded = String[],
                             v_min = nothing, v_max = nothing, vpn_min = nothing, vpn_max = nothing,
                             vpp_min = nothing, vpp_max = nothing, vsym_min = nothing,
                             vsym_max = nothing, extras = (;)),
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
            if PowerIO._exports_symbol(:pio_package_to_multiconductor_network)
                @test PowerIO.n_buses(from_package(ready_pkg)) == 2
            else
                @test_skip PowerIO.n_buses(from_package(ready_pkg)) == 2
            end
        else
            @test_skip to_package(net)
        end

        # The in-memory parser matches the file parser on the round trip.
        net_str = parse_str(MulticonductorNetwork, read(dss, String), "dss")
        @test first(to_format(net_str, "dss")) == read(dss, String)

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

        gen_bmopf, gen_bmopf_w = to_format(gen_net, "bmopf")
        gen_bmopf_doc = PowerIO._json_plain(JSON3.read(gen_bmopf))
        if haskey(gen_bmopf_doc, "generator")
            @test haskey(gen_bmopf_doc["generator"], "g1")
        elseif VersionNumber(PowerIO.library_version()) < v"0.4.0"
            @test haskey(gen_bmopf_doc, "load")
            @test haskey(gen_bmopf_doc["load"], "g1")
            @test any(w -> occursin("fixed P/Q generation encoded as BMOPF negative load", w),
                      gen_bmopf_w)
            @test_skip haskey(gen_bmopf_doc, "generator")
        else
            @test haskey(gen_bmopf_doc, "generator")
        end

        # The v0.3.1 artifact lacks the native fix; the v0.3.2 repin turns
        # this regression on in ordinary package tests.
        if VersionNumber(PowerIO.library_version()) < v"0.3.2"
            @test_skip false
        else
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
        end

        # The bare verb routes on the format: a .dss path parses into a
        # data-carrying MulticonductorNetwork, symmetric with the balanced side.
        routed = parse_file(dss)
        @test routed isa MulticonductorNetwork
        @test PowerIO.n_buses(routed) > 0
        @test !isempty(PowerIO.buses(routed))
        @test PowerIO.source_format(routed) == "dss"
        @test PowerIO.base_frequency(routed) > 0
        @test occursin("buses", sprint(show, routed))
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

        # Cross-model requests are directed errors, both directions, and the
        # explicit BalancedNetwork marker bypasses routing to the balanced
        # parser, whose error names the distribution surface.
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
        if package_available()
            @test_throws ErrorException to_package(bare)
        end

        if package_available() && PowerIO._exports_symbol(:pio_package_to_multiconductor_network)
            # from_package returns the model the package holds; the rebuilt
            # handle serializes (fresh serialization, no echo expectation).
            back = from_package(to_package(routed))
            @test back isa MulticonductorNetwork
            @test PowerIO.n_buses(back) == PowerIO.n_buses(routed)
            @test first(to_format(back, "bmopf")) == first(to_format(routed, "bmopf"))
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
        if PowerIO._classify_family(pmd) === :distribution
            dir = mktempdir()
            jpath = joinpath(dir, "feeder.json")
            write(jpath, pmd)
            @test parse_file(jpath) isa MulticonductorNetwork
        else
            @test_skip false  # library predates pio_classify_str
        end

        # A nonexistent path surfaces as a Julia error, not a fault.
        @test_throws ErrorException parse_file(MulticonductorNetwork, joinpath(@__DIR__, "data", "no_such.dss"))
    end
end
