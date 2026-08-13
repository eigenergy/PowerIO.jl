@testset "native SCOPF instance JSON (feature prob)" begin
    if !PowerIO.library_available() || !PowerIO.scopf_available()
        @info "pio_scopf_* not exported (needs powerio-capi v0.7 --features prob); skipping"
        @test_skip PowerIO.parse_scopf("{}")
    else
        goc3_path = joinpath(@__DIR__, "data", "goc3_14bus_20220707.json")
        text = read(goc3_path, String)
        doc = PowerIO.parse_scopf(text)
        @test String(doc.schema) == "powerio.scopf.julia"
        @test haskey(doc, :powerio_version)
        @test Int(doc.index_base) == 1
        @test haskey(doc, :instance)

        # The serialized instance carries the same per-class set sizes the pure
        # Julia builders derive (the two parsers agree on official GOC3 files;
        # pio_scopf_to_json numbers zones and branches from document order,
        # powerio#252).
        inst = goc3_scopf_data(parse_goc3_json(goc3_path))
        lengths = doc.instance.lengths
        for k in (:L_J_xf, :L_J_ln, :L_J_ac, :L_J_dc, :L_J_br, :L_J_cs, :L_J_pr,
                  :L_J_cspr, :L_J_sh, :I, :L_T, :L_N_p, :L_N_q)
            @test Int(getproperty(lengths, k)) == Int(getproperty(inst.lengths, k))
        end

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
