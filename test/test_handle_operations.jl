# C source for a stand-in library whose `pio_version_numbers` reports `release`.
_version_numbers_c(release::VersionNumber) =
    "typedef struct { unsigned major, minor, patch; } PioVersionView;\n" *
    "PioVersionView pio_version_numbers(void) { PioVersionView v = " *
    "{$(release.major), $(release.minor), $(release.patch)}; return v; }\n"

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
                    write(source, "#include <stddef.h>\n" * _version_numbers_c(PowerIO._HEADER_RELEASE) *
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
                            @test !isempty(PowerIO.library_version(lib))
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

@testset "library release check" begin
    header = PowerIO._HEADER_RELEASE
    # The rule alone: the header's release series, at the header's release or newer.
    accepts(got, want) = PowerIO._check_release("lib", got, want) === nothing
    @test accepts(v"0.12.0", v"0.12.0")
    @test accepts(v"0.12.3", v"0.12.0")
    @test_throws r"older than PowerIO 0\.12\.3" accepts(v"0.12.0", v"0.12.3")
    @test_throws r"another release series" accepts(v"0.13.0", v"0.12.0")
    @test_throws r"another release series" accepts(v"0.11.9", v"0.12.0")
    @test accepts(v"1.4.2", v"1.2.0")
    @test_throws r"older than PowerIO 1\.2\.0" accepts(v"1.1.9", v"1.2.0")
    @test_throws r"another release series" accepts(v"2.0.0", v"1.2.0")
    @test_throws r"another release series" accepts(v"1.0.0", v"0.12.0")

    # Stand-in libraries go through the same check `_checked_lib` runs.
    compiler = Sys.which("cc")
    if compiler === nothing || !Sys.isunix()
        @test_skip "C compiler on a Unix platform required"
    else
        mktempdir() do dir
            function stand_in(name, body)
                source = joinpath(dir, "$name.c")
                library = joinpath(dir, "$name.$(Libdl.dlext)")
                releases = join(["void $(sym)(void *p) {}" for sym in PowerIO._HANDLE_RELEASE_SYMBOLS], "\n")
                write(source, "#include <stddef.h>\n" * body * releases * "\n")
                run(`$compiler -shared -fPIC -o $library $source`)
                return library
            end
            before = stand_in("before", "typedef struct { const char *data; size_t len; } PioStringView;\n" *
                "PioStringView pio_version(void) { PioStringView v = {\"0.11.6\", 6}; return v; }\n")
            @test_throws r"\(PowerIO 0\.11\.6\) has no pio_version_numbers, so it predates PowerIO 0\.12" PowerIO._ensure_compatible(before)
            other = stand_in("other", _version_numbers_c(VersionNumber(header.major, header.minor + 1, 0)))
            @test_throws r"another release series" PowerIO._ensure_compatible(other)
            if header.patch > 0
                older = stand_in("older", _version_numbers_c(VersionNumber(header.major, header.minor, header.patch - 1)))
                @test_throws r"older than PowerIO" PowerIO._ensure_compatible(older)
            end
            newer = stand_in("newer", _version_numbers_c(VersionNumber(header.major, header.minor, header.patch + 1)))
            # The library under test is checked again on its next call.
            @test PowerIO._ensure_compatible(newer) === nothing
            @test PowerIO._library_release(newer) > header
        end
    end
end
