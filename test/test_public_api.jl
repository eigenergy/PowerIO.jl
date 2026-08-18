@testset "public API loads" begin
    # The module must load with no C library present (the binding is lazy),
    # and its public API must exist.
    for sym in (:BalancedNetwork, :parse_file, :parse_str, :parse_bytes, :from_json, :convert_file,
                :convert_str, :to_format, :to_normalized, :to_normalized_with_options,
                :to_json, :to_dense, :to_matpower, :to_arrow, :calc_admittance_matrix,
                :calc_susceptance_matrix, :calc_incidence_matrix, :calc_bprime_matrix,
                :calc_bdoubleprime_matrix, :ArrowTable,
                :write_pypsa_csv_folder,
                :to_powermodels, :from_powermodels, :to_powerdata,
                :parse_ac_power_data, :LoadSeries, :read_load_series, :n_periods,
                :demands_mw, :read_gridfm, :read_gridfm_scenarios,
                :parse_goc3_json, :goc3_scopf_data, :ScopfInstance,
                :goc3_status_flags, :goc3_add_status_flags!, :goc3_interval_bounds,
                :parse_scopf, :scopf_available,
                :NetworkPackage, :CompilerPackage, :to_package, :from_package, :read_package,
                :write_package, :package_model_kind, :package_available,
                :validate_package, :package_validation, :package_diagnostics,
                :package_operating_points, :package_study, :set_operating_points,
                :materialize_operating_point, :materialize_study_commit,
                :multiconductor_to_balanced_preflight,
                :lower_multiconductor_to_balanced,
                :arrow_available, :gridfm_available, :matrix_available, :features,
                :has_feature, :schema_versions, :build_info, :arrow_catalog,
                :MulticonductorNetwork, :dist_available, :dist_abi_version,
                :dist_capabilities, :to_graph)
        @test isdefined(PowerIO, sym)
    end
    # The 0.3.0 compatibility bindings are gone in 0.9.0.
    @test !isdefined(PowerIO, :Network)
    @test !isdefined(PowerIO, :DistNetwork)
    @test !isdefined(PowerIO, :dist_graph)
    # The accessor API the ecosystem bridges read is unexported but must exist.
    for sym in (:n_buses, :n_branches, :n_gens, :n_switches, :base_mva, :network_name,
                :source_format, :reference_bus_id, :reference_bus_indices,
                :n_components, :is_radial, :bus_type_code, :warnings,
                :buses, :generators, :branches, :loads, :shunts, :storage, :hvdc,
                :lines, :linecodes, :switches, :transformers, :sources,
                :ibrs, :control_profiles, :capacitors, :untyped,
                :base_frequency,
                :abi_version, :library_version, :library_available)
        @test isdefined(PowerIO, sym)
    end
    @test isdefined(PowerIO, :AdmittanceMatrix)
    @test :AdmittanceMatrix ∉ names(PowerIO)
    # LoadSeries is the exported ExaModelsPower multiperiod-load bridge; the general
    # OperatingPointSeries name is reserved for the coming format-neutral series.
    @test :LoadSeries ∈ names(PowerIO)
    @test :goc3_scopf_data ∈ names(PowerIO)
    @test :ScopfInstance ∈ names(PowerIO)
    # The individual GOC3 index-set builders behind goc3_scopf_data are internal:
    # defined but unexported (consumers call goc3_scopf_data).
    for sym in (:_goc3_static_data, :_goc3_energy_windows, :_goc3_price_blocks,
                :_goc3_ac_contingency_survivors, :_goc3_dc_contingency_flows)
        @test isdefined(PowerIO, sym)
        @test sym ∉ names(PowerIO)
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
    @test !isdefined(PowerIO, :NetworkHandle)
    @test PowerIO._lib() isa AbstractString
    @test PowerIO.PIO_ABI_VERSION isa Unsigned
    @test PowerIO.PIO_DIST_ABI_VERSION isa Unsigned

    f = PowerIO.features()
    @test propertynames(f) == (:arrow, :matrix, :gridfm, :dist, :package, :prob)
    @test f.arrow == PowerIO.arrow_available()
    @test f.matrix == PowerIO.matrix_available()
    @test f.gridfm == PowerIO.gridfm_available()
    @test f.dist == PowerIO.dist_available()
    @test f.package == PowerIO.package_available()
    @test f.prob == PowerIO.scopf_available()
    # pio_has_feature reports what the library was compiled with; an unknown
    # feature name is false, never an error, and "package" aliases the C
    # feature name "pkg" (matching the features() field).
    @test PowerIO.has_feature("no-such-feature") == false
    @test PowerIO.has_feature("package") == PowerIO.has_feature("pkg")
    if PowerIO.library_available()
        @test PowerIO.has_feature("dist") isa Bool
        PowerIO._exports_symbol(:pio_has_feature) &&
            @test PowerIO.has_feature("pkg") == PowerIO.package_available()
    end

    lib = PowerIO._lib()
    PowerIO.set_library!(lib)
    @test PowerIO._lib() == lib
    PowerIO.clear_library!()
    @test PowerIO._lib() isa AbstractString
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
    @test one_ref.warnings == String[]
    @test sprint(show, one_ref) == "BalancedNetwork{InMemory}: 3 buses, 0 branches, 0 gens"
    balanced_display = sprint(show, MIME"text/plain"(), one_ref)
    @test occursin("BalancedNetwork{InMemory}", balanced_display)
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
    @test PowerIO.warnings(mn) == ["w1"]
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

@testset "OperatingPointSeries reserved skeleton" begin
    # The general format-neutral series is a reserved, unexported skeleton until a
    # typed binding backs it (the JSON-level attach is set_operating_points). Its
    # component structs are constructible, but every entry point that would build
    # or materialize a series throws until then, so a throwing constructor is
    # never advertised as usable.
    for sym in (:OperatingPointSeries, :TimeAxis, :ElementUpdate, :OperatingPoint,
                :operating_point_series, :materialize_operating_point_series)
        @test isdefined(PowerIO, sym)
        @test sym ∉ names(PowerIO)
    end

    ta = PowerIO.TimeAxis(2, [1.0, 1.0], ["t1", "t2"])
    @test ta.periods == 2
    up = PowerIO.ElementUpdate(:bus, "bus_1", nothing, :pd, 1.0)
    @test up.table === :bus
    pt = PowerIO.OperatingPoint(0, [up])
    @test pt.index == 0 && length(pt.updates) == 1

    # The inner constructor throws: a series cannot yet be built from Julia.
    @test_throws ErrorException PowerIO.OperatingPointSeries(ta, [pt])
    @test_throws ErrorException PowerIO.OperatingPointSeries(ta, PowerIO.OperatingPoint[])
    @test_throws ErrorException PowerIO.operating_point_series(ta, [pt])
    @test_throws ErrorException PowerIO.materialize_operating_point_series(nothing)
end

@testset "parse_bytes" begin
    # The byte entry point takes an explicit length, so it needs no NUL and can
    # carry binary. Against a text case it must agree with the path parse.
    path = joinpath(@__DIR__, "data", "case9.m")
    from_path = parse_file(path)
    from_bytes = parse_bytes(read(path), "matpower")
    @test from_bytes isa BalancedNetwork
    @test length(from_bytes.data.buses) == length(from_path.data.buses)
    @test length(from_bytes.data.branches) == length(from_path.data.branches)

    # A read-only view of the same bytes works: the binding copies what it must
    # before the ccall rather than assuming a Vector{UInt8}.
    @test parse_bytes(view(read(path), :), "matpower") isa BalancedNetwork

    # Bytes a text format cannot decode surface as that, not as a bad case.
    @test_throws ErrorException parse_bytes(UInt8[0xff, 0xfe, 0x00], "matpower")

    # The type marker form is symmetric with parse_str / parse_file.
    @test parse_bytes(BalancedNetwork, read(path), "matpower") isa BalancedNetwork
end

@testset "conversion warnings are not truncated" begin
    # ABI 5 hands the warning list back as an owned string through an out
    # pointer. The 64 KiB guess this binding used to make, and the "may be
    # truncated" marker it appended near the cap, are both gone: there is no
    # cap to approach.
    @test !isdefined(PowerIO, :_WARNLEN)
    @test !isdefined(PowerIO, :_warnbuf)
    @test !isdefined(PowerIO, :_warn_lines)

    # A case whose conversion loses nothing reports an empty list, not an
    # empty string, and the C side signals that with a NULL out pointer.
    net = PowerIO.parse_file(joinpath(@__DIR__, "data", "case9.m"))
    _, clean = PowerIO.to_format(net, "matpower")
    @test clean isa Vector{String}

    # Every warning survives regardless of how many there are. A lossy target
    # produces one per element, which is what used to overrun the guess.
    _, lossy = PowerIO.to_format(net, "psse")
    @test lossy isa Vector{String}
    @test all(w -> !occursin("may be truncated", w), lossy)
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
            @test doc.abi == PowerIO.PIO_ABI_VERSION

            # The per document lineages are gone: one powerio version covers
            # every document the library authors.
            @test get(doc, :package, nothing) === nothing
            @test get(doc, :arrow, nothing) === nothing

            # The exported probe reads the same document.
            sv = schema_versions()
            @test sv.powerio_version == doc.powerio_version
            @test sv.abi == doc.abi
            @test sv.bmopf_schema == get(doc, :bmopf_schema, nothing)
        end
    end
end
