@testset "shared input collections" begin
    if LIBRARY_AVAILABLE
        standalone = InputCollection(Dict("case9.m" => read(fixture("case9.m"))))
        single = parse(standalone, (primary="case9.m", format="matpower", operation="parse"))
        close(standalone)
        @test single.module isa PioModule{BalancedNetwork}
        @test length(single.module.value.buses) == 9
        @test single.dependencies == String[]
        @test single.dependencies isa Vector{String}
        @test !single.incomplete
        files = Dict(
            "masters/day.dss" => Vector{UInt8}(codeunits("New Circuit.day basekv=12.47 bus1=source\nRedirect ../shared/topology.inc\n")),
            "masters/night.dss" => Vector{UInt8}(codeunits("New Circuit.night basekv=12.47 bus1=source\nRedirect ../shared/topology.inc\n")),
            "shared/topology.inc" => Vector{UInt8}(codeunits("New Line.l bus1=source bus2=load phases=3 r1=0.1 x1=0.2 r0=0.3 x0=0.4 length=1\n")))
        collection = InputCollection(files)
        owned = copy(collection)
        close(collection)
        metadata = inspect_collection(owned)
        @test length(metadata.candidates) == 2
        result = nothing
        for index in [1, 2, 2, 1]
            result = parse(owned, metadata.candidates[index].selection)
            @test result.module isa PioModule{MulticonductorNetwork}
            @test result.dependencies == ["shared/topology.inc"]
            @test !result.incomplete
        end
        close(owned)
        @test length(result.module.value.buses) == 3
        @test_throws ErrorException inspect_collection(owned)
        @test_throws ArgumentError InputCollection(files; max_bytes=1)
        mktempdir() do dir
            for (name, bytes) in files
                path = joinpath(dir, name)
                mkpath(dirname(path))
                write(path, bytes)
            end
            folder = InputCollection(dir)
            @test inspect_collection(folder) == metadata
            @test_throws PowerIOError parse(folder, (primary="../outside.dss",))
            close(folder)
        end
        @test_throws PowerIOError InputCollection(UInt8[1,2,3])
    end
end
