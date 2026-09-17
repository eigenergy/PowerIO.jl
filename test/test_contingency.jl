@testset "Contingency analysis files" begin
    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        con(parts...) = fixture("psse", "contingency", parts...)
        read_con(name) = read(con(name), String)

        @testset "values from a module" begin
            cases = parse(con("resolve_cases.con"))
            @test cases isa PioModule{ContingencySet}
            @test length(cases.value) == 20
            @test cases.value.cases[1] == "BR_1_2_C1"
            @test cases.value.cases[end] == "UNRECOGNIZED"
            # A value taken from a module carries no notes; the module holds them.
            @test cases.value.diagnostics == Diagnostic[]
            @test propertynames(cases.value) == (:text, :cases, :diagnostics)
            @test sprint(show, cases.value) == "ContingencySet(20 cases)"
            # The module retains the source bytes, so same-format emission is
            # byte exact, while `.text` is the writer's canonical form.
            @test emit(cases, "psse-con").text == read_con("resolve_cases.con")
            @test occursin("CONTINGENCY 'BR_MISSING'\nOPEN LINE FROM BUS      3 TO BUS      4 CIRCUIT 1\nEND\n",
                           cases.value.text)
            @test ContingencySet(cases.value.text).cases == cases.value.cases

            groups = parse(con("selectors.sub"))
            @test groups isa PioModule{SubsystemSet}
            @test length(groups.value) == 10
            @test groups.value.names == ["A1", "AREARANGE", "BARE", "BUSLIST", "BUSRANGE",
                                         "KV", "JOINED", "BAREJOIN", "ONELINE", "A2"]
            @test groups.value.diagnostics == Diagnostic[]
            @test sprint(show, groups.value) == "SubsystemSet(10 subsystems)"
            @test emit(groups, "psse-sub").text == read_con("selectors.sub")

            # A file the writer reproduces exactly states `.text` as its bytes.
            area = parse(con("psse35_area.sub"))
            @test area.value.text == read_con("psse35_area.sub")

            monitored = parse(con("generated.mon"))
            @test monitored isa PioModule{MonitoredSet}
            @test monitored.value.statement_count == 12
            @test monitored.value.diagnostics == Diagnostic[]
            @test sprint(show, monitored.value) == "MonitoredSet(12 statements)"
            @test emit(monitored, "psse-mon").text == read_con("generated.mon")
        end

        @testset "text constructors" begin
            cases = ContingencySet(read_con("resolve_cases.con"))
            @test length(cases) == 20
            @test cases.cases[1] == "BR_1_2_C1"
            # One statement of the fixture is kept as text, so the reader
            # records it.
            @test !isempty(cases.diagnostics)

            groups = SubsystemSet(read_con("selectors.sub"))
            @test groups.names == ["A1", "AREARANGE", "BARE", "BUSLIST", "BUSRANGE",
                                   "KV", "JOINED", "BAREJOIN", "ONELINE", "A2"]
            @test [d.code for d in groups.diagnostics] == ["READ.SUB.STATEMENT_UNRECOGNIZED"]

            blocks = MonitoredSet(read_con("blocks.mon"))
            @test blocks.statement_count == 4
            @test [d.code for d in blocks.diagnostics] == ["READ.MON.STATEMENT_UNRECOGNIZED"]
            @test occursin("MONITOR INTERFACE 'WEST' RATING 200.0 MW", blocks.text)

            @test_throws PowerIOError ContingencySet("CONTINGENCY 'A'\nCONTINGENCY 'B'\nEND\nEND\n")
        end

        @testset "resolution" begin
            net = parse(con("resolve_v33.raw")).value
            resolution = resolve_contingencies(net, read_con("resolve_cases.con"))
            @test resolution.cases == 20
            @test resolution.resolved == 17
            @test resolution.unresolved == 3
            @test resolution.unrecognized_statements == 1
            @test sprint(show, resolution) == "ContingencyResolution(17 of 20 cases resolved)"
            @test length(resolution) == 20
            @test resolution[1] === resolution.case_results[1]
            @test [c.name for c in resolution] == [c.name for c in resolution.case_results]

            first_case = resolution.case_results[1]
            @test first_case.name == "BR_1_2_C1"
            @test first_case.resolved
            @test first_case.components == [ContingencyComponent("branch", "1-2", 1, true)]
            @test isempty(first_case.unresolved)

            unresolved = [(c.name, c.unresolved) for c in resolution.case_results if !c.resolved]
            @test unresolved == [
                ("BR_MISSING",
                 [UnresolvedAction("OPEN LINE FROM BUS      3 TO BUS      4 CIRCUIT 1", :no_such_branch)]),
                ("MACHINE_MISSING",
                 [UnresolvedAction("REMOVE MACHINE 9 FROM BUS      1", :no_such_machine)]),
                ("UNRECOGNIZED",
                 [UnresolvedAction("PARALLEL BRANCH FROM BUS      1 TO BUS      2", :unrecognized)]),
            ]

            # The typed form takes a set and reports the set's own notes.
            typed = resolve_contingencies(net, ContingencySet(read_con("resolve_cases.con")))
            fields(c) = (c.name, c.resolved, c.components, c.unresolved)
            @test map(fields, typed.case_results) == map(fields, resolution.case_results)
            @test !isempty(typed.diagnostics)

            # A row the network states no identity for still names its table.
            ir = JSON3.read(serialize(parse(con("resolve_v33.raw"))).text, Dict{String,Any})
            for load in ir["value"]["data"]["loads"]
                load["uid"] = ""
            end
            anonymous = deserialize(Vector{UInt8}(JSON3.write(ir))).value
            blanked = resolve_contingencies(anonymous, read_con("resolve_cases.con"))
            loads = only(c for c in blanked.case_results if c.name == "LOADS_AT_BUS")
            @test [c.component_type for c in loads.components] == ["load", "load"]
            @test all(c -> c.local_id === nothing, loads.components)
            @test [c.row for c in loads.components] == [1, 2]
        end

        @testset "expansion" begin
            net = parse(con("select_v33.raw")).value
            cases = ContingencySet(read_con("expand.con"))
            groups = SubsystemSet(read_con("selectors.sub"))
            expanded, notes = expand_contingencies(net, cases, groups)
            @test expanded.cases == ["EXPLICIT", "L_101_102_1", "L_102_103_1", "T_101_102_103_1",
                                     "G_101_1", "G_101_2", "L_103_201_1",
                                     "L_101_102_1+L_102_103_1"]
            @test length(expanded) == 8
            # An expanded set is the library's own product and carries no notes.
            @test expanded.diagnostics == Diagnostic[]
            @test [d.code for d in notes] ==
                  ["READ.SUB.STATEMENT_UNRECOGNIZED", "BUILD.CON.SUBSYSTEM_UNKNOWN"]

            text, text_notes = expand_contingencies(net, read_con("expand.con"),
                                                    read_con("selectors.sub"))
            @test text == expanded.text
            @test occursin("SINGLE BRANCH IN SUBSYSTEM 'NOSUCH'", text)
            @test occursin("CONTINGENCY 'T_101_102_103_1'", text)
            @test [d.code for d in text_notes] == [d.code for d in notes]
        end

        @testset "subsystem selection" begin
            net = parse(con("select_v33.raw")).value
            groups = SubsystemSet(read_con("selectors.sub"))
            @test select_subsystem_buses(net, groups, "A1") == [101, 102, 103]
            @test select_subsystem_buses(net, groups, "AREARANGE") == [101, 102, 103, 201, 202]
            @test select_subsystem_buses(net, groups, "KV") == [101, 102, 103, 201]
            # A statement names a subsystem without case and without
            # surrounding whitespace.
            @test select_subsystem_buses(net, groups, " a1 ") == [101, 102, 103]
            @test select_subsystem_buses(net, read_con("selectors.sub"), "A1") == [101, 102, 103]

            missing_name = try
                select_subsystem_buses(net, groups, "NOSUCH")
                nothing
            catch e
                e
            end
            @test missing_name isa PowerIOError
            @test missing_name.code == "BIND.CAPI.INDEX_OUT_OF_RANGE"

            # The handle holds the module owner, so a set projected from a
            # module value selects after the module handle is released.
            module_groups = parse(con("selectors.sub"))
            projected = module_groups.value
            PowerIO.release!(PowerIO._handle(module_groups))
            GC.gc()
            @test select_subsystem_buses(net, projected, "A1") == [101, 102, 103]
            @test projected.names[1] == "A1"
        end
    end
end
