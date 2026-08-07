@testset "public API loads" begin
    # The module must load with no C library present (the binding is lazy),
    # and its public API must exist.
    for sym in (:BalancedNetwork, :parse_file, :parse_str, :from_json, :convert_file,
                :convert_str, :to_format, :to_normalized, :to_normalized_with_options,
                :to_json, :to_dense, :to_matpower, :to_arrow, :calc_admittance_matrix,
                :calc_susceptance_matrix, :calc_incidence_matrix, :calc_bprime_matrix,
                :calc_bdoubleprime_matrix, :ArrowTable,
                :write_pypsa_csv_folder,
                :to_powermodels, :from_powermodels, :to_powerdata,
                :parse_ac_power_data, :LoadSeries, :read_load_series, :n_periods,
                :read_gridfm, :read_gridfm_scenarios,
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
                :has_feature, :arrow_catalog,
                :MulticonductorNetwork, :dist_available, :dist_abi_version,
                :dist_capabilities, :to_graph)
        @test isdefined(PowerIO, sym)
    end
    @test isdefined(PowerIO, :Network) # deprecated compatibility binding
    @test isdefined(PowerIO, :DistNetwork) # deprecated compatibility binding
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
    @test isdefined(PowerIO, :NetworkHandle)  # deprecated alias of BalancedNetworkHandle
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

@testset "warning buffer truncation" begin
    # The per-call warn channel is a fixed-size buffer the library fills and
    # cuts at a byte offset, not at a line boundary, and it returns no length.
    # These pin the two behaviors that follow: a full-but-clean fill is not
    # mistaken for truncation, and a truncated fill never hands back the
    # fragment it cut. There was no coverage here before v0.8.0 made the
    # writers chatty enough to reach the cap on ordinary cases.
    pack(text, cap) = (buf = zeros(UInt8, cap); b = codeunits(text);
                       copyto!(buf, 1, b, 1, min(length(b), cap - 1)); buf)

    # Well under the cap: every line survives, no marker.
    small = PowerIO._warn_lines(pack("first\nsecond\nthird", 512); capped=true)
    @test small == ["first", "second", "third"]

    # Filled to the cap mid-word: the fragment is dropped and the list is
    # explicitly marked short, so a caller matching warning text can never
    # match half a message.
    cap = 64
    long = join(("warning number $i is quite wordy" for i in 1:20), "\n")
    cut = PowerIO._warn_lines(pack(long, cap); capped=true)
    @test occursin("truncated at $cap bytes", last(cut))
    @test all(w -> !occursin("truncated", w), cut[1:end-1])
    @test all(w -> occursin("is quite wordy", w), cut[1:end-1])

    # A fill that lands exactly on a newline kept a complete final line, so
    # nothing is dropped beyond adding the marker.
    exact = "aa\nbb\n"
    onnl = PowerIO._warn_lines(pack(exact, ncodeunits(exact) + 1); capped=true)
    @test onnl[1:2] == ["aa", "bb"]

    # capped=false is the handle-backed channel, which sizes then fills and so
    # cannot truncate: no marker, and the fragment is left alone rather than
    # dropped, because on that channel a full buffer is not evidence of a cut.
    uncapped = PowerIO._warn_lines(pack(long, cap); capped=false)
    @test all(w -> !occursin("truncated", w), uncapped)
    @test length(uncapped) == length(cut)
end

@testset "wire version contract" begin
    # The ABI integers do not cover document formats: powerio's own policy is
    # that new data arrives through versioned payloads rather than signature
    # changes. So a library can pass both ABI handshakes while speaking a
    # `.pio.json` lineage this binding cannot read — which is exactly what
    # v0.8.0 did, with the mismatch surfacing only after release.
    #
    # `pio_wire_versions_json` closes that: every version the library stamps
    # into a document is reported, and the constants mirrored here are checked
    # against it rather than trusted.
    if !PowerIO.library_available()
        @test_skip "library unavailable"
    elseif !PowerIO._exports_symbol(:pio_wire_versions_json)
        # Older binaries have no such entry point; the ABI gate governs them,
        # as it did before.
        @test_skip "library predates pio_wire_versions_json"
    else
        lib = PowerIO._lib()
        s = ccall(PowerIO._library_symbol(lib, :pio_wire_versions_json), Cstring, ())
        @test s != C_NULL
        doc = JSON3.read(PowerIO._take_string(lib, s))

        @test haskey(doc, :wire_versions)
        @test doc.abi == PowerIO.PIO_ABI_VERSION

        # The one this binding mirrors as a source constant. Compare the
        # lineage (major.minor while the major is 0) because that is the
        # reader's own acceptance rule; a patch bump is additive.
        if doc.package !== nothing
            got = VersionNumber(String(doc.package))
            want = VersionNumber(PowerIO.PIO_PACKAGE_SCHEMA_VERSION)
            @test (got.major, got.minor) == (want.major, want.minor)
        end
    end
end
