@testset "loads and exposes API" begin
    # The module must load with no C library present (the binding is lazy),
    # and its public API must exist.
    for sym in (:BalancedNetwork, :parse_file, :parse_str, :from_json, :convert_file,
                :convert_str, :to_format, :to_normalized, :to_normalized_with_options,
                :to_json, :to_dense, :to_matpower, :to_arrow, :calc_admittance_matrix,
                :calc_susceptance_matrix, :calc_incidence_matrix, :calc_bprime_matrix,
                :calc_bdoubleprime_matrix, :ArrowTable,
                :write_pypsa_csv_folder,
                :to_powermodels, :from_powermodels, :to_powerdata,
                :parse_ac_power_data, :read_gridfm, :read_gridfm_scenarios,
                :parse_goc3_json, :goc3_status_flags, :goc3_add_status_flags!,
                :NetworkPackage, :CompilerPackage, :to_package, :from_package, :read_package,
                :write_package, :package_model_kind, :package_available,
                :validate_package, :package_validation, :package_diagnostics,
                :package_operating_points, :package_study,
                :materialize_operating_point, :materialize_study_commit,
                :multiconductor_to_balanced_preflight,
                :lower_multiconductor_to_balanced,
                :arrow_available, :gridfm_available, :matrix_available, :features,
                :MulticonductorNetwork, :dist_available, :dist_abi_version,
                :dist_capabilities, :to_graph)
        @test isdefined(PowerIO, sym)
    end
    @test isdefined(PowerIO, :Network) # deprecated compatibility binding
    @test isdefined(PowerIO, :DistNetwork) # deprecated compatibility binding
    @test !isdefined(PowerIO, :dist_graph)
    # The accessor API the ecosystem bridges read is unexported but must exist.
    for sym in (:n_buses, :n_branches, :n_gens, :base_mva, :network_name,
                :source_format, :reference_bus_id, :reference_bus_indices,
                :n_components, :is_radial, :bus_type_code, :warnings,
                :buses, :generators, :branches, :loads, :shunts, :storage, :hvdc,
                :lines, :linecodes, :switches, :transformers, :sources,
                :base_frequency,
                :abi_version, :library_version, :library_available)
        @test isdefined(PowerIO, sym)
    end
    @test isdefined(PowerIO, :AdmittanceMatrix)
    @test :AdmittanceMatrix ∉ names(PowerIO)
    @test isdefined(PowerIO, :NetworkHandle)  # deprecated alias of BalancedNetworkHandle
    @test PowerIO._lib() isa AbstractString
    @test PowerIO.PIO_ABI_VERSION isa Unsigned
    @test PowerIO.PIO_DIST_ABI_VERSION isa Unsigned

    f = PowerIO.features()
    @test propertynames(f) == (:arrow, :matrix, :gridfm, :dist, :package)
    @test f.arrow == PowerIO.arrow_available()
    @test f.matrix == PowerIO.matrix_available()
    @test f.gridfm == PowerIO.gridfm_available()
    @test f.dist == PowerIO.dist_available()
    @test f.package == PowerIO.package_available()

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
    @test sprint(show, mn) == "MulticonductorNetwork{dss}: 2 buses, 1 lines, 1 loads"

    @test PowerIO.bus_type_code("PQ") == 1
    @test PowerIO.bus_type_code("PV") == 2
    @test PowerIO.bus_type_code("REF") == 3
    @test PowerIO.bus_type_code("ISOLATED") == 4
    @test_throws ArgumentError PowerIO.bus_type_code("SLACK")
end
