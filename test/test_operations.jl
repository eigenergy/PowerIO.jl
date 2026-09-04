@testset "parse, emit, serialize, deserialize" begin
    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        @test PowerIO.abi_version() == PowerIO.PIO_ABI_VERSION
        @test !isempty(PowerIO.library_version())

        @testset "parse a path" begin
            m = parse(fixture("case9.m"))
            @test m isa PioModule{BalancedNetwork}
            @test m.value isa BalancedNetwork
            @test m.diagnostics isa Vector{Diagnostic}
            @test m.producer.name == "powerio"
            @test length(m.sources) == 1
            @test m.sources[1].name == "case9.m"
            @test m.sources[1].format == "matpower"
            @test m.sources[1].byte_length == filesize(fixture("case9.m"))
            @test m.history isa Vector{HistoryEntry}
            @test propertynames(m) == (:value, :diagnostics, :producer, :sources, :history)
            @test occursin("PioModule{BalancedNetwork}", sprint(show, m))
        end

        @testset "parse a stream and bytes" begin
            text = read(fixture("case9.m"))
            from_io = parse(IOBuffer(text); format="matpower", name="case9.m")
            @test from_io isa PioModule{BalancedNetwork}
            @test from_io.sources[1].name == "case9.m"
            from_bytes = parse(text; format="matpower", name="case9.m")
            @test from_bytes isa PioModule{BalancedNetwork}
            open(fixture("case9.m")) do io
                m = parse(io; format="matpower")
                @test m isa PioModule{BalancedNetwork}
                @test endswith(m.sources[1].name, "case9.m")
            end
            @test parse(read(fixture("case14.pm.json")); format="powermodels-json",
                        name="case14.pm.json") isa PioModule{BalancedNetwork}
            @test parse(fixture("case14.egret.json")) isa PioModule{BalancedNetwork}
            @test parse(fixture("dist", "switch.dss")) isa PioModule{MulticonductorNetwork}
        end

        @testset "parse failures are structured" begin
            e = try
                parse(fixture("does-not-exist.m"))
            catch err
                err
            end
            @test e isa PowerIOError
            @test e.code == "READ.IO.OPEN"
            @test occursin(e.code, sprint(showerror, e))

            e = try
                parse(IOBuffer("not a case"); format="matpower", name="bad.m")
            catch err
                err
            end
            @test e isa PowerIOError
            @test startswith(e.code, "PARSE.")
            @test !isempty(e.diagnostics)
            @test e.diagnostics[1].severity == :error
        end

        @testset "emit" begin
            m = parse(fixture("case9.m"))
            same = emit(m, "matpower")
            @test same isa EmitResult
            @test same.layout == "file"
            @test same.fidelity == "exact_same_format"
            @test same.text == read(fixture("case9.m"), String)
            @test length(same.artifacts) == 1
            @test same.artifacts[1].path === nothing
            @test same.artifacts[1].data == read(fixture("case9.m"))
            @test propertynames(same) == (:artifacts, :layout, :fidelity, :diagnostics, :text)

            other = emit(m, "psse")
            @test other.fidelity == "canonical"
            @test occursin("case9", other.text)
            @test all(d -> d isa Diagnostic, other.diagnostics)
            @test any(d -> startswith(d.code, "EMIT.PSSE."), other.diagnostics)

            buf = IOBuffer()
            emit(m, "matpower", buf)
            @test String(take!(buf)) == same.text

            mktempdir() do dir
                path = joinpath(dir, "case9.raw")
                written = emit(m, "psse", path)
                @test written.layout == "file"
                @test written.artifacts[1].path == path
                @test written.artifacts[1].data === nothing
                @test written.artifacts[1].name == "case9.raw"
                @test read(path, String) == other.text

                folder = joinpath(dir, "pypsa")
                dir_result = emit(m, "pypsa-csv", folder)
                @test dir_result.layout == "directory"
                @test length(dir_result.artifacts) > 1
                @test all(a -> isfile(a.path), dir_result.artifacts)
                @test_throws ArgumentError emit(m, "pypsa-csv", IOBuffer())
            end

            e = try
                emit(m, "not-a-format")
            catch err
                err
            end
            @test e isa PowerIOError
        end

        @testset "serialize and deserialize" begin
            m = parse(fixture("case9.m"))
            ir = serialize(m)
            @test ir isa EmitResult
            @test ir.layout == "file"
            @test length(ir.artifacts) == 1
            doc = JSON3.read(ir.text)
            @test doc.schema == "powerio.module"
            # PowerIO IR names the release that wrote it.
            @test doc.version == library_version()
            @test doc.value.type == "powerio.BalancedNetwork"

            back = deserialize(Vector{UInt8}(ir.text))
            @test back isa PioModule{BalancedNetwork}
            @test back.producer == m.producer
            # PowerIO IR does not carry the original file content, so the
            # deserialized module writes canonical output with the same values.
            @test emit(back, "matpower").fidelity == "canonical"
            @test emit(back, "psse").text == emit(m, "psse").text

            mktempdir() do dir
                path = joinpath(dir, "case9.pio.json")
                written = serialize(m, path)
                @test written.artifacts[1].path == path
                @test deserialize(path) isa PioModule{BalancedNetwork}
                open(path) do io
                    @test deserialize(io) isa PioModule{BalancedNetwork}
                end
            end

            e = try
                deserialize(read(fixture("case9.m")))
            catch err
                err
            end
            @test e isa PowerIOError

            # A document from outside this library's compatible release line
            # is refused with the version it states named, and with the remedy
            # that applies to it: a later release needs a newer PowerIO, an
            # earlier one has to be regenerated from its source data.
            header(version) = JSON3.write(
                Dict("schema" => "powerio.module", "version" => version),
            )
            for (version, remedy) in
                (("99.0.0", "upgrade PowerIO"), ("0.10.0", "regenerate this one"))
                err = try
                    deserialize(Vector{UInt8}(header(version)))
                catch caught
                    caught
                end
                @test err isa PowerIOError
                @test occursin("version $version", err.message)
                @test occursin(remedy, err.message)
            end

            feeder = parse(fixture("dist", "switch.dss"))
            @test deserialize(Vector{UInt8}(serialize(feeder).text)) isa PioModule{MulticonductorNetwork}
        end
    end
end
