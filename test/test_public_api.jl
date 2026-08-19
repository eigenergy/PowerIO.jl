@testset "public API loads" begin
    # The module must load with no C library present (the binding is lazy),
    # and its public API must exist.
    for sym in (:BalancedNetwork, :parse_file, :parse_str, :parse_bytes, :from_json, :convert_file,
                :convert_str, :to_format, :to_normalized, :set_library!, :clear_library!,
                :to_json, :to_dense, :to_matpower, :to_arrow, :calc_admittance_matrix,
                :calc_susceptance_matrix, :calc_incidence_matrix, :calc_bprime_matrix,
                :calc_bdoubleprime_matrix, :ArrowTable,
                :write_pypsa_csv_folder, :Diagnostic,
                :to_powermodels, :from_powermodels, :to_powerdata,
                :parse_ac_power_data, :LoadSeries, :read_load_series, :n_periods,
                :demands_mw, :read_gridfm, :read_gridfm_scenarios,
                :parse_goc3_json, :goc3_scopf_data, :ScopfInstance,
                :goc3_status_flags, :goc3_add_status_flags!, :goc3_interval_bounds,
                :parse_scopf, :scopf_available,
                :NetworkPackage, :to_package, :from_package, :read_package,
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
    # The accessor API the ecosystem bridges read must exist. Most of it stays
    # unexported because the names collide with the packages a consumer loads
    # beside this one; `n_buses` and `warnings` are the exported two.
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
    # The docs and the show methods name these unqualified, so they are exported.
    for sym in (:set_library!, :clear_library!, :warnings, :n_buses, :Diagnostic)
        @test sym ∈ names(PowerIO)
    end
    # 0.9.0 removed the last of the 0.3.0 compatibility aliases and the
    # normalize spelling whose only reason to exist was the retired C dispatch key.
    @test !isdefined(PowerIO, :CompilerPackage)
    @test !isdefined(PowerIO, :to_normalized_with_options)
    # LoadSeries is the exported ExaModelsPower multiperiod-load bridge; the general
    # OperatingPointSeries name is reserved for the coming format-neutral series.
    @test :LoadSeries ∈ names(PowerIO)
    @test :goc3_scopf_data ∈ names(PowerIO)
    @test :ScopfInstance ∈ names(PowerIO)
    @test :DeviceClassLayout ∈ names(PowerIO)
    # The Julia GOC3 projection is retired: the Rust core projects the instance
    # and goc3_scopf_data types its rows. Nothing internal survives to leak.
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

@testset "PowerWorld byte paths" begin
    # PowerWorld binary has no text form, so parse_bytes with "pwb" is the only
    # in-memory route to it, and neither PowerWorld path was covered here. The
    # fixtures are 1.5 MB against 528 KB of test/data, so read them out of the
    # powerio checkout the C library was built from instead of vendoring them:
    # POWERIO_CAPI points at <root>/target/release/libpowerio_capi.<ext>.
    capi = get(ENV, "POWERIO_CAPI", "")
    root = isempty(capi) ? "" : dirname(dirname(dirname(capi)))
    dir = isempty(root) ? "" : joinpath(root, "tests", "data", "powerworld")
    pwb_path = joinpath(dir, "ACTIVSg200.pwb")
    aux_path = joinpath(dir, "ACTIVSg200.aux")
    mat_path = joinpath(dir, "case_ACTIVSg200.m")
    found = !isempty(dir) && all(isfile, (pwb_path, aux_path, mat_path))
    # CI builds the library inside a powerio checkout, so a miss there is lost
    # coverage rather than a missing sibling checkout. Assert it rather than skip.
    isempty(capi) || @test found

    if !(found && PowerIO.library_available())
        @info "PowerWorld fixtures not found next to POWERIO_CAPI; skipping the byte path tests"
        @test_skip "PowerWorld fixtures unavailable"
    else
        pwb = parse_bytes(read(pwb_path), "pwb")
        aux = parse_bytes(read(aux_path), "aux")
        mat = parse_file(mat_path)

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
        @test_throws ErrorException parse_bytes(raw[1:16], "pwb")
        @test_throws ErrorException parse_bytes(raw[1:65536], "pwb")
        text = read(aux_path)
        @test_throws ErrorException parse_bytes(text[1:(length(text) ÷ 2)], "aux")
    end
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
    @test clean isa Vector{Diagnostic}
    @test isempty(clean)

    # Every warning survives regardless of how many there are. A lossy target
    # produces one per element, which is what used to overrun the guess.
    _, lossy = PowerIO.to_format(net, "psse")
    @test lossy isa Vector{Diagnostic}
    @test all(w -> !occursin("may be truncated", w), lossy)
end

@testset "conversion findings carry their record" begin
    # The conversion entry points return the diagnostic document, not rendered
    # lines, so a consumer branches on `code` without splitting a string.
    net = PowerIO.parse_file(joinpath(@__DIR__, "data", "case9.m"))
    _, lossy = PowerIO.to_format(net, "psse")
    @test !isempty(lossy)
    d = first(lossy)
    @test d isa Diagnostic
    @test d isa AbstractString
    @test !isempty(String(d.code))
    @test !isempty(String(d.severity))
    @test !isempty(String(d.message))
    @test d.record isa JSON3.Object
    @test :code in propertynames(d)

    # It reads as the `CODE: message` line it always did.
    @test String(d) == string(d.code, ": ", d.message)
    @test d == string(d.code, ": ", d.message)
    @test startswith(d, String(d.code))
    @test split(d, ": "; limit = 2)[1] == String(d.code)
    @test occursin(String(d.message), join(lossy, "\n"))

    # Every finding of a real conversion round trips through the same fields.
    _, from_file = PowerIO.convert_file(joinpath(@__DIR__, "data", "case9.m"), "psse")
    @test from_file isa Vector{Diagnostic}
    @test Set(String.(from_file)) == Set(String.(lossy))
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
        @test info.abi == PowerIO.PIO_ABI_VERSION
        @test info.abi == PowerIO.abi_version()
        @test info.powerio_version == PowerIO.library_version()
        @test info.powerio_version == schema_versions().powerio_version

        # `features` is what the library was compiled with, which is the same
        # question `pio_has_feature` answers one name at a time. The C feature
        # name is `pkg`; the Julia field name is `package`.
        feats = info.features
        for name in (:arrow, :matrix, :gridfm, :dist, :pkg, :prob)
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
        @test f.package == feats.pkg
        @test f.prob == feats.prob
        @test f.matrix == (feats.arrow && feats.matrix)

        # Foreign schema versions belong to whoever owns the schema, so they
        # travel here rather than in the ABI integer, and both entry points
        # must report the same vintage.
        @test haskey(info, :foreign_schemas)
        @test get(info.foreign_schemas, :bmopf, nothing) == schema_versions().bmopf_schema
        if PowerIO.dist_available()
            @test info.foreign_schemas.bmopf == PowerIO.dist_capabilities().bmopf_schema_version
        end

        # The tokens that prefix an errbuf message, for a caller that branches
        # on the kind of failure instead of matching prose. The set may grow, so
        # assert the five documented ones are present rather than pinning it.
        cats = info.error_categories
        @test cats isa AbstractVector
        @test all(c -> c isa AbstractString && !isempty(c), cats)
        for token in ("io", "unknown_format", "parse", "data", "output")
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
        # and drops the format after the colon.
        @test PowerIO._classify_family("""{"baseMVA":100.0,"branch":{}}""") === :transmission
        @test PowerIO._classify_family("""{"data_model":"ENGINEERING"}""") === :distribution
        @test PowerIO._classify_family("""{"model_kind":"balanced","model":{}}""") === :package
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
