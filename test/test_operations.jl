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
            @test propertynames(m) == (:value, :type_name, :diagnostics, :producer, :sources,
                                       :history)
            @test occursin("PioModule{BalancedNetwork}", sprint(show, m))
        end

        @testset "a module names its value's structural type" begin
            m = parse(fixture("case9.m"))
            @test m.type_name == "powerio.BalancedNetwork"
            # The name comes from the module, so it survives a mutation.
            apply_updates!(m, [set_load_active_power(ComponentId("load", "bus-5"),
                                                     ActivePower(megawatts=91.5))])
            @test m.type_name == "powerio.BalancedNetwork"
            @test parse(fixture("dist", "switch.dss")).type_name ==
                  "powerio.MulticonductorNetwork"
            @test to_dc_opf_instance(m).type_name == "powerio.DcOpfInstance"
            @test parse(fixture("goc3")).type_name == "powerio.AcScucSolution"
        end

        @testset "diagnostics as JSON ready records" begin
            result = emit(parse(fixture("case9.m")), "psse")
            records = diagnostic_records(result.diagnostics)
            @test records isa Vector{Dict{String,Any}}
            @test length(records) == length(result.diagnostics)
            for (record, d) in zip(records, result.diagnostics)
                @test issubset(["code", "severity", "message", "target"], keys(record))
                @test record["code"] == d.code
                @test record["severity"] isa String
                @test record["severity"] == String(d.severity)
                @test record["message"] == d.message
                @test JSON3.read(JSON3.write(record), Dict{String,Any}) == record
            end
            @test diagnostic_records(Diagnostic[]) == Dict{String,Any}[]

            # An absent optional is left out; `target` is written as null.
            bare = Diagnostic("READ.X.Y", :warning, "a message", nothing, nothing, nothing,
                              SourceSpan[], String[], nothing)
            record = diagnostic_record(bare)
            @test sort!(collect(keys(record))) == ["code", "message", "severity", "target"]
            @test record["target"] === nothing
            @test occursin("\"target\":null", JSON3.write(record))

            full = Diagnostic("READ.X.Y", :error, "a message", "d1", "bus 3", "fix it",
                              [SourceSpan("case9.m", 0x0000000000000010,
                                          0x0000000000000020)],
                              ["d0"], Dict{String,Any}("count" => 2))
            record = diagnostic_record(full)
            @test record["id"] == "d1"
            @test record["target"] == "bus 3"
            @test record["suggested_action"] == "fix it"
            @test record["related"] == ["d0"]
            @test record["details"] == Dict{String,Any}("count" => 2)
            @test record["spans"] == [Dict{String,Any}("source" => "case9.m",
                                                       "byte_start" => 16, "byte_end" => 32)]
            @test record["spans"][1]["byte_start"] isa Int
            @test JSON3.read(JSON3.write(record), Dict{String,Any}) == record
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
            @test doc.schema == "pio-ir"
            @test doc.version == 2
            # The IR generation and producing release are independent.
            @test doc.producer.name == "powerio"
            @test doc.producer.version == library_version()
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

            # An unsupported generation is refused with the version it states
            # and the applicable remedy. The v0.10 identity is historical and
            # is not another current schema family.
            header(schema, version) = JSON3.write(
                Dict("schema" => schema, "version" => version),
            )
            for (schema, version, remedy) in
                (("pio-ir", 4, "upgrade PowerIO"),
                 ("pio-ir", 1, "regenerate this document"),
                 ("powerio.module", 1, "regenerate this document"))
                err = try
                    deserialize(Vector{UInt8}(header(schema, version)))
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
