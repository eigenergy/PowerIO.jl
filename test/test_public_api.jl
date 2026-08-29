@testset "public API loads" begin
    # The module must load with no C library present (the binding is lazy).
    # The exported surface is the ordinary consumer path: one typed module
    # from parse_file/parse_bytes, its value families, structured findings,
    # the conversion/serialization verbs, and the feature/library probes.
    # An exact set equality catches drift in both directions — a symbol lost
    # from the export list, or a new one added without updating this guard.
    exported = Set{Symbol}((
        :PowerIO,
        # The typed module surface.
        :PioModule, :parse_file, :parse_bytes, :kind, :diagnostics,
        :write_file, :write_str, :write_json, :inspect, :source_format,
        :state_inventory, :select_state, :lower_to_balanced, :lowering_readiness,
        # Value families.
        :BalancedNetwork, :MulticonductorNetwork, :TimeSeries, :ScenarioSet,
        :OperatingPoint, :UnknownValue,
        :DcPfInstance, :AcPfInstance, :DcOpfInstance, :AcOpfInstance,
        :McAcPfInstance, :McAcOpfInstance, :AcScucInstance,
        :DcPfSolution, :AcPfSolution, :DcOpfSolution, :AcOpfSolution,
        :McAcPfSolution, :McAcOpfSolution, :AcScucSolution,
        # Structured findings and failures.
        :Diagnostic, :SourceSpan, :PowerIOCError,
        # Conversion and serialization over networks.
        :convert_file, :convert_str, :to_format, :to_normalized,
        :to_json, :from_json, :to_matpower, :write_pypsa_csv_folder,
        # The one exported bridge accessor.
        :n_buses,
        # C library resolution.
        :set_library!, :clear_library!,
        # DC branch data and borrowed numerical views.
        :DcData, :dc_data, :BorrowedVector, :branch_flow,
        # Materialized numeric views.
        :to_dense, :to_arrow, :ArrowTable, :release_c_data, :arrow_catalog,
        # Sparse system matrices.
        :calc_admittance_matrix, :calc_susceptance_matrix, :calc_incidence_matrix,
        :calc_bprime_matrix, :calc_bdoubleprime_matrix,
        # Ecosystem bridges.
        :to_powermodels, :from_powermodels, :to_powerdata, :parse_ac_power_data,
        :read_gridfm, :read_gridfm_scenarios,
        # Distribution availability and feature probes.
        :dist_available, :to_graph, :features, :has_feature, :schema_versions,
        :build_info, :arrow_available, :gridfm_available, :matrix_available,
    ))
    @test Set(names(PowerIO)) == exported

    # The 0.3.0 compatibility bindings, the 0.9 package/SCOPF/untyped parse
    # surfaces, and the reserved OperatingPointSeries skeleton are all gone
    # at 1.0.0. The typed family entries stay, unexported (StoredModule
    # level: PowerIO.parse_module, PowerIO.module_kind, ...).
    for sym in (:Network, :DistNetwork, :dist_graph, :NetworkPackage, :read_package,
                :to_package, :from_package, :ScopfInstance, :parse_scopf,
                :parse_goc3_json, :goc3_scopf_data, :NetworkHandle,
                :CompilerPackage, :to_normalized_with_options,
                :OperatingPointSeries, :TimeAxis, :ElementUpdate,
                :operating_point_series, :materialize_operating_point_series,
                # parse_file(BalancedNetwork, path) / parse_str type-marker
                # forms and the bare PowerIO.parse dispatcher are gone; only
                # parse_file/parse_bytes (auto-detected kind) remain public.
                # as_network/as_dist_network (StoredModule -> typed value)
                # are gone too: parse_bytes on the stored document is the
                # public round trip now. The distribution ABI probe
                # (dist_abi_version/dist_capabilities/PIO_DIST_ABI_VERSION)
                # is gone from the C ABI itself, not just this binding.
                :as_network, :as_dist_network, :dist_abi_version,
                :dist_capabilities, :PIO_DIST_ABI_VERSION)
        @test !isdefined(PowerIO, sym)
    end
    @test :parse ∉ names(PowerIO)  # call it as PowerIO.parse_module, beside Base.parse

    # The accessor API the ecosystem bridges read must exist. It stays
    # unexported because the names collide with the packages a consumer
    # loads beside this one; `n_buses` is the one exported exception.
    for sym in (:n_buses, :n_branches, :n_gens, :n_switches, :base_mva, :network_name,
                :source_format, :reference_bus_id, :reference_bus_indices,
                :n_components, :is_radial, :bus_type_code,
                :buses, :generators, :branches, :loads, :shunts, :storage, :hvdc,
                :lines, :linecodes, :switches, :transformers, :sources,
                :ibrs, :control_profiles, :capacitors, :untyped,
                :base_frequency,
                :abi_version, :library_version, :library_available)
        @test isdefined(PowerIO, sym)
    end
    @test isdefined(PowerIO, :AdmittanceMatrix)
    @test :AdmittanceMatrix ∉ names(PowerIO)

    # LoadSeries is the ExaModelsPower multiperiod-load bridge: still present,
    # now unexported (its whole family — n_periods, demands_mw,
    # read_load_series — moved unexported together).
    for sym in (:LoadSeries, :n_periods, :demands_mw, :read_load_series)
        @test isdefined(PowerIO, sym)
        @test sym ∉ names(PowerIO)
    end
    # StoredModule and its handle-level verbs are the internal surface
    # PioModule wraps: present, unexported.
    for sym in (:StoredModule, :read_module, :parse_module, :parse_module_str,
                :parse_module_bytes, :write_module, :module_kind,
                :inspect_module, :export_state, :lower_module_to_balanced)
        @test isdefined(PowerIO, sym)
        @test sym ∉ names(PowerIO)
    end

    # The Julia GOC3 projection is retired with the SCOPF surface. Nothing
    # internal survives to leak.
    for sym in (:_goc3_static_data, :_goc3_energy_windows, :_goc3_price_blocks,
                :_goc3_ac_contingency_survivors, :_goc3_dc_contingency_flows,
                :_uidnum)
        @test !isdefined(PowerIO, sym)
    end
    # ExaModels PowerData row containers must be concrete isbits so an empty
    # gen/branch/arc/storage section still moves to the GPU (guards the empty->Any
    # inference bug the typed row containers fix).
    for RT in (PowerIO._powerdata_bus_row_type(Float64),
               PowerIO._powerdata_gen_row_type(Float64),
               PowerIO._powerdata_branch_row_type(Float64),
               PowerIO._powerdata_arc_row_type(Float64),
               PowerIO._powerdata_storage_row_type(Float64))
        @test isconcretetype(RT)
        @test isbitstype(RT)
        @test eltype(RT[]) === RT
    end
    @test PowerIO._lib() isa AbstractString
    @test PowerIO.PIO_ABI_VERSION isa Unsigned

    f = PowerIO.features()
    @test propertynames(f) == (:arrow, :matrix, :gridfm, :dist, :prob)
    @test f.arrow == PowerIO.arrow_available()
    @test f.matrix == PowerIO.matrix_available()
    @test f.gridfm == PowerIO.gridfm_available()
    @test f.dist == PowerIO.dist_available()
    @test f.prob == PowerIO.prob_available()
    # pio_has_feature reports what the library was compiled with, an unknown
    # feature name is false, never an error.
    @test PowerIO.has_feature("no-such-feature") == false
    @test PowerIO.has_feature("pkg") == false
    if PowerIO.library_available()
        @test PowerIO.has_feature("dist") isa Bool
    end

    lib = PowerIO._lib()
    PowerIO.set_library!(lib)
    @test PowerIO._lib() == lib
    PowerIO.clear_library!()
    @test PowerIO._lib() isa AbstractString

    # Persistent overrides update both Preferences.jl and the current session;
    # a normal clear removes only the session override. Point Base's active
    # project at a temporary file so this test never edits the checkout.
    old_active_project = Base.ACTIVE_PROJECT[]
    old_session_library = PowerIO._SESSION_LIBRARY[]
    old_preferred_library = PowerIO._PREFERRED_LIBRARY[]
    mktempdir() do dir
        project = joinpath(dir, "Project.toml")
        write(project, "")
        try
            Base.ACTIVE_PROJECT[] = project
            persisted = joinpath(dir, "libpowerio_capi.test")
            PowerIO.set_library!(persisted; persist=true)
            @test PowerIO._SESSION_LIBRARY[] == persisted
            @test PowerIO._PREFERRED_LIBRARY[] == persisted
            @test occursin("library = $(repr(persisted))",
                           read(joinpath(dir, "LocalPreferences.toml"), String))

            PowerIO.set_library!("session-only")
            PowerIO.clear_library!()
            @test isempty(PowerIO._SESSION_LIBRARY[])
            @test PowerIO._PREFERRED_LIBRARY[] == persisted

            PowerIO.clear_library!(persist=true)
            @test isempty(PowerIO._PREFERRED_LIBRARY[])
            @test !occursin("library =",
                            read(joinpath(dir, "LocalPreferences.toml"), String))
        finally
            Base.ACTIVE_PROJECT[] = old_active_project
            PowerIO._SESSION_LIBRARY[] = old_session_library
            PowerIO._PREFERRED_LIBRARY[] = old_preferred_library
        end
    end

    # Clearing an override in the active environment reveals any preference
    # inherited from the next environment on LOAD_PATH. Reflect that effective
    # value in the current session as well as after a process restart.
    mktempdir() do dir
        inner = joinpath(dir, "inner")
        outer = joinpath(dir, "outer")
        mkpath(inner)
        mkpath(outer)
        uuid = Base.PkgId(PowerIO).uuid
        project_text = "[deps]\nPowerIO = \"$uuid\"\n"
        inner_project = joinpath(inner, "Project.toml")
        outer_project = joinpath(outer, "Project.toml")
        write(inner_project, project_text)
        write(outer_project, project_text)
        inherited = joinpath(outer, "libpowerio_capi.inherited")
        PowerIO.set_preferences!((uuid, "PowerIO"), "library" => inherited;
                                 project_toml=outer_project, force=true)

        old_active_project = Base.ACTIVE_PROJECT[]
        old_load_path = copy(LOAD_PATH)
        old_session_library = PowerIO._SESSION_LIBRARY[]
        old_preferred_library = PowerIO._PREFERRED_LIBRARY[]
        try
            Base.ACTIVE_PROJECT[] = inner_project
            empty!(LOAD_PATH)
            append!(LOAD_PATH, (inner, outer, "@stdlib"))
            effective_preference() = get(Base.get_preferences(uuid), "library", "")
            @test effective_preference() == inherited
            PowerIO._PREFERRED_LIBRARY[] = String(effective_preference())

            PowerIO.set_library!("inner"; persist=true)
            @test effective_preference() == "inner"
            PowerIO.clear_library!(persist=true)
            @test effective_preference() == inherited
            @test PowerIO._PREFERRED_LIBRARY[] == inherited
        finally
            Base.ACTIVE_PROJECT[] = old_active_project
            empty!(LOAD_PATH)
            append!(LOAD_PATH, old_load_path)
            PowerIO._SESSION_LIBRARY[] = old_session_library
            PowerIO._PREFERRED_LIBRARY[] = old_preferred_library
        end
    end
end

@testset "pure-Julia accessors (no binary)" begin
    # `reference_bus_id` and `bus_type_code` are pure functions of the parsed JSON,
    # so build a `BalancedNetwork` straight from a JSON3 object and exercise every branch
    # without the native library.
    mk(buses) = PowerIO.BalancedNetwork(JSON3.read(JSON3.write((; buses = buses))))

    # REF at array position 2 but id 7: a "returns the index" bug would read 2;
    # the id is 7. This pins the accessor to the id field, not the position.
    one_ref = mk([(id = 4, kind = "PQ"), (id = 7, kind = "REF"), (id = 9, kind = "PV")])
    @test PowerIO.reference_bus_id(one_ref) == 7
    @test :warnings in propertynames(one_ref)
    # `warnings` reads the live handle; an in-memory network has none, so
    # the read is a directed error like the other live reads.
    @test_throws ErrorException one_ref.warnings
    @test sprint(show, one_ref) == "BalancedNetwork{in-memory}: 3 buses, 0 branches, 0 gens"
    balanced_display = sprint(show, MIME"text/plain"(), one_ref)
    @test occursin("BalancedNetwork{in-memory}", balanced_display)
    @test occursin("  buses: 3", balanced_display)
    @test occursin("  reference_bus_ids: [7]", balanced_display)
    @test occursin("  data: materialized", balanced_display)
    @test PowerIO.reference_bus_id(mk([(id = 1, kind = "REF"), (id = 2, kind = "REF")])) === nothing
    @test PowerIO.reference_bus_id(mk([(id = 1, kind = "PQ"), (id = 2, kind = "PV")])) === nothing

    # The multiconductor accessors are pure functions of the payload, so a
    # handle-less MulticonductorNetwork built from bare JSON exercises them
    # without the native library.
    mn = PowerIO.MulticonductorNetwork(JSON3.read(JSON3.write((;
        name = "t", base_frequency = 60.0, source_format = "dss",
        buses = [(id = "a", terminals = ["1"]), (id = "b", terminals = ["1"])],
        linecodes = [], lines = [(name = "l1", bus_from = "a", bus_to = "b")],
        switches = [], transformers = [],
        loads = [(name = "d1", bus = "b")], generators = [], shunts = [],
        sources = [], warnings = ["w1"]))))
    @test mn.handle === nothing
    @test PowerIO.n_buses(mn) == 2
    @test length(PowerIO.lines(mn)) == 1
    @test PowerIO.network_name(mn) == "t"
    @test PowerIO.source_format(mn) == "dss"
    @test PowerIO.base_frequency(mn) == 60.0
    # Unlike BalancedNetwork, MulticonductorNetwork's getproperty(:warnings)
    # reads the payload's own `warnings` field directly (no removed function
    # in the way), so the property access works.
    @test :warnings in propertynames(mn)
    @test mn.warnings == ["w1"]
    @test sprint(show, mn) == "MulticonductorNetwork{dss}: 2 buses, 1 lines, 1 loads"
    multi_display = sprint(show, MIME"text/plain"(), mn)
    @test occursin("MulticonductorNetwork{dss}", multi_display)
    @test occursin("  base_frequency: 60.0 Hz", multi_display)
    @test occursin("  lines: 1", multi_display)
    @test occursin("  data: materialized", multi_display)

    @test PowerIO.bus_type_code("PQ") == 1
    @test PowerIO.bus_type_code("PV") == 2
    @test PowerIO.bus_type_code("REF") == 3
    @test PowerIO.bus_type_code("ISOLATED") == 4
    @test_throws ArgumentError PowerIO.bus_type_code("SLACK")
end

# NOTE: the "OperatingPointSeries reserved skeleton" testset that used to
# live here is deleted. It tested a placeholder API —
# `OperatingPointSeries`, `TimeAxis`, `ElementUpdate`,
# `operating_point_series`, `materialize_operating_point_series` — none of
# which exist any more in any form (not even unexported). The real type
# family it was reserving a name for has shipped: `TimeSeries{T}` /
# `ScenarioSet{T}` / `OperatingPoint{N}`, backed by the module surface and
# reachable through ordinary `parse_file`/`parse_bytes`. See "parse_file
# value family dispatch" below for its replacement coverage, including the
# one-based `select_state(m; time=)` contract the deleted testset could not
# have exercised (there was nothing behind it to select from).

@testset "parse_file value family dispatch" begin
    if !PowerIO.library_available()
        @test_skip parse_file("case9.m")
    else
        data = joinpath(@__DIR__, "data")

        # parse_file detects the balanced vs multiconductor kind from the
        # source and returns the exactly typed module — no value_type
        # keyword, no type-marker form.
        balanced = parse_file(joinpath(data, "case9.m"))
        @test typeof(balanced) === PioModule{BalancedNetwork}
        @test kind(balanced) == "balanced_network"

        dist_fixture = joinpath(data, "dist", "switch.dss")
        if PowerIO.dist_available() && isfile(dist_fixture)
            multi = parse_file(dist_fixture)
            @test typeof(multi) === PioModule{MulticonductorNetwork}
            @test kind(multi) == "multiconductor_network"
        end

        # write_str on an unchanged parsed module echoes the retained source
        # bytes exactly.
        @test write_str(balanced; format="matpower") == read(joinpath(data, "case9.m"), String)

        # diagnostics(m) is the module's findings as native records.
        d = diagnostics(balanced)
        @test d isa Vector{Diagnostic}
        @test all(x -> x.severity isa Symbol, d)

        # The multiline text/plain form adds the module's own element counts
        # beyond the single line compact form.
        compact = sprint(show, balanced)
        multiline = sprint(show, MIME"text/plain"(), balanced)
        @test multiline != compact
        @test startswith(multiline, compact)
        @test occursin("buses", multiline)

        # select_state is one based, matching every other Julia axis
        # (StoredModule's export_state, the C ABI, and every other language
        # binding are zero based instead). Build a genuine
        # PioModule{TimeSeries{OperatingPoint{BalancedNetwork}}} by feeding a
        # stored document through the same public parse_bytes a consumer
        # reading a `.pio.json` file would use.
        network_json = JSON3.read(to_json(balanced.value))
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
        series = parse_bytes(codeunits(legacy); name="legacy.pio.json")
        @test typeof(series) === PioModule{TimeSeries{OperatingPoint{BalancedNetwork}}}
        @test kind(series) == "balanced_operating_point_time_series"
        original_pg = Float64(first(PowerIO.generators(balanced.value)).pg)
        first_point = select_state(series; time=1)
        @test typeof(first_point) === PioModule{BalancedNetwork}
        @test Float64(first(PowerIO.generators(first_point.value)).pg) ≈ original_pg
        second_point = select_state(series; time=2)
        @test Float64(first(PowerIO.generators(second_point.value)).pg) ≈ 95.0
        @test_throws ErrorException select_state(series; time=0)  # one based: 0 is out of range
        @test_throws ErrorException select_state(series)          # exactly one of time/scenario
        @test_throws ErrorException select_state(series; time=1, scenario="x")

        # A gridfm scenario set selects by scenario id string instead.
        gridfm_dir = joinpath(data, "case14_gridfm", "raw")
        if PowerIO.gridfm_available() && isdir(gridfm_dir)
            scenarios = parse_file(gridfm_dir; format="gridfm")
            @test typeof(scenarios) === PioModule{ScenarioSet{BalancedNetwork}}
            selected = select_state(scenarios; scenario="0")
            @test typeof(selected) === PioModule{BalancedNetwork}
        end
    end
end

@testset "write_file's default format echoes the parsed source" begin
    if !PowerIO.library_available()
        @test_skip "library unavailable"
    else
        data = joinpath(@__DIR__, "data")
        m = parse_file(joinpath(data, "case9.m"))

        # inspect_json only started carrying source_format partway through
        # 1.0 development; skip cleanly against an older artifact instead
        # of failing on a fix this suite predates.
        if source_format(m) === nothing
            @test_skip "the resolved library's inspect report predates source_format"
        else
            @test source_format(m) == "matpower"
            @test occursin("matpower", sprint(show, m))
            tmp = tempname() * ".m"
            write_file(m, tmp)  # no format keyword: the module's own source
            @test read(tmp, String) == read(joinpath(data, "case9.m"), String)
            rm(tmp; force=true)

            dist_fixture = joinpath(data, "dist", "switch.dss")
            if PowerIO.dist_available() && isfile(dist_fixture)
                dn = parse_file(dist_fixture)
                @test source_format(dn) == "dss"
                @test occursin("dss", sprint(show, dn))
                tmp_dss = tempname() * ".dss"
                write_file(dn, tmp_dss)
                # DSS writes as a directory (one file inside, name not
                # pinned here) rather than a flat file at the given path.
                written = isdir(tmp_dss) ? only(readdir(tmp_dss; join=true)) : tmp_dss
                @test read(written, String) == read(dist_fixture, String)
                rm(tmp_dss; force=true, recursive=true)
            end
        end
    end
end

@testset "parse_bytes" begin
    if !PowerIO.library_available()
        @test_skip parse_bytes(UInt8[])
    else
        # The byte entry point takes an explicit length, so it needs no NUL
        # and can carry binary. Against a text case it must agree with the
        # path parse.
        path = joinpath(@__DIR__, "data", "case9.m")
        from_path = parse_file(path).value
        from_bytes = parse_bytes(read(path); format="matpower").value
        @test from_bytes isa BalancedNetwork
        @test length(from_bytes.data.buses) == length(from_path.data.buses)
        @test length(from_bytes.data.branches) == length(from_path.data.branches)

        # A read-only view of the same bytes works: the binding copies what it must
        # before the ccall rather than assuming a Vector{UInt8}.
        @test parse_bytes(view(read(path), :); format="matpower").value isa BalancedNetwork

        # parse_bytes(io::IO) reads the stream once and parses the bytes; it
        # must agree with the path and Vector{UInt8} forms.
        io_value = open(path) do io
            parse_bytes(io; format="matpower").value
        end
        @test PowerIO.n_buses(io_value) == PowerIO.n_buses(from_path)

        # Bytes a text format cannot decode surface as that, not as a bad case.
        @test_throws PowerIOCError parse_bytes(UInt8[0xff, 0xfe, 0x00]; format="matpower")

        # A malformed source's PowerIOCError carries native diagnostics, not
        # just a rendered message.
        err = try
            parse_bytes(codeunits("not a case"); format="matpower")
            nothing
        catch e
            e
        end
        @test err isa PowerIOCError
        @test !isempty(err.code)
        @test err.diagnostics isa Vector{Diagnostic}
    end
end

@testset "PowerWorld byte paths" begin
    # PowerWorld binary has no text form, so parse_bytes with "pwb" is the only
    # in-memory route to it, and neither PowerWorld path was covered here. The
    # fixtures are 1.5 MB against 528 KB of test/data, so read them out of the
    # powerio checkout the C library was built from instead of vendoring them:
    # POWERIO_CAPI points at <root>/target/release/libpowerio_capi.<ext>.
    capi = get(ENV, "POWERIO_CAPI", "")
    custom_target_dir = haskey(ENV, "CARGO_TARGET_DIR")
    root = isempty(capi) ? "" : dirname(dirname(dirname(capi)))
    dir = isempty(root) ? "" : joinpath(root, "tests", "data", "powerworld")
    pwb_path = joinpath(dir, "ACTIVSg200.pwb")
    aux_path = joinpath(dir, "ACTIVSg200.aux")
    mat_path = joinpath(dir, "case_ACTIVSg200.m")
    found = !isempty(dir) && all(isfile, (pwb_path, aux_path, mat_path))
    # CI builds the library inside a powerio checkout, so a miss there is lost
    # coverage rather than a missing sibling checkout. Assert it rather than
    # skip — unless CARGO_TARGET_DIR redirected the build tree, in which case
    # the <root> guess three parents above the dylib need not land there.
    isempty(capi) || custom_target_dir || @test found

    if !(found && PowerIO.library_available())
        @info "PowerWorld fixtures not found next to POWERIO_CAPI; skipping the byte path tests" custom_target_dir
        @test_skip "PowerWorld fixtures unavailable"
    else
        pwb = parse_bytes(read(pwb_path); format="pwb").value
        aux = parse_bytes(read(aux_path); format="aux").value
        mat = parse_file(mat_path).value

        # Each path reaches its own reader rather than a text fallback.
        @test PowerIO.source_format(pwb) == "powerworld-pwb"
        @test PowerIO.source_format(aux) == "powerworld"

        # The .aux and .pwb are one same day export of one case, so they agree
        # element for element.
        for field in (:buses, :branches, :generators, :loads, :shunts)
            @test length(getproperty(pwb.data, field)) == length(getproperty(aux.data, field))
        end
        @test PowerIO.n_buses(pwb) == PowerIO.n_buses(aux) == 200
        @test PowerIO.n_branches(pwb) == PowerIO.n_branches(aux) == 246
        @test PowerIO.base_mva(pwb) == PowerIO.base_mva(aux) == 100.0

        # The MATPOWER sibling is an earlier revision of the same case: same bus
        # table and same generators, one line short. Pin that one line so a
        # reader regression cannot pass as a revision difference.
        @test Set(b.id for b in pwb.data.buses) == Set(b.id for b in mat.data.buses)
        @test length(pwb.data.generators) == length(mat.data.generators) == 49
        # Sorted: the two exports carry the same lines in a different record order.
        endpoints(net) = sort([(br.from, br.to) for br in net.data.branches])
        @test endpoints(aux) == endpoints(pwb)
        @test setdiff(endpoints(pwb), endpoints(mat)) == [(82, 64)]
        @test isempty(setdiff(endpoints(mat), endpoints(pwb)))

        # Truncated bytes raise instead of returning a partial network. The
        # binary reader validates its table chain, so a cut past the last case
        # table reads as a complete case; both cuts below land inside the chain.
        raw = read(pwb_path)
        @test_throws PowerIOCError parse_bytes(raw[1:16]; format="pwb")
        @test_throws PowerIOCError parse_bytes(raw[1:65536]; format="pwb")
        text = read(aux_path)
        @test_throws PowerIOCError parse_bytes(text[1:(length(text) ÷ 2)]; format="aux")
    end
end

@testset "conversion findings are structured records" begin
    # A case whose conversion loses nothing reports an empty findings list,
    # and every finding is a native Diagnostic, not a rendered string.
    net = parse_file(joinpath(@__DIR__, "data", "case9.m")).value
    _, clean = PowerIO.to_format(net, "matpower")
    @test clean isa Vector{Diagnostic}
    @test isempty(clean)

    # Every finding survives regardless of how many there are, and each
    # carries its own code/severity/message rather than a truncatable
    # rendered buffer (the pre-ABI-5 64 KiB guess and its "may be
    # truncated" marker are both gone: there is no cap to approach).
    _, lossy = PowerIO.to_format(net, "psse")
    @test lossy isa Vector{Diagnostic}
    @test !isempty(lossy)
    d = first(lossy)
    @test d isa Diagnostic
    @test !isempty(d.code)
    @test d.severity isa Symbol
    @test !isempty(d.message)
    @test :code in propertynames(d)

    # `string(d)` (and `show`) render as "SEVERITY code: message", so a
    # consumer wanting the old rendered line still has it, but branches on
    # `.code` for identity.
    @test occursin(d.code, string(d))
    @test occursin(d.message, string(d))
    @test startswith(string(d), uppercase(String(d.severity)))

    # Every finding of a real conversion round trips through the same fields.
    _, from_file = PowerIO.convert_file(joinpath(@__DIR__, "data", "case9.m"), "psse")
    @test from_file isa Vector{Diagnostic}
    @test Set(d.code for d in from_file) == Set(d.code for d in lossy)
end

@testset "schema version contract" begin
    # The ABI integers do not cover document formats. Check the versions
    # the library reports against the mirrored constants.
    if !PowerIO.library_available()
        @test_skip "library unavailable"
    elseif !PowerIO._exports_symbol(:pio_schema_versions_json)
        # Older binaries lack the entry point; the ABI gate governs them.
        @test_skip "library predates pio_schema_versions_json"
    else
        lib = PowerIO._lib()
        s = ccall(PowerIO._library_symbol(lib, :pio_schema_versions_json), Cstring, ())
        @test s != C_NULL
        if s != C_NULL
            doc = JSON3.read(PowerIO._take_string(lib, s))

            @test haskey(doc, :powerio_version)
            @test UInt32(doc.abi) in PowerIO._ACCEPTED_ABI_VERSIONS

            # The per document lineages are gone: one powerio version covers
            # every document the library authors.
            @test get(doc, :package, nothing) === nothing
            @test get(doc, :arrow, nothing) === nothing

            # The exported probe reads the same document.
            sv = schema_versions()
            @test sv.powerio_version == doc.powerio_version
            @test sv.abi == doc.abi
            @test sv.bmopf_schema == get(doc, :bmopf_schema, nothing)
            # module_schema is newer than the entry point itself; an older
            # library can report schema_versions() without it yet.
            if haskey(doc, :module_schema)
                @test sv.module_schema == (; name = doc.module_schema.name, version = doc.module_schema.version)
                @test sv.module_schema.version == 1
            else
                @test sv.module_schema === nothing
            end

            # Every top level key the raw report carries has a matching
            # field on the returned NamedTuple, so a future key the C side
            # adds is caught here instead of silently missing its accessor.
            # A subset, not equality: an older library's report can carry
            # fewer of the fields this binding knows, which schema_versions()
            # already reports as `nothing`.
            @test issubset(Set(keys(doc)), Set(PowerIO._DOCUMENT_VERSION_FIELDS))
        end
    end
end

@testset "build_info agrees with the single answer probes" begin
    # One report where the rest of this file asks one question at a time. It is
    # only useful if it says the same things, so check it against them.
    if !PowerIO.library_available()
        @test_skip "library unavailable"
    elseif !PowerIO._exports_symbol(:pio_build_info)
        @test_skip "library predates pio_build_info"
    else
        info = PowerIO.build_info()
        @test info !== nothing
        @test UInt32(info.abi) in PowerIO._ACCEPTED_ABI_VERSIONS
        @test info.abi == PowerIO.abi_version()
        @test info.powerio_version == PowerIO.library_version()
        @test info.powerio_version == schema_versions().powerio_version

        # `features` is what the library was compiled with, which is the same
        # question `pio_has_feature` answers one name at a time.
        feats = info.features
        for name in (:arrow, :matrix, :gridfm, :dist, :prob)
            @test haskey(feats, name)
            @test feats[name] isa Bool
            @test feats[name] == PowerIO.has_feature(String(name))
        end

        # The Julia predicates report "usable from Julia": symbol present and,
        # for dist, the feature handshake passed. Matrix tables also need arrow,
        # which is why that one is a conjunction.
        f = PowerIO.features()
        @test f.arrow == feats.arrow
        @test f.gridfm == feats.gridfm
        @test f.dist == feats.dist
        @test f.prob == feats.prob
        @test f.matrix == (feats.arrow && feats.matrix)

        # Foreign schema versions belong to whoever owns the schema, so they
        # travel here rather than in the ABI integer, and both entry points
        # must report the same vintage. dist_capabilities() (which used to
        # cross-check this against a second source) is gone from the C ABI
        # itself (see the removal note in test_dist.jl); build_info and
        # schema_versions are the only two surfaces left to agree.
        @test haskey(info, :foreign_schemas)
        @test get(info.foreign_schemas, :bmopf, nothing) == schema_versions().bmopf_schema

        # The tokens that prefix an errbuf message, for a caller that branches
        # on the kind of failure instead of matching prose. The set may grow, so
        # assert the five documented ones are present rather than pinning it.
        cats = info.error_categories
        @test cats isa AbstractVector
        @test all(c -> c isa AbstractString && !isempty(c), cats)
        # "unknown_format" was renamed "request" (matching the REQUEST.*
        # diagnostic code namespace: REQUEST.FORMAT.UNKNOWN and its siblings
        # like REQUEST.STATE.NOT_A_COLLECTION are broader than just format).
        for token in ("io", "request", "parse", "data", "output")
            @test token in cats
        end
        @test allunique(cats)
    end
end

@testset "JSON family classification" begin
    if !PowerIO.library_available()
        @test_skip "library unavailable"
    elseif !PowerIO._exports_symbol(:pio_classify_str)
        @test_skip "library predates pio_classify_str"
    else
        # The five outcomes the header documents. The binding keeps the domain
        # and drops the format after the colon. :module replaced :package: a
        # stored `.pio.json` document is a "module" now, not a "package".
        @test PowerIO._classify_family("""{"baseMVA":100.0,"branch":{}}""") === :transmission
        @test PowerIO._classify_family("""{"data_model":"ENGINEERING"}""") === :distribution
        @test PowerIO._classify_family("""{"model_kind":"balanced","model":{}}""") === :module
        # Strong markers from both domains at once.
        @test PowerIO._classify_family("""{"baseMVA":100.0,"line":{}}""") === :ambiguous
        @test PowerIO._classify_family("""{"unrelated":1}""") === :unknown
        # Not a JSON object, and not JSON at all.
        @test PowerIO._classify_family("[1, 2]") === :unknown
        @test PowerIO._classify_family("not json") === :unknown
        @test PowerIO._classify_family("") === :unknown

        # Size then fill: `pio_classify_str` returns the full length against a
        # NULL buffer, which is what the binding sizes its allocation from. No
        # enumerated token exceeds the 64 bytes the old fixed buffer held, so
        # this is the only place the size query is observable.
        lib = PowerIO._lib()
        n = ccall(PowerIO._library_symbol(lib, :pio_classify_str), Csize_t,
                  (Cstring, Ptr{UInt8}, Csize_t), """{"baseMVA":100.0}""", C_NULL, Csize_t(0))
        @test n == ncodeunits("transmission:powermodels-json")
    end
end
