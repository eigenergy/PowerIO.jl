# Original synthetic acquisition data, not a native third-party MDB fixture.
const SINCAL_SYNTHETIC_SOURCE = Vector{UInt8}(codeunits("\0\x01\0\0Standard Jet DB\0PowerIO synthetic source, not a real MDB"))

@testset "SINCAL reader selections" begin
    @test SincalReadOptions().variant === nothing
    @test_throws ArgumentError SincalReadOptions(variant=true)
    @test_throws ArgumentError SincalReadOptions(snapshot_hours=true)
    if LIBRARY_AVAILABLE
        records = read(fixture("synthetic-sincal-records.json"))
        for (hours, expected) in [(0, 2000.0), (6, 4000.0), (12, 6000.0), (24, 2000.0)]
            selection = SincalReadOptions(variant=1, snapshot_hours=hours, acquired_tables="records.json")
            module_ = parse(copy(SINCAL_SYNTHETIC_SOURCE); name="synthetic.mdb", format="sincal-multiconductor",
                sincal_multiconductor=selection, named_buffers=Dict("records.json" => copy(records)))
            GC.gc()
            @test module_ isa PioModule{MulticonductorNetwork}
            @test module_.value.loads[1].active_power_nominal_w == fill(expected, 3)
            @test emit(module_, "sincal").artifacts[1].data == SINCAL_SYNTHETIC_SOURCE
            restored = deserialize(IOBuffer(serialize(module_).text))
            @test restored isa PioModule{MulticonductorNetwork}
            @test restored.value.loads[1].active_power_nominal_w == fill(expected, 3)
            @test_throws PowerIOError emit(restored, "sincal")
        end
        for selection in [
            SincalReadOptions(acquired_tables="records.json"),
            SincalReadOptions(variant=999, snapshot_hours=6, acquired_tables="records.json"),
            SincalReadOptions(snapshot_hours=NaN, acquired_tables="records.json"),
            SincalReadOptions(snapshot_hours=6, acquired_tables="missing.json"),
            SincalReadOptions(snapshot_hours=6, acquired_tables="../records.json"),
        ]
            @test_throws PowerIOError parse(SINCAL_SYNTHETIC_SOURCE; format="sincal-multiconductor",
                sincal_multiconductor=selection, named_buffers=Dict("records.json" => records))
        end
        selected = SincalReadOptions(snapshot_hours=6, acquired_tables="records.json")
        for format in [nothing, "sincal-balanced", "dss"]
            @test_throws PowerIOError parse(SINCAL_SYNTHETIC_SOURCE; format,
                sincal_multiconductor=selected, named_buffers=Dict("records.json" => records))
        end
        @test_throws PowerIOError parse(vcat(SINCAL_SYNTHETIC_SOURCE, UInt8[0]); format="sincal-multiconductor",
            sincal_multiconductor=selected, named_buffers=Dict("records.json" => records))
        mktempdir() do root
            mkdir(joinpath(root, "case"))
            path = joinpath(root, "case", "original.mdb")
            write(path, SINCAL_SYNTHETIC_SOURCE)
            write(joinpath(root, "records.json"), records)
            choice = SincalReadOptions(snapshot_hours=6, acquired_tables="../records.json")
            @test_throws PowerIOError parse(path; format="sincal-multiconductor", sincal_multiconductor=choice)
            module_ = parse(path; format="sincal-multiconductor", sincal_multiconductor=choice, acquisition_root=root)
            @test module_.value.loads[1].active_power_nominal_w == fill(4000.0, 3)
            @test emit(module_, "sincal").artifacts[1].data == SINCAL_SYNTHETIC_SOURCE
            @test_throws ArgumentError parse(path; named_buffers=Dict())
            @test_throws ArgumentError parse(SINCAL_SYNTHETIC_SOURCE; acquisition_root=root)
        end
    else
        @test_skip LIBRARY_AVAILABLE
    end
end
