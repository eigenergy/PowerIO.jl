using PowerIO
using Test
using JSON3

@testset "PowerIO" begin
    @testset "loads and exposes its surface" begin
        # The module must load with no C library present (the binding is lazy),
        # and its public surface must exist.
        for sym in (:Network, :parse_case, :convert_case, :to_normalized, :to_json,
                    :to_dense, :to_matpower, :to_arrow, :ArrowTable)
            @test isdefined(PowerIO, sym)
        end
        # The accessor surface the ecosystem bridges read is unexported but must exist.
        for sym in (:n_buses, :n_branches, :n_gens, :base_mva, :network_name,
                    :source_format, :reference_bus_id, :bus_type_code,
                    :buses, :generators, :branches, :loads, :shunts, :storage, :hvdc,
                    :abi_version, :library_version, :library_available, :arrow_available)
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
            @test_skip parse_case("case14.m")
        else
            data = joinpath(@__DIR__, "data")
            net = parse_case(joinpath(data, "case14.m"))
            @test PowerIO.n_buses(net) == 14
            @test PowerIO.n_branches(net) == 20
            @test PowerIO.n_gens(net) == 5
            @test PowerIO.base_mva(net) == 100.0
            @test PowerIO.source_format(net) == "Matpower"
            @test PowerIO.reference_bus_id(net) == 1
            @test isempty(PowerIO.storage(net))
            @test isempty(PowerIO.hvdc(net))

            # `from` hint threads through to pio_parse.
            net_hinted = parse_case(joinpath(data, "case14.m"); from = "matpower")
            @test PowerIO.n_buses(net_hinted) == 14

            # EGRET and PowerModels both use .json (fixtures produced by convert_case).
            # The positive cases confirm each fixture parses under its own format; the
            # negative cases prove `from` overrides inference, since forcing the wrong
            # reader on a well-formed file fails.
            egret = parse_case(joinpath(data, "case14.egret.json"); from = "egret")
            @test PowerIO.n_buses(egret) == 14
            @test PowerIO.source_format(egret) == "EgretJson"
            pm = parse_case(joinpath(data, "case14.pm.json"); from = "powermodels")
            @test PowerIO.n_buses(pm) == 14
            @test PowerIO.source_format(pm) == "PowerModelsJson"
            @test_throws ErrorException parse_case(joinpath(data, "case14.pm.json"); from = "egret")
            @test_throws ErrorException parse_case(joinpath(data, "case14.egret.json"); from = "powermodels")

            # Same-format conversion is byte-exact and warning-free.
            text, warnings = convert_case(joinpath(data, "case14.m"), "matpower")
            @test occursin("mpc.bus", text)
            @test isempty(warnings)

            # A cross-format target exercises a second writer and the warnings vector.
            psse_text, psse_warnings = convert_case(joinpath(data, "case14.m"), "psse")
            @test !isempty(psse_text)
            @test psse_warnings isa AbstractVector{<:AbstractString}

            # library_available() is true here, so the ABI handshake passed: the
            # library's ABI version must equal the one this binding targets.
            @test PowerIO.abi_version() == PowerIO.PIO_ABI_VERSION
            @test !isempty(PowerIO.library_version())
        end
    end

    @testset "parse_case input methods and to_* dispatch" begin
        if !PowerIO.library_available()
            @test_skip parse_case("", "matpower")
        else
            data = joinpath(@__DIR__, "data")
            mtext = read(joinpath(data, "case14.m"), String)

            # parse_case from text matches parse_case from a path field-for-field,
            # except `name`: a path parse takes the case name from the file stem
            # ("case14"), an in-memory parse has no path so the core defaults it.
            net = parse_case(joinpath(data, "case14.m"))
            nets = parse_case(mtext, "matpower")
            @test PowerIO.source_format(nets) == "Matpower"
            @test PowerIO.n_buses(nets) == PowerIO.n_buses(net)
            for k in keys(net.data)
                k == :name && continue
                @test JSON3.write(net.data[k]) == JSON3.write(nets.data[k])
            end
            @test parse_case(IOBuffer(mtext), "matpower") isa Network   # IO reads to end

            # Each to_* transform agrees whether it starts from a Network (live handle)
            # or re-parses a path.
            @test to_dense(net).bus_ids == to_dense(joinpath(data, "case14.m")).bus_ids
            @test to_matpower(net) == to_matpower(joinpath(data, "case14.m"))
            @test JSON3.read(to_json(net)).base_mva == PowerIO.base_mva(net)

            # to_json works on a handle-less Network (built straight from JSON); the
            # handle-only transforms refuse it with a clear error.
            jsononly = PowerIO.Network(JSON3.read(to_json(net)))
            @test jsononly.handle === nothing
            @test to_json(jsononly) isa String
            @test_throws ErrorException to_dense(jsononly)
            @test_throws ErrorException to_matpower(jsononly)

            # to_normalized on case14: per unit, radians, bus types, source_format.
            # case14 buses are already 1..14, so the reindex is the identity here;
            # norm_tiny below exercises filtering and reindex.
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
            # and branch 5-8 onto the dropped bus. Normalized: buses {1,3,5} reindex
            # to 1,2,3 and branches {1-3, 3-5} to {1-2, 2-3}; tap 0->1, 0.98 kept.
            tiny = to_normalized(parse_case(joinpath(data, "norm_tiny.m")))
            @test PowerIO.n_buses(tiny) == 3                          # isolated bus 8 dropped
            @test PowerIO.n_branches(tiny) == 2                      # out-of-service + dangling dropped
            @test [Int(b.id) for b in PowerIO.buses(tiny)] == [1, 2, 3]
            @test [String(b.kind) for b in PowerIO.buses(tiny)] == ["REF", "PV", "PQ"]
            @test [(Int(br.from), Int(br.to)) for br in PowerIO.branches(tiny)] == [(1, 2), (2, 3)]
            taps = [Float64(br.tap) for br in PowerIO.branches(tiny)]
            @test taps[1] ≈ 1.0                                      # raw tap 0 -> 1
            @test taps[2] ≈ 0.98                                     # explicit tap kept
            @test PowerIO.buses(tiny)[3].va ≈ -5 * pi / 180
            @test sort([Float64(l.p) for l in PowerIO.loads(tiny)]) ≈ [0.30, 0.50]  # 30,50 MW -> pu

            # Error paths surface as Julia errors. Build the bad cases in memory.
            basemva0 = replace(mtext, "mpc.baseMVA = 100" => "mpc.baseMVA = 0")
            @test_throws ErrorException to_normalized(parse_case(basemva0, "matpower"))
            # No generators and no REF bus: nothing to promote to slack.
            noref = "function mpc = noref\nmpc.version = '2';\nmpc.baseMVA = 100;\n" *
                    "mpc.bus = [\n1 1 10 5 0 0 1 1.0 0 138 1 1.1 0.9;\n" *
                    "2 1 20 8 0 0 1 1.0 -1 138 1 1.1 0.9;\n];\n" *
                    "mpc.gen = [\n];\nmpc.branch = [\n1 2 0.01 0.1 0 100 100 100 0 0 1 -30 30;\n];\n"
            @test_throws ErrorException to_normalized(parse_case(noref, "matpower"))
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
            @test d.ng == PowerIO.n_gens(parse_case(joinpath(@__DIR__, "data", "case14.m")))
        end
    end

    @testset "zero-copy Arrow export" begin
        if !(PowerIO.library_available() && PowerIO.arrow_available())
            @test_skip to_arrow("case14.m", :bus)
        else
            data = joinpath(@__DIR__, "data")
            bus = to_arrow(joinpath(data, "case14.m"), :bus)
            @test bus isa ArrowTable
            @test :id in propertynames(bus)
            @test bus.id == collect(1:14)                   # external 1-based bus ids, in order

            # The Arrow gen table matches the dense extractor on the shared columns.
            d = to_dense(joinpath(data, "case14.m"))
            gen = to_arrow(joinpath(data, "case14.m"), :gen)
            @test collect(gen.bus) == d.gen.bus
            @test collect(gen.pg) ≈ d.gen.pg

            # Every table's row count matches the JSON view's element count.
            net = parse_case(joinpath(data, "case14.m"))
            shunts = to_arrow(joinpath(data, "case14.m"), :shunt)
            @test length(shunts.bus) == length(PowerIO.shunts(net))
            branch = to_arrow(joinpath(data, "case14.m"), :branch)
            @test length(branch.from) == length(PowerIO.branches(net))

            @test_throws ArgumentError to_arrow(joinpath(data, "case14.m"), :nonesuch)

            # Releasing the producer (finalizer) must not fault.
            finalize(bus)
            @test true
        end
    end
end
