@testset "native SCOPF instance JSON (feature prob)" begin
    if !PowerIO.library_available() || !PowerIO.scopf_available()
        @info "pio_scopf_* not exported (needs powerio-capi v0.7 --features prob); skipping"
        @test_skip PowerIO.parse_scopf("{}")
    else
        goc3_path = joinpath(@__DIR__, "data", "goc3_small.json")
        text = read(goc3_path, String)
        doc = PowerIO.parse_scopf(text)
        @test String(doc.schema) == "powerio.scopf"
        @test haskey(doc, :powerio_version)
        @test Int(doc.index_base) == 1
        @test haskey(doc, :instance)

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

        # The wire document and the typed Julia view are one contract. Check
        # every row the fixture produces, not a hand-picked subset of fields.
        same_keys(row, T) = Set(propertynames(row)) == Set(fieldnames(T))
        static_contracts = (
            (doc.instance.static.bus, PowerIO._ScopfBusRow),
            (doc.instance.static.shunt, PowerIO._ScopfShuntRow),
            (doc.instance.static.acl_branch, PowerIO._ScopfAclRow),
            (doc.instance.static.acx_branch, PowerIO._ScopfAcxRow),
            (doc.instance.static.vpd, PowerIO._ScopfVpdRow),
            (doc.instance.static.fpd, PowerIO._ScopfFpdRow),
            (doc.instance.static.vwr, PowerIO._ScopfVwrRow),
            (doc.instance.static.fwr, PowerIO._ScopfFwrRow),
            (doc.instance.static.dc_branch, PowerIO._ScopfDcRow),
            (doc.instance.static.prod, PowerIO._ScopfSddRow),
            (doc.instance.static.cons, PowerIO._ScopfSddRow),
            (doc.instance.static.active_reserve, PowerIO._ScopfActiveReserveRow),
            (doc.instance.static.reactive_reserve, PowerIO._ScopfReactiveReserveRow),
            (doc.instance.static.active_reserve_set_pr, PowerIO._ScopfActiveReserveSetRow),
            (doc.instance.static.active_reserve_set_cs, PowerIO._ScopfActiveReserveSetRow),
            (doc.instance.static.reactive_reserve_set_pr, PowerIO._ScopfReactiveReserveSetRow),
            (doc.instance.static.reactive_reserve_set_cs, PowerIO._ScopfReactiveReserveSetRow),
        )
        for (rows, T) in static_contracts, row in rows
            @test same_keys(row, T)
        end
        energy_contracts = (
            (doc.instance.energy_windows.W_en_max_pr, PowerIO._ScopfWinMaxPrRow),
            (doc.instance.energy_windows.W_en_max_cs, PowerIO._ScopfWinMaxCsRow),
            (doc.instance.energy_windows.W_en_min_pr, PowerIO._ScopfWinMinPrRow),
            (doc.instance.energy_windows.W_en_min_cs, PowerIO._ScopfWinMinCsRow),
            (doc.instance.energy_windows.T_w_en_max_pr, PowerIO._ScopfWinTMaxPrRow),
            (doc.instance.energy_windows.T_w_en_max_cs, PowerIO._ScopfWinTMaxCsRow),
            (doc.instance.energy_windows.T_w_en_min_pr, PowerIO._ScopfWinTMinPrRow),
            (doc.instance.energy_windows.T_w_en_min_cs, PowerIO._ScopfWinTMinCsRow),
        )
        for (rows, T) in energy_contracts, row in rows
            @test same_keys(row, T)
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
