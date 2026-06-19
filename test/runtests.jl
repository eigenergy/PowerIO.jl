using PowerIO
using Test
using JSON3
using Aqua

@testset "PowerIO" begin
    @testset "loads and exposes its surface" begin
        # The module must load with no C library present (the binding is lazy),
        # and its public surface must exist.
        for sym in (:Network, :parse_file, :parse_str, :from_json, :convert_file,
                    :convert_str, :to_format, :to_normalized, :to_json, :to_dense,
                    :to_matpower, :to_arrow, :ArrowTable, :write_pypsa_csv_folder,
                    :to_powermodels, :from_powermodels, :to_powerdata,
                    :parse_ac_power_data, :read_gridfm, :read_gridfm_scenarios,
                    :arrow_available, :gridfm_available, :DistNetwork, :dist_available)
            @test isdefined(PowerIO, sym)
        end
        # The accessor surface the ecosystem bridges read is unexported but must exist.
        for sym in (:n_buses, :n_branches, :n_gens, :base_mva, :network_name,
                    :source_format, :reference_bus_id, :reference_bus_indices,
                    :n_components, :is_radial, :bus_type_code, :warnings,
                    :buses, :generators, :branches, :loads, :shunts, :storage, :hvdc,
                    :abi_version, :library_version, :library_available)
            @test isdefined(PowerIO, sym)
        end
        @test PowerIO._lib() isa AbstractString
        @test PowerIO.PIO_ABI_VERSION isa Unsigned
    end

    @testset "pure-Julia accessors (no binary)" begin
        # `reference_bus_id` and `bus_type_code` are pure functions of the parsed JSON,
        # so build a `Network` straight from a JSON3 object and exercise every branch
        # without the native library.
        mk(buses) = PowerIO.Network(JSON3.read(JSON3.write((; buses = buses))))

        # REF at array position 2 but id 7: a "returns the index" bug would read 2;
        # the id is 7. This pins the accessor to the id field, not the position.
        one_ref = mk([(id = 4, kind = "PQ"), (id = 7, kind = "REF"), (id = 9, kind = "PV")])
        @test PowerIO.reference_bus_id(one_ref) == 7
        @test PowerIO.reference_bus_id(mk([(id = 1, kind = "REF"), (id = 2, kind = "REF")])) === nothing
        @test PowerIO.reference_bus_id(mk([(id = 1, kind = "PQ"), (id = 2, kind = "PV")])) === nothing

        @test PowerIO.bus_type_code("PQ") == 1
        @test PowerIO.bus_type_code("PV") == 2
        @test PowerIO.bus_type_code("REF") == 3
        @test PowerIO.bus_type_code("ISOLATED") == 4
        @test_throws ArgumentError PowerIO.bus_type_code("SLACK")
    end

    @testset "C ABI round trip" begin
        if !PowerIO.library_available()
            @info "libpowerio_capi not found (set POWERIO_CAPI to a local build); skipping ccall tests"
            @test_skip parse_file("case14.m")
        else
            data = joinpath(@__DIR__, "data")
            net = parse_file(joinpath(data, "case14.m"))
            @test PowerIO.n_buses(net) == 14
            @test PowerIO.n_branches(net) == 20
            @test PowerIO.n_gens(net) == 5
            @test PowerIO.base_mva(net) == 100.0
            @test PowerIO.source_format(net) == "Matpower"
            @test PowerIO.reference_bus_id(net) == 1
            @test isempty(PowerIO.storage(net))
            @test isempty(PowerIO.hvdc(net))

            # `from` hint threads through to pio_parse_file.
            net_hinted = parse_file(joinpath(data, "case14.m"); from = "matpower")
            @test PowerIO.n_buses(net_hinted) == 14

            text_in = read(joinpath(data, "case14.m"), String)
            net_from_text = parse_str(text_in, "matpower")
            @test PowerIO.n_buses(net_from_text) == 14
            @test PowerIO.source_format(net_from_text) == "Matpower"

            net_from_json = from_json(to_json(net))
            @test PowerIO.n_buses(net_from_json) == 14
            @test PowerIO.source_format(net_from_json) == "Matpower"

            # powerio-json is a first-class format token under v4: parse_str reads
            # the snapshot to_json writes, and a clean MATPOWER parse keeps no
            # handle warnings (the v4 pio_warnings accessor).
            @test PowerIO.n_buses(parse_str(to_json(net), "powerio-json")) == 14
            @test isempty(PowerIO.warnings(net))

            # EGRET and PowerModels both use .json (fixtures produced by convert_file).
            # The positive cases confirm each fixture parses under its own format; the
            # negative cases prove `from` overrides inference, since forcing the wrong
            # reader on a well-formed file fails.
            egret = parse_file(joinpath(data, "case14.egret.json"); from = "egret")
            @test PowerIO.n_buses(egret) == 14
            @test PowerIO.source_format(egret) == "EgretJson"
            pm = parse_file(joinpath(data, "case14.pm.json"); from = "powermodels")
            @test PowerIO.n_buses(pm) == 14
            @test PowerIO.source_format(pm) == "PowerModelsJson"
            @test_throws ErrorException parse_file(joinpath(data, "case14.pm.json"); from = "egret")
            @test_throws ErrorException parse_file(joinpath(data, "case14.egret.json"); from = "powermodels")

            # Same-format conversion is byte-exact and warning-free.
            text, warnings = convert_file(joinpath(data, "case14.m"), "matpower")
            @test occursin("mpc.bus", text)
            @test isempty(warnings)

            # A cross-format target exercises a second writer and the warnings vector.
            psse_text, psse_warnings = convert_file(joinpath(data, "case14.m"), "psse")
            @test !isempty(psse_text)
            @test psse_warnings isa AbstractVector{<:AbstractString}

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
            pv_ac = parse_ac_power_data(parse_str(pv_noref, "matpower"))
            @test pv_ac.ref_buses == [1]
            @test pv_ac.bus[1].type == 3

            bad_branch = replace(pv_noref, "0.01 0.1" => "NaN 0.1")
            bad_err = try
                to_powerdata(parse_str(bad_branch, "matpower"))
                nothing
            catch e
                e
            end
            @test bad_err isa ArgumentError
            @test occursin("PowerIO.to_powerdata: branch 1", sprint(showerror, bad_err))

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
            storage_net = parse_str(storage_text, "matpower")
            storage_raw_pd = to_powerdata(storage_net; filtered=false)
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
            # library's ABI version must equal the one this binding targets.
            @test PowerIO.abi_version() == PowerIO.PIO_ABI_VERSION
            @test !isempty(PowerIO.library_version())
        end
    end

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
            # they must match the dense view (case14 is one connected, looped component).
            dense = PowerIO.to_dense(net)
            @test PowerIO.n_components(net) == dense.n_components == 1
            @test PowerIO.is_radial(net) == dense.is_radial == false
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

            # Each Network-first to_* transform agrees with its path / convert counterpart.
            @test to_dense(net).gen.bus == to_dense(joinpath(data, "case14.m")).gen.bus
            @test to_dense(net).branch.x ≈ to_dense(joinpath(data, "case14.m")).branch.x
            # to_matpower(net) equals the file->MATPOWER conversion (byte-exact) and round-trips.
            @test to_matpower(net) == convert_file(joinpath(data, "case14.m"), "matpower")[1]
            @test PowerIO.n_buses(parse_file(IOBuffer(to_matpower(net)), "matpower")) == 14
            @test JSON3.read(to_json(net)).base_mva == PowerIO.base_mva(net)

            # to_json works on a handle-less Network (built straight from JSON); every
            # handle-only transform refuses it with a clear error. The guard fires before
            # any feature-specific ccall, so to_arrow throws even without the arrow build.
            jsononly = PowerIO.Network(JSON3.read(to_json(net)))
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

            # Error paths surface as Julia errors. Build the bad cases in memory.
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
        end
    end

    @testset "dense numeric surface" begin
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
            # The dense gen table lines up with the JSON view's count.
            @test d.ng == PowerIO.n_gens(parse_file(joinpath(@__DIR__, "data", "case14.m")))
        end
    end

    @testset "Arrow export (copy-out default + zero-copy opt-in)" begin
        if !(PowerIO.library_available() && PowerIO.arrow_available())
            @test_skip to_arrow("case14.m", :bus)
        else
            data = joinpath(@__DIR__, "data")
            m = joinpath(data, "case14.m")

            # Default copy=true: a NamedTuple of owned Julia Vectors, no ArrowTable.
            bus = to_arrow(m, :bus)
            @test bus isa NamedTuple
            @test bus.id isa Vector{Int64}
            @test bus.id == collect(1:14)                   # external 1-based bus ids, in order
            # Owned: mutating a returned column can't touch the producer (already
            # freed); a fresh export is unaffected, and GC after release is safe.
            bus.id[1] = -999
            GC.gc()
            @test to_arrow(m, :bus).id[1] == 1
            @test bus.id[2] == 2

            # The Arrow gen table matches the dense extractor on the shared columns.
            d = to_dense(m)
            gen = to_arrow(m, :gen)
            @test gen.bus == d.gen.bus
            @test gen.pg ≈ d.gen.pg

            # Every table's row count matches the JSON view's element count.
            net = parse_file(m)
            @test length(to_arrow(m, :shunt).bus) == length(PowerIO.shunts(net))
            @test length(to_arrow(m, :branch).from) == length(PowerIO.branches(net))

            # The Network-first method matches the path method.
            @test to_arrow(net, :bus).id == collect(1:14)

            @test_throws ArgumentError to_arrow(m, :nonesuch)

            # copy=false: the zero-copy ArrowTable path, same values. A column
            # extracted from the table roots the shared buffers on its own, so
            # it survives the table being collected (the old footgun).
            z = to_arrow(m, :bus; copy=false)
            @test z isa ArrowTable
            @test z.id == collect(1:14)
            @test z.id isa PowerIO.ArrowColumn{Int64}
            @test PowerIO.columns(z) isa NamedTuple
            # The raw unsafe_wrap view must not escape its rooting wrapper.
            @test_throws ErrorException z.id.data
            @test collect(z.id) isa Vector{Int64}
            col = z.id
            z = nothing
            GC.gc(); GC.gc()
            @test col == collect(1:14)
            col = nothing
            GC.gc()

            # close releases the producer eagerly: both release callbacks NULL
            # themselves, so a second close (and the later GC finalize) is a
            # no-op. finalize(table) stays a legal no-op for 0.1.0 callers; the
            # buffers free once the columns drop too.
            z2 = to_arrow(m, :bus; copy=false)
            b = getfield(z2, :_buffers)
            @test b.array[].release != C_NULL
            close(z2)
            @test b.array[].release == C_NULL
            @test b.schema[].release == C_NULL
            close(z2)
            finalize(z2)
            @test true
        end
    end

    @testset "gridfm reader (feature-gated)" begin
        if !(PowerIO.library_available() && PowerIO.gridfm_available())
            @test_skip read_gridfm("case14_gridfm/raw")
        else
            data = joinpath(@__DIR__, "data")
            single = joinpath(data, "case14_gridfm", "raw")

            # Read one scenario back into a Network: counts, base_mva, and
            # source_format match the source, and the lossy read reports warnings.
            r = read_gridfm(single)
            @test r.network isa Network
            @test r.scenario == 0
            @test r.warnings isa Vector{String}
            @test !isempty(r.warnings)
            # The lossy read's warnings attach to the handle (v4 pio_warnings), not
            # a per-call buffer: the synthesized-bus-ids note is the signature one.
            @test any(w -> occursin("synthesized bus ids", w), r.warnings)
            @test PowerIO.n_buses(r.network) == 14
            @test PowerIO.n_branches(r.network) == 20
            @test PowerIO.n_gens(r.network) == 5
            @test PowerIO.base_mva(r.network) == 100.0
            @test PowerIO.source_format(r.network) == "Gridfm"

            # The recovered case carries a live handle: it serializes and re-parses.
            text = to_matpower(r.network)
            @test occursin("mpc.bus", text)
            @test PowerIO.n_buses(parse_file(IOBuffer(text), "matpower")) == 14

            # The NamedTuple is positionally unpackable, mirroring Python's GridfmRead.
            net, scen, warns = read_gridfm(single)
            @test net isa Network
            @test scen == 0
            @test warns isa Vector{String}

            # A batch dataset rebuilds one Network per scenario id, ascending; a
            # specific scenario can be selected.
            batch = joinpath(data, "case14_gridfm_batch", "raw")
            reads = read_gridfm_scenarios(batch)
            @test [x.scenario for x in reads] == [0, 1]
            @test all(x -> PowerIO.n_buses(x.network) == 14, reads)
            @test read_gridfm(batch; scenario = 1).scenario == 1

            # A nonexistent dataset directory surfaces as a Julia error, not a fault.
            @test_throws ErrorException read_gridfm(joinpath(data, "no_such_gridfm"))
        end
    end

    @testset "distribution surface (feature-gated)" begin
        if !(PowerIO.library_available() && PowerIO.dist_available())
            @test_skip parse_file(DistNetwork, "switch.dss")
        else
            dss = joinpath(@__DIR__, "data", "dist", "switch.dss")

            # The distribution case shares the transmission verbs: the entry points
            # take DistNetwork as a leading type marker (the parse(T, x) idiom),
            # to_format / warnings dispatch on the handle.
            net = parse_file(DistNetwork, dss)
            @test net isa DistNetwork
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

            # The in-memory parser matches the file parser on the round trip.
            net_str = parse_str(DistNetwork, read(dss, String), "dss")
            @test first(to_format(net_str, "dss")) == read(dss, String)

            # convert_file is the one-shot path; dss -> bmopf produces JSON. The
            # Julia signature is (DistNetwork, path, to; from=...).
            bmopf, bmopf_w = convert_file(DistNetwork, dss, "bmopf")
            @test !isempty(bmopf)
            @test bmopf_w isa AbstractVector{<:AbstractString}
            # convert_str matches convert_file for the same conversion.
            cs, _ = convert_str(DistNetwork, read(dss, String), "pmd", "dss")
            @test cs == pmd

            # The shared verbs still default to Network: parsing the dss as a
            # transmission case fails, distinct from the DistNetwork path above.
            @test_throws ErrorException parse_file(dss)

            # A nonexistent path surfaces as a Julia error, not a fault.
            @test_throws ErrorException parse_file(DistNetwork, joinpath(@__DIR__, "data", "no_such.dss"))
        end
    end

    @testset "Aqua quality" begin
        Aqua.test_all(PowerIO)
    end
end
