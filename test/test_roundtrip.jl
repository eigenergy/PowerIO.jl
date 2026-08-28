@testset "C ABI round trip" begin
    if !PowerIO.library_available()
        @info "libpowerio_capi not found (set POWERIO_CAPI to a local build); skipping ccall tests"
        @test_skip PowerIO.parse("case14.m"; value_type=BalancedNetwork)
    else
        data = joinpath(@__DIR__, "data")
        net = PowerIO.parse(joinpath(data, "case14.m"); value_type=BalancedNetwork)
        @test getfield(net, :data) === nothing
        @test PowerIO.n_buses(net) == 14
        @test PowerIO.n_branches(net) == 20
        @test PowerIO.n_gens(net) == 5
        @test PowerIO.base_mva(net) == 100.0
        @test PowerIO.reference_bus_id(net) == 1
        @test getfield(net, :data) === nothing
        has_scalar_helpers = PowerIO._exports_symbol(:pio_balanced_network_source_format) &&
                             PowerIO._exports_symbol(:pio_balanced_network_name)
        @test PowerIO.source_format(net) == "matpower"
        @test net.name == "case14"
        @test net.source_format == "matpower"
        @test net.base_mva == 100.0
        @test net.base_frequency == 60.0
        @test getfield(net, :data) === nothing
        if has_scalar_helpers
            # Drift canary: the v0.7 C string accessors (pio_balanced_network_name /
            # pio_balanced_network_source_format) agree with the summary-backed public
            # accessors reading the same Rust fields.
            @test PowerIO._handle_string(net, :pio_balanced_network_name) == PowerIO.network_name(net)
            @test PowerIO._handle_string(net, :pio_balanced_network_source_format) == PowerIO.source_format(net)
            @test PowerIO.network_name(net) == "case14"
            @test net.warnings == String[]
            @test getfield(net, :data) === nothing
            @test sprint(show, net) == "BalancedNetwork{matpower}: 14 buses, 20 branches, 5 gens"
            display = sprint(show, MIME"text/plain"(), net)
            @test occursin("BalancedNetwork{matpower}", display)
            @test occursin("  name: case14", display)
            @test occursin("  base_mva: 100.0", display)
            @test occursin("  buses: 14", display)
            @test occursin("  branches: 20", display)
            @test occursin("  data: not materialized", display)
            @test getfield(net, :data) === nothing
        end
        @test isempty(PowerIO.warnings(net))
        @test getfield(net, :data) === nothing
        dense = PowerIO.to_dense(net)
        @test dense.n == 14
        @test getfield(net, :data) === nothing
        if PowerIO.arrow_available()
            @test PowerIO.to_arrow(net, :bus).id[1] == 1
            @test getfield(net, :data) === nothing
        end
        expected_data = JSON3.read(to_json(net))
        @test getfield(net, :data) === nothing
        @test length(net.buses) == 14
        materialized = net.data
        @test getfield(net, :data) === materialized
        @test JSON3.write(materialized) == JSON3.write(expected_data)
        @test net.data === materialized
        @test isempty(PowerIO.storage(net))
        @test isempty(PowerIO.hvdc(net))

        # `from` hint threads through to pio_parse_file.
        net_hinted = PowerIO.parse(joinpath(data, "case14.m"); from="matpower", value_type=BalancedNetwork)
        @test PowerIO.n_buses(net_hinted) == 14

        text_in = read(joinpath(data, "case14.m"), String)
        net_from_text = PowerIO.parse(IOBuffer(text_in); from="matpower", value_type=BalancedNetwork)
        @test PowerIO.n_buses(net_from_text) == 14
        @test PowerIO.source_format(net_from_text) == "matpower"

        net_from_json = from_json(to_json(net))
        @test PowerIO.n_buses(net_from_json) == 14
        @test PowerIO.source_format(net_from_json) == "matpower"

        # Model JSON is not a case format, so parse_str refuses it and names
        # from_json. A clean MATPOWER parse keeps no handle warnings.
        @test_throws PowerIOCError PowerIO.parse(IOBuffer(to_json(net)); from="model-json", value_type=BalancedNetwork)
        @test isempty(PowerIO.warnings(net))

        # The core classifies it as its own family, and a bare .json holding
        # one routes through from_json rather than a case reader.
        @test PowerIO._classify_family(to_json(net)) === PowerIO.MODEL_JSON_FAMILY
        let dir = mktempdir()
            mjson = joinpath(dir, "case14.json")
            write(mjson, to_json(net))
            @test PowerIO.n_buses(PowerIO.parse(mjson; value_type=BalancedNetwork)) == 14
        end

        # One vocabulary: the families this binding knows are the ones the
        # library reports, so a router here can never meet a token it has no
        # arm for.
        info = PowerIO.build_info()
        classes = info === nothing ? nothing : get(info, :json_classes, nothing)
        if classes !== nothing
            @test Symbol.(classes) == collect(PowerIO.JSON_FAMILIES)
        end

        # EGRET and PowerModels both use .json (fixtures produced by convert_file).
        # The positive cases confirm each fixture parses under its own format; the
        # negative cases prove `from` overrides inference, since forcing the wrong
        # reader on a well-formed file fails.
        egret = PowerIO.parse(joinpath(data, "case14.egret.json"); from="egret", value_type=BalancedNetwork)
        @test PowerIO.n_buses(egret) == 14
        @test PowerIO.source_format(egret) == "egret-json"
        pm = PowerIO.parse(joinpath(data, "case14.pm.json"); from="powermodels", value_type=BalancedNetwork)
        @test PowerIO.n_buses(pm) == 14
        @test PowerIO.source_format(pm) == "powermodels-json"
        @test_throws PowerIOCError PowerIO.parse(joinpath(data, "case14.pm.json"); from="egret", value_type=BalancedNetwork)
        @test_throws PowerIOCError PowerIO.parse(joinpath(data, "case14.egret.json"); from="powermodels", value_type=BalancedNetwork)

        # Same-format conversion is byte-exact and warning-free.
        text, warnings = convert_file(joinpath(data, "case14.m"), "matpower")
        @test occursin("mpc.bus", text)
        @test isempty(warnings)

        # A cross-format target exercises a second writer and the warnings vector.
        psse_text, psse_warnings = convert_file(joinpath(data, "case14.m"), "psse")
        @test !isempty(psse_text)
        @test psse_warnings isa AbstractVector{<:AbstractString}

        # Every warning line leads with its code: split at the first ": " and
        # the left side is a dotted code whose first segment names the stage.
        # A consumer branches on that, never on the prose after it.
        @test !isempty(psse_warnings)
        for line in psse_warnings
            parts = split(line, ": "; limit = 2)
            @test length(parts) == 2
            @test occursin(r"^[A-Z][A-Z0-9_]*(\.[A-Z0-9_]+)+$", parts[1])
            @test split(parts[1], '.')[1] in
                  ("PARSE", "READ", "CANONICALIZE", "VALIDATE", "LOWER", "BUILD",
                   "EMIT", "BIND", "PARTNER", "REQUEST")
        end

        # An error message carries the same identity a warning line does, so a
        # test can name the failure mode without matching prose.
        failure = try
            convert_file(joinpath(data, "case14.m"), "no-such-format")
            nothing
        catch e
            sprint(showerror, e)
        end
        @test failure !== nothing
        @test occursin("REQUEST.FORMAT.UNKNOWN: ", failure)

        # convert_str is the in-memory sibling of convert_file (v4 pio_convert_str);
        # matpower -> psse matches the file conversion byte for byte.
        cs_text, cs_warnings = convert_str(read(joinpath(data, "case14.m"), String), "psse"; from = "matpower")
        @test cs_text == psse_text
        @test cs_warnings isa AbstractVector{<:AbstractString}

        pm_text, pm_warnings = to_format(net, "powermodels-json")
        @test JSON3.read(pm_text).baseMVA == 100.0
        @test pm_warnings isa AbstractVector{<:AbstractString}
        pm_dict = to_powermodels(net)
        @test haskey(pm_dict, "bus")
        @test PowerIO.n_buses(from_powermodels(pm_dict)) == 14

        pdata = to_powerdata(net)
        @test pdata.baseMVA == 100.0
        @test length(pdata.bus) == 14
        @test length(pdata.arc) == 2 * length(pdata.branch)
        @test pdata.gen[1].bus == 1
        @test pdata.gen[1].n == 3
        @test pdata.gen[1].c[1] ≈ 430.292599
        @test pdata.gen[1].c[2] ≈ 2000.0
        @test pdata.gen[1].c[3] ≈ 0.0
        ac = parse_ac_power_data(net)
        @test ac.baseMVA == [100.0]
        @test ac.ref_buses == [1]
        @test ac.gen[1].c == pdata.gen[1].c
        # ExaModelsPower builds a CuArray from each row vector, which needs a
        # concrete isbits element type, not the abstract NamedTuple a bare
        # accumulator leaves behind. case14 has no storage, so the storage-derived
        # bounds must still be empty Float64 vectors, not a NamedTuple fallback.
        for f in (:bus, :gen, :branch, :arc, :storage)
            @test isbitstype(eltype(getfield(ac, f)))
        end
        # A live nonempty parse must produce rows whose element type is exactly the
        # declared bridge schema type. This catches a field-name or field-type drift
        # between the `@NamedTuple` declaration and the row literal that the empty
        # case in test_public_api.jl (which never builds a row) cannot see.
        @test eltype(pdata.bus) === PowerIO._powerdata_bus_row_type(Float64)
        @test eltype(pdata.gen) === PowerIO._powerdata_gen_row_type(Float64)
        @test eltype(pdata.branch) === PowerIO._powerdata_branch_row_type(Float64)
        @test eltype(pdata.arc) === PowerIO._powerdata_arc_row_type(Float64)
        @test ac.pdmax == Float64[] && ac.emax isa Vector{Float64}

        routed_model_path = joinpath(mktempdir(), "case14.json")
        write(routed_model_path, to_json(net))
        @test to_powerdata(routed_model_path) == pdata
        @test parse_ac_power_data(routed_model_path) == ac

        # The stored module replaces the 0.9 package: the document round trips
        # through read_module/write_module, and the balanced value comes back
        # with provenance threaded on.
        m = PowerIO.parse(joinpath(data, "case14.m"))
        @test module_kind(m) == "balanced_network"
        doc = JSON3.read(write_module(m))
        @test doc.schema == "powerio.module"
        @test doc.version == 1
        @test doc.value.kind == "balanced_network"
        back = as_network(read_module(write_module(m)))
        @test back isa BalancedNetwork
        @test PowerIO.n_buses(back) == 14
        @test PowerIO.to_dense(back).gen.bus == PowerIO.to_dense(net).gen.bus

        module_path = joinpath(mktempdir(), "case14.pio.json")
        write(module_path, write_module(m))
        @test module_kind(read_module(read(module_path, String))) == "balanced_network"
        @test to_powerdata(module_path) == pdata
        @test parse_ac_power_data(module_path) == ac

        pv_noref = """
        function mpc = pv_noref
        mpc.version = '2';
        mpc.baseMVA = 100;
        mpc.bus = [
            1 2 0 0 0 0 1 1.0 0 138 1 1.1 0.9;
            2 1 10 4 0 0 1 1.0 -1 138 1 1.1 0.9;
        ];
        mpc.gen = [
            1 50 0 50 -50 1 100 1 100 0;
        ];
        mpc.branch = [
            1 2 0.01 0.1 0 100 100 100 0 0 1 -30 30;
        ];
        mpc.gencost = [
            2 0 0 3 0.01 20 0;
        ];
        """
        pv_ac = parse_ac_power_data(PowerIO.parse(IOBuffer(pv_noref); from="matpower", value_type=BalancedNetwork))
        @test pv_ac.ref_buses == [1]
        @test pv_ac.bus[1].type == 3

        bad_branch = replace(pv_noref, "0.01 0.1" => "NaN 0.1")
        bad_err = try
            to_powerdata(PowerIO.parse(IOBuffer(bad_branch); from="matpower", value_type=BalancedNetwork))
            nothing
        catch e
            e
        end
        @test bad_err isa ArgumentError
        @test occursin("PowerIO.to_powerdata: branch 1", sprint(showerror, bad_err))

        # An unlimited reactive bound is a bound, not a missing value. Model JSON
        # has no Inf literal and spells it "Infinity"; stock case9241pegase.m
        # carries it on seven generators.
        inf_q = replace(pv_noref, "1 50 0 50 -50 1 100 1 100 0;" =>
                                  "1 50 0 Inf -Inf 1 100 1 100 0;")
        inf_net = PowerIO.parse(IOBuffer(inf_q); from="matpower", value_type=BalancedNetwork)
        @test PowerIO.generators(inf_net)[1].qmax == "Infinity"
        @test PowerIO.generators(inf_net)[1].qmin == "-Infinity"
        inf_ac = parse_ac_power_data(inf_net)
        @test inf_ac.qmax[1] == Inf
        @test inf_ac.qmin[1] == -Inf
        @test to_powerdata(inf_net).gen[1].qmax == Inf
        @test to_powerdata(inf_net).gen[1].qmin == -Inf
        @test to_powerdata(inf_net; filtered=false).gen[1].qmax == Inf
        @test PowerIO._json_float(Float64, "Infinity") === Inf
        @test PowerIO._json_float(Float64, "-Infinity") === -Inf
        @test isnan(PowerIO._json_float(Float64, "NaN"))
        @test PowerIO._json_float(Float32, "Infinity") === Float32(Inf)
        @test PowerIO._json_float(Float64, 2) === 2.0
        @test_throws ArgumentError PowerIO._json_float(Float64, "inf")
        # An absent field is still an error, and so is a NaN.
        @test_throws ArgumentError PowerIO._powerdata_real(nothing, Float64, "gen 1", :qmax)
        @test_throws ArgumentError PowerIO._powerdata_real("NaN", Float64, "gen 1", :qmax)
        @test PowerIO._powerdata_real("Infinity", Float64, "gen 1", :qmax) === Inf

        # The bridge normalizes internally and keeps only the tables, so it
        # re-emits what normalize found. A case with no cost data builds rows
        # whose cost objective is identically zero, which the caller building
        # that objective is the one who needs to know.
        costless = replace(read(joinpath(data, "case9.m"), String),
                           r"(?s)mpc\.gencost.*?\];" => "")
        costless_net = PowerIO.parse(IOBuffer(costless); from="matpower", value_type=BalancedNetwork)
        @test occursin("GEN_COST_ABSENT",
                       join(PowerIO.warnings(to_normalized(costless_net)), "\n"))
        @test_logs (:warn, r"CANONICALIZE\.NORMALIZE\.GEN_COST_ABSENT") match_mode = :any parse_ac_power_data(costless_net)
        @test_logs (:warn, r"CANONICALIZE\.NORMALIZE\.GEN_COST_ABSENT") match_mode = :any to_powerdata(costless_net)
        @test_logs (:warn, r"CANONICALIZE\.NORMALIZE\.GEN_COST_ABSENT") match_mode = :any PowerIO.LoadSeries(costless_net, [1.0])
        # A costed case has nothing to report.
        costed_net = PowerIO.parse(joinpath(data, "case9.m"); value_type=BalancedNetwork)
        live = Val(:live)
        @test_logs min_level = Logging.Warn parse_ac_power_data(costed_net)
        @test_logs min_level = Logging.Warn to_powerdata(costed_net)
        @test to_powerdata(costed_net) == to_powerdata(costed_net; filtered=true)
        @test to_powerdata(costed_net, Float64, live) == to_powerdata(costed_net)
        @test to_powerdata(costed_net, Float64, live; filtered=false) ==
              to_powerdata(costed_net; filtered=false)
        @test parse_ac_power_data(costed_net) ==
              parse_ac_power_data(costed_net; filtered=true)
        @test parse_ac_power_data(costed_net, Float64, live) ==
              parse_ac_power_data(costed_net)

        # The closed bridge schema ignores fields added by newer model JSON
        # producers, including nested values and escaped string contents.
        additive = JSON3.read(to_json(costed_net), Dict{String,Any})
        additive["future"] = Dict(
            "nested" => Any[Dict("text" => "brace } ] quote \" slash \\")],
        )
        additive["buses"][1]["future_bus"] = Dict(
            "deep" => Any[1, Dict("escaped" => "a\\\"b")],
        )
        additive["generators"][1]["cost"]["future_cost"] = Dict(
            "values" => Any[true, nothing, "x\\y"],
        )
        additive_net = BalancedNetwork(JSON3.read(JSON3.write(additive)))
        @test to_powerdata(additive_net; filtered=false) ==
              to_powerdata(costed_net; filtered=false)

        # Required bridge fields still fail at the read boundary with a
        # directed error instead of falling into schema-free JSON decoding.
        malformed = deepcopy(additive)
        malformed["loads"][1]["in_service"] = "yes"
        malformed_net = BalancedNetwork(JSON3.read(JSON3.write(malformed)))
        malformed_error = try
            to_powerdata(malformed_net; filtered=false)
            nothing
        catch e
            e
        end
        @test malformed_error isa ArgumentError
        @test occursin("invalid Boolean in model JSON", sprint(showerror, malformed_error))

        missing = deepcopy(additive)
        delete!(missing["loads"][1], "in_service")
        missing_net = BalancedNetwork(JSON3.read(JSON3.write(missing)))
        missing_error = try
            to_powerdata(missing_net; filtered=false)
            nothing
        catch e
            e
        end
        @test missing_error isa ArgumentError
        @test occursin("missing required field `in_service`",
                       sprint(showerror, missing_error))
        # Each call reports for itself: separate cases deserve separate warnings,
        # so the dedupe is within a call rather than capped across the session.
        @test_logs (:warn, r"GEN_COST_ABSENT") match_mode = :any parse_ac_power_data(costless_net)
        # The unfiltered path runs no normalize pass, so it reports nothing.
        @test_logs min_level = Logging.Warn to_powerdata(costless_net; filtered=false)
        # An already normalized network is passed straight through.
        normalized_net = to_normalized(costed_net)
        normalized_pd = @test_logs min_level = Logging.Warn to_powerdata(normalized_net)
        data_only_normalized = BalancedNetwork(JSON3.read(to_json(normalized_net)))
        @test getfield(data_only_normalized, :handle) === nothing
        @test_logs min_level = Logging.Warn to_powerdata(data_only_normalized)
        @test to_powerdata(data_only_normalized) == normalized_pd
        @test_throws ErrorException to_powerdata(data_only_normalized, Float64, live)
        legacy_normalized = PowerIO._json_plain(JSON3.read(to_json(normalized_net)))
        legacy_normalized["source_format"] = "Normalized"
        @test to_powerdata(BalancedNetwork(JSON3.read(JSON3.write(legacy_normalized)))) ==
              normalized_pd
        finalized_normalized = to_normalized(costed_net)
        finalized_normalized.data
        PowerIO.source_format(finalized_normalized)
        finalize(getfield(finalized_normalized, :handle))
        @test to_powerdata(finalized_normalized) == normalized_pd

        storage_text = """
        function mpc = storage_case
        mpc.baseMVA = 100;
        mpc.bus = [
            1 3 0 0 0 0 1 1 0 345 1 1.1 0.9;
            4 1 0 0 0 0 1 1 0 345 1 1.1 0.9;
        ];
        mpc.branch = [
            1 4 0.01 0.05 0.02 0 0 0 0 0 1 -360 360;
        ];
        mpc.gen = [
            1 10 0 100 -100 1 100 1 20 0;
        ];
        mpc.gencost = [
            2 0 0 3 0 1 0;
        ];
        mpc.storage = [
            4 0.0 0.0 1.00 600.0 300.0 216.0 0.9 0.85 1000 -1000 1000 0.1 0.01 0 0 1;
            1 0.0 0.0 0.50 200.0 100.0 100.0 0.95 0.9 500 -500 500 0.2 0.02 0 0 0;
        ];
        """
        storage_net = PowerIO.parse(IOBuffer(storage_text); from="matpower", value_type=BalancedNetwork)
        storage_raw_pd = to_powerdata(storage_net; filtered=false)
        # Nonempty storage rows carry the declared storage row type (order/field drift guard).
        @test eltype(storage_raw_pd.storage) === PowerIO._powerdata_storage_row_type(Float64)
        # The unfiltered bus path is built with the same declared row type as the normalized one.
        @test eltype(storage_raw_pd.bus) === PowerIO._powerdata_bus_row_type(Float64)
        @test length(storage_raw_pd.storage) == 2
        @test storage_raw_pd.storage[1].storage_bus == 4
        @test storage_raw_pd.storage[1].energy_rating == 6.0
        @test storage_raw_pd.storage[2].storage_bus == 1
        @test storage_raw_pd.storage[2].status == 0
        storage_pd = to_powerdata(storage_net)
        @test length(storage_pd.storage) == 1
        # v0.3.0 normalization preserves source bus ids, so the surviving
        # storage unit keeps its source bus 4.
        @test storage_pd.storage[1].storage_bus == 4
        @test storage_pd.storage[1].energy_rating == 6.0

        # library_available() is true here, so the ABI handshake passed: the
        # library reports a version this binding accepts.
        @test PowerIO.abi_version() in PowerIO._ACCEPTED_ABI_VERSIONS
        @test !isempty(PowerIO.library_version())
    end
end
