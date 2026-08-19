@testset "native SCOPF instance JSON (feature prob)" begin
    if !PowerIO.library_available() || !PowerIO.scopf_available()
        @info "pio_scopf_* not exported (needs powerio-capi v0.7 --features prob); skipping"
        @test_skip PowerIO.parse_scopf("{}")
    else
        goc3_path = joinpath(@__DIR__, "data", "goc3_14bus_20220707.json")
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
