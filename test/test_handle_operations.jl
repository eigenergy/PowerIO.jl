@testset "handle operations" begin
    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        @testset "release waits for an active operation" begin
            m = parse(fixture("case9.m"))
            h = getfield(m, :handle)
            entered = Base.Event()
            finish = Base.Event()
            requested = Base.Event()
            reading = Threads.@spawn PowerIO._with_handles(h) do
                notify(entered)
                wait(finish)
                PowerIO._ptr(h) != C_NULL
            end
            wait(entered)
            releasing = Threads.@spawn begin
                notify(requested)
                PowerIO.release!(h)
            end
            wait(requested)
            @test getfield(h, :ptr) != C_NULL
            notify(finish)
            @test fetch(reading)
            fetch(releasing)
            @test getfield(h, :ptr) == C_NULL
            PowerIO.release!(h)
            @test_throws ErrorException m.producer
            @test length(getfield(m, :value).buses) == 9
        end

        @testset "exceptions release operation locks" begin
            m = parse(fixture("case9.m"))
            h = getfield(m, :handle)
            @test_throws ErrorException PowerIO._with_handles(h) do
                error("operation did not complete")
            end
            @test fetch(Threads.@spawn m.producer).name == m.producer.name
        end

        @testset "shared module aliases and snapshots" begin
            m = parse(fixture("case9.m"))
            snapshot = m.value
            alias = PioModule(getfield(m, :handle), snapshot)
            update = set_load_active_power(ComponentId("load", "bus-5"), ActivePower(megawatts=91.5))
            readers = map(1:2) do _
                Threads.@spawn begin
                for _ in 1:20
                    @test !isempty(alias.producer.name)
                    @test length(m.value.buses) == 9
                    @test !isempty(serialize(alias).text)
                    @test !isempty(sprint(show, m))
                    @test !isempty(to_powermodels(snapshot))
                end
                end
            end
            writer = Threads.@spawn begin
                for _ in 1:20
                    apply_updates!(m, [update])
                end
            end
            foreach(fetch, readers)
            fetch(writer)
            @test m.value.loads[1].p_mw == 91.5
            @test snapshot.loads[1].p_mw == 90.0
            @test_throws ArgumentError PowerIO._calculation_update(PowerIO._lib_of(m) * ".other", update)
            @test m.value.loads[1].p_mw == 91.5
        end

        @testset "borrowed records are copied from temporary owners" begin
            balanced = parse(fixture("case9.m"))
            document = JSON3.read(serialize(balanced).text, Dict{String,Any})
            document["value"]["data"]["geo"] = Dict("space" => "geographic", "crs" => "EPSG:4326")
            bytes = Vector{UInt8}(JSON3.write(document))
            dist = raw"""{"meta":{"schema_version":"0.2.0"},"bus":{"a":{"terminal_names":["1"],"geo":{"type":"Point","coordinates":[1.0,2.0]}}}}"""
            collector = Threads.@spawn for _ in 1:30
                GC.gc()
                yield()
            end
            for _ in 1:30
                @test parse(fixture("case9.m")).producer.name == balanced.producer.name
                @test parse(fixture("case9.m")).producer.version == balanced.producer.version
                @test deserialize(bytes).value.geo.crs == "EPSG:4326"
                @test parse(IOBuffer(dist); format="bmopf-json").value.geo.space == "geographic"
            end
            fetch(collector)
        end

        @testset "release symbols are checked before allocation" begin
            compiler = Sys.which("cc")
            if compiler === nothing || !Sys.islinux()
                @test_skip "C compiler on Linux required"
            else
                mktempdir() do dir
                    omitted = last(PowerIO._HANDLE_RELEASE_SYMBOLS)
                    source = joinpath(dir, "library.c")
                    library = joinpath(dir, "library.so")
                    declarations = join(["void $(sym)(void *p) {}" for sym in PowerIO._HANDLE_RELEASE_SYMBOLS if sym != omitted], "\n")
                    write(source, "#include <stddef.h>\nunsigned pio_abi_version(void) { return 7; }\n" *
                        "static unsigned count = 0;\nunsigned test_allocation_count(void) { return count; }\n" *
                        "void *pio_source_open(const char *p, size_t n, void **err) { count++; return 0; }\n" * declarations)
                    run(`$compiler -shared -fPIC -o $library $source`)
                    @test_throws Exception PowerIO._source_open(library, "unused.m")
                    native = Libdl.dlopen(library)
                    count = Libdl.dlsym(native, :test_allocation_count)
                    @test ccall(count, Cuint, ()) == 0
                end
            end
        end

        @testset "library selection remains consistent during reads" begin
            lib = PowerIO._checked_lib()
            try
                readers = map(1:2) do _
                    Threads.@spawn begin
                        for _ in 1:30
                            @test PowerIO._checked_lib() isa String
                            @test PowerIO.abi_version(lib) == 7
                        end
                    end
                end
                writer = Threads.@spawn for _ in 1:30
                    set_library!(lib)
                    clear_library!()
                end
                foreach(fetch, readers)
                fetch(writer)
            finally
                clear_library!()
            end
        end
    end
end
