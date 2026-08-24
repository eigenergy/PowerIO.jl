@testset "native SCOPF instance JSON (feature prob)" begin
    @test_throws ArgumentError PowerIO.parse_scopf("{}"; index_base=-1)
    @test_throws ArgumentError PowerIO.parse_scopf("{}"; index_base=2)

    if !PowerIO.library_available() || !PowerIO.scopf_available()
        @info "pio_scopf_* not exported (needs powerio-capi v0.9 --features prob); skipping"
        @test_skip PowerIO.parse_scopf("{}")
    else
        goc3_path = joinpath(@__DIR__, "data", "goc3_small.json")
        text = read(goc3_path, String)
        doc = PowerIO.parse_scopf(text)
        @test String(doc.schema) == "powerio.scopf"
        @test haskey(doc, :powerio_version)
        @test Int(doc.index_base) == 1
        @test haskey(doc, :instance)

        zero_based = PowerIO.parse_scopf(text; index_base=0)
        @test Int(zero_based.index_base) == 0
        @test Int(zero_based.instance.static.bus[1].i) ==
              Int(doc.instance.static.bus[1].i)
        @test Int(zero_based.instance.static.acl_branch[1].j_ln) == 0
        @test Int(doc.instance.static.acl_branch[1].j_ln) == 1
        @test Int(zero_based.instance.static.acl_branch[1].u_0) ==
              Int(doc.instance.static.acl_branch[1].u_0)
        @test Int(zero_based.instance.lengths.L_J_ln) ==
              Int(doc.instance.lengths.L_J_ln)

        # The typed API requests base 1 explicitly. Its document-order
        # ordinals can index the corresponding Julia vectors without shifts.
        typed = PowerIO.goc3_scopf_data(text)
        lines = typed.static.acl_branch
        producers = typed.static.prod
        consumers = typed.static.cons
        producer_members = typed.static.active_reserve_set_pr
        consumer_members = typed.static.active_reserve_set_cs
        devices = vcat(producers, consumers)
        @test all(row -> lines[row.j_ln].uid == row.uid, lines)
        @test all(row -> producers[row.j_dev].uid == row.uid, producer_members)
        @test all(row -> consumers[row.j_dev].uid == row.uid, consumer_members)
        @test all(
            row -> devices[row.j_sdd].uid == row.uid,
            vcat(producer_members, consumer_members),
        )

        # The instance's per-class set sizes match the document sections
        # parse_goc3_json reads, so the two remaining readers of the raw file
        # agree on what it contains.
        data = parse_goc3_json(goc3_path)
        lengths = doc.instance.lengths
        @test Int(lengths.L_J_ln) == length(data.ac_line_lookup)
        @test Int(lengths.L_J_xf) == length(data.twt_lookup)
        @test Int(lengths.L_J_dc) == length(data.dc_line_lookup)
        @test Int(lengths.L_J_pr) == length(data.sdd_ids_producer)
        @test Int(lengths.L_J_cs) == length(data.sdd_ids_consumer)
        @test Int(lengths.L_J_sh) == length(data.shunt_lookup)
        @test Int(lengths.I) == length(data.bus_lookup)
        @test Int(lengths.L_T) == length(data.dt)

        # The wire document and the typed Julia view have one row schema. Extend
        # the synthetic source so every row shape is present, then compare all
        # keys rather than a hand-picked subset.
        schema_source = JSON3.read(text, Dict{String,Any})
        variable_xf = deepcopy(schema_source["network"]["two_winding_transformer"][1])
        variable_xf["uid"] = "xf_variable"
        variable_xf["ta_lb"] = -0.1
        variable_xf["ta_ub"] = 0.1
        variable_xf["tm_lb"] = 0.9
        variable_xf["tm_ub"] = 1.1
        push!(schema_source["network"]["two_winding_transformer"], variable_xf)
        consumer = schema_source["network"]["simple_dispatchable_device"][2]
        consumer["energy_req_ub"] = [[0.0, 2.0, 9.0]]
        consumer["energy_req_lb"] = [[0.0, 2.0, 1.0]]
        schema_doc = PowerIO.parse_scopf(JSON3.write(schema_source))

        same_keys(row, T) = Set(propertynames(row)) == Set(fieldnames(T))
        static_schemas = (
            (schema_doc.instance.static.bus, PowerIO._ScopfBusRow),
            (schema_doc.instance.static.shunt, PowerIO._ScopfShuntRow),
            (schema_doc.instance.static.acl_branch, PowerIO._ScopfAclRow),
            (schema_doc.instance.static.acx_branch, PowerIO._ScopfAcxRow),
            (schema_doc.instance.static.vpd, PowerIO._ScopfVpdRow),
            (schema_doc.instance.static.fpd, PowerIO._ScopfFpdRow),
            (schema_doc.instance.static.vwr, PowerIO._ScopfVwrRow),
            (schema_doc.instance.static.fwr, PowerIO._ScopfFwrRow),
            (schema_doc.instance.static.dc_branch, PowerIO._ScopfDcRow),
            (schema_doc.instance.static.prod, PowerIO._ScopfSddRow),
            (schema_doc.instance.static.cons, PowerIO._ScopfSddRow),
            (schema_doc.instance.static.active_reserve, PowerIO._ScopfActiveReserveRow),
            (schema_doc.instance.static.reactive_reserve, PowerIO._ScopfReactiveReserveRow),
            (schema_doc.instance.static.active_reserve_set_pr, PowerIO._ScopfActiveReserveSetRow),
            (schema_doc.instance.static.active_reserve_set_cs, PowerIO._ScopfActiveReserveSetRow),
            (schema_doc.instance.static.reactive_reserve_set_pr, PowerIO._ScopfReactiveReserveSetRow),
            (schema_doc.instance.static.reactive_reserve_set_cs, PowerIO._ScopfReactiveReserveSetRow),
        )
        for (rows, T) in static_schemas
            @test !isempty(rows)
            @test all(row -> same_keys(row, T), rows)
        end
        energy_schemas = (
            (schema_doc.instance.energy_windows.W_en_max_pr, PowerIO._ScopfWinMaxPrRow),
            (schema_doc.instance.energy_windows.W_en_max_cs, PowerIO._ScopfWinMaxCsRow),
            (schema_doc.instance.energy_windows.W_en_min_pr, PowerIO._ScopfWinMinPrRow),
            (schema_doc.instance.energy_windows.W_en_min_cs, PowerIO._ScopfWinMinCsRow),
            (schema_doc.instance.energy_windows.T_w_en_max_pr, PowerIO._ScopfWinTMaxPrRow),
            (schema_doc.instance.energy_windows.T_w_en_max_cs, PowerIO._ScopfWinTMaxCsRow),
            (schema_doc.instance.energy_windows.T_w_en_min_pr, PowerIO._ScopfWinTMinPrRow),
            (schema_doc.instance.energy_windows.T_w_en_min_cs, PowerIO._ScopfWinTMinCsRow),
        )
        for (rows, T) in energy_schemas
            @test !isempty(rows)
            @test all(row -> same_keys(row, T), rows)
        end
        for row in doc.instance.price_blocks.producer
            @test same_keys(row, PowerIO._ScopfPriceBlockRow)
        end
        for row in doc.instance.price_blocks.consumer
            @test same_keys(row, PowerIO._ScopfPriceBlockRow)
        end
        for row in Iterators.flatten(doc.instance.ac_contingency_survivors.ln)
            @test same_keys(row, PowerIO._ScopfLnSurvivorRow)
        end
        for row in Iterators.flatten(doc.instance.ac_contingency_survivors.xf)
            @test same_keys(row, PowerIO._ScopfXfSurvivorRow)
        end
        for row in doc.instance.dc_contingency_flows
            @test same_keys(row, PowerIO._ScopfDcFlowRow)
        end
        @test same_keys(doc.instance.lengths, PowerIO._ScopfLengths)
        @test Set(propertynames(doc.instance.violation_cost)) == Set((:p_bus, :q_bus, :s, :e))
        @test Set(propertynames(doc.instance.device_class_layout)) ==
              Set((:kind, :producers_first))

        # Errors carry the function name and the core's message.
        try
            PowerIO.parse_scopf("not json")
            error("expected parse_scopf to fail")
        catch e
            @test occursin("PowerIO.parse_scopf:", sprint(showerror, e))
        end
        @test_throws ErrorException PowerIO.parse_scopf(text; from = "no-such-format")
    end
end
