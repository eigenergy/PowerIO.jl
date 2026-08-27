# ABI v6: stored modules, structured errors, DC branch data with borrowed
# array views.

# The v6 entry points ship with powerio releases past 0.9; against the pinned
# 0.9 artifact library (ABI 5) every v6 testset is skipped by symbol probe.
_has_v6 = PowerIO.library_available() &&
    PowerIO._exports_symbol(:pio_module_read_json, PowerIO._lib())

@testset "ABI v6 stored modules and DC data" begin
    if !_has_v6
        @test_skip "the resolved library predates the ABI v6 entry points"
        return
    end
    case9 = joinpath(@__DIR__, "data", "case9.m")

    @testset "module round trip and kind" begin
        m = parse_module(case9)
        @test module_kind(m) == "balanced_network"
        doc = write_module(m)
        @test occursin("\"powerio.module\"", doc)
        back = read_module(doc)
        @test module_kind(back) == "balanced_network"
        inspection = inspect_module(back)
        @test inspection.kind == "balanced_network"
        @test "diagnostics" in inspection.operations
    end

    @testset "structured refusals carry the code" begin
        err = try
            parse_module_str("not a case"; format="matpower")
            nothing
        catch e
            e
        end
        @test err isa PowerIOCError
        @test occursin(".", err.code)
        @test !isempty(err.message)

        m = parse_module(case9)
        err = try
            export_state(m; time_position=0)
            nothing
        catch e
            e
        end
        @test err isa PowerIOCError
        @test err.code == "REQUEST.STATE.NOT_A_COLLECTION"
    end

    @testset "DC data spans, mappings, and PowerModels values" begin
        m = parse_module(case9)
        d = dc_data(m)
        # The result is independently owned: drop the module first.
        finalize(m)
        rows = PowerIO.n_rows(d)
        buses = PowerIO.n_buses(d)
        @test rows == 9 && buses == 9
        b = PowerIO.susceptance(d)
        @test b isa BorrowedVector{Float64}
        @test length(b) == rows
        # PowerModels sign: imag(inv(r + im*x)) is negative for an inductive
        # branch, and case9 has no shunt susceptance or capacitive branch.
        @test all(<(0), b)
        shift = PowerIO.shift(d)
        @test shift isa BorrowedVector{Float64}
        @test length(shift) == rows
        @test all(iszero, shift)  # case9 has no phase shifting transformer
        @test PowerIO.formula(d) == "series_susceptance"
        @test PowerIO.row_ids(d)[1] == "branches:0"
        @test length(PowerIO.bus_ids(d)) == buses
        @test isempty(PowerIO.omitted(d))

        # The view is read only; copy is an ordinary mutable array.
        @test_throws ErrorException b[1] = 0.0
        c = copy(b)
        @test c isa Vector{Float64}
        c[1] = 0.0
        @test b[1] != 0.0

        # p_branch = -b (va_from - va_to), against a hand computed row.
        from = PowerIO.from_indices(d)
        to = PowerIO.to_indices(d)
        va = zeros(buses)
        va[from[1] + 1] = 0.05
        flow = branch_flow(d, va)
        expected = -b[1] * (va[from[1] + 1] - va[to[1] + 1])
        @test isapprox(flow[1], expected; atol=1e-12)
        @test_throws ErrorException branch_flow(d, zeros(buses - 1))

        # The borrowed view roots its owner: the spans survive a GC pass with
        # only the view live.
        view = PowerIO.susceptance(dc_data(parse_module(case9)))
        GC.gc()
        @test length(view) == rows
        @test view[1] < 0
    end

    @testset "series values inventory and export over the module surface" begin
        # A released 0.9 package with operating points upgrades on read and
        # selects by time position. The document is hand authored: the 0.9
        # writer is gone, and the frozen layout is the upgrade specification.
        network_json = JSON3.read(to_json(PowerIO.parse(case9; value_type=BalancedNetwork)))
        legacy = JSON3.write(Dict(
            "powerio_version" => "0.9.0",
            "producer" => Dict("tool" => "PowerIO.jl test", "version" => "0"),
            "model_kind" => "balanced",
            "model" => Dict("kind" => "balanced", "balanced_network" => network_json),
            "origin" => Dict("kind" => "in_memory"),
            "validation" => Dict("status" => "ok",
                                 "counts" => Dict("fatal" => 0, "error" => 0,
                                                  "warning" => 0, "info" => 0,
                                                  "debug" => 0)),
            "operating_points" => Dict(
                "time_axis" => Dict("periods" => 2, "duration_hours" => [1.0, 1.0],
                                    "labels" => ["h0", "h1"]),
                "points" => [
                    Dict("index" => 0, "updates" => Any[]),
                    Dict("index" => 1, "updates" => [Dict(
                        "element" => Dict("table" => "generators",
                                           "source_uid" => "generators:0"),
                        "fields" => Dict("pg" => 95.0),
                    )]),
                ],
            ),
        ))
        m = read_module(legacy)
        @test module_kind(m) == "balanced_operating_point_time_series"
        inventory = state_inventory(m)
        @test inventory.keyed_by == "time_position"
        @test [p.label for p in inventory.time_points] == ["h0", "h1"]
        exported = export_state(m; time_position=1)
        @test module_kind(exported) == "balanced_network"
        # time_position is zero based: position 1 selects the SECOND time
        # point ("h1"), whose update set pg to 95.0. Read it back off the
        # exported network's own generator so an off by one silently landing
        # on "h0" (pg unchanged) cannot pass.
        exported_value = JSON3.read(write_module(exported)).value
        @test exported_value.kind == "balanced_network"
        exported_net = from_json(JSON3.write(exported_value.data))
        @test Float64(first(PowerIO.generators(exported_net)).pg) ≈ 95.0
        @test occursin("export_selected_state", write_module(exported))
    end
end

@testset "typed module records and bounded field readers" begin
    if !_has_v6
        @test_skip "the resolved library predates the ABI v6 entry points"
        return
    end
    case9 = joinpath(@__DIR__, "data", "case9.m")
    m = parse_module(case9)
    sources = module_sources(m)
    @test length(sources) == 1
    @test endswith(sources[1].name, "case9.m")
    @test sources[1].byte_length > 0

    lowered_history = module_history(lower_module_to_balanced(
        parse_module_str("New Circuit.c basekv=12.47 bus1=src\n"; format="dss")))
    @test any(e -> e.kind == "transform" && e.name == "lower_multiconductor_to_balanced",
              lowered_history)
    entry = only(filter(e -> e.kind == "transform", lowered_history))
    @test any(a -> occursin("power base", a), entry.assumptions)

    diagnostics = module_diagnostics(m)
    @test diagnostics isa Vector{ModuleDiagnostic}

    # A diagnostic row decodes whether `target` is stated, stated as an
    # explicit null (the capi JSON spelling), or absent (the DTO spelling).
    for (row, want) in (
        (JSON3.read("""{"code":"C","severity":"note","message":"m","target":"t"}"""), "t"),
        (JSON3.read("""{"code":"C","severity":"note","message":"m","target":null}"""), nothing),
        (JSON3.read("""{"code":"C","severity":"note","message":"m"}"""), nothing),
    )
        record = ModuleDiagnostic(String(row.code), String(row.severity),
                                  String(row.message),
                                  PowerIO._record_string(row, :target))
        @test record.target == want
    end
end

@testset "module_kind and formula outlive their GC.@preserve scope" begin
    if !_has_v6
        @test_skip "the resolved library predates the ABI v6 entry points"
        return
    end
    # Every module/DcData handle below exists only as an inline argument, with
    # no local binding keeping it alive past the ccall: if the GC.@preserve
    # around the ccall does not also cover the unsafe_string read, an
    # interleaved collection frees the handle before its name is read back.
    case9 = joinpath(@__DIR__, "data", "case9.m")
    dss_text = "New Circuit.c basekv=12.47 bus1=src\n"
    for _ in 1:200
        GC.gc()
        @test module_kind(parse_module_str(dss_text; format="dss")) == "multiconductor_network"
        GC.gc()
        @test PowerIO.formula(PowerIO.dc_data(parse_module(case9))) == "series_susceptance"
    end
end

@testset "BorrowedVector rejects access once its owner is released" begin
    if !_has_v6
        @test_skip "the resolved library predates the ABI v6 entry points"
        return
    end
    d = PowerIO.dc_data(parse_module(joinpath(@__DIR__, "data", "case9.m")))
    v = PowerIO.susceptance(d)
    @test length(v) == PowerIO.n_rows(d)
    @test v[1] isa Float64
    @test v[1:3] isa Vector{Float64}
    @test collect(v) isa Vector{Float64}
    before = copy(v)
    @test before == collect(v)

    # The owner is still reachable through `d`: a GC pass changes nothing.
    GC.gc()
    @test v[1] == before[1]

    finalize(d)
    @test_throws ErrorException v[1]
    @test_throws ErrorException v[1:3]
    @test_throws ErrorException collect(v)
    @test_throws ErrorException copy(v)
end

@testset "read_module, parse_module, parse_module_str keep working against ABI 6" begin
    if !_has_v6
        @test_skip "the resolved library predates the ABI v6 entry points"
        return
    end
    case9 = joinpath(@__DIR__, "data", "case9.m")
    @test module_kind(parse_module(case9)) == "balanced_network"
    @test module_kind(parse_module_str(read(case9, String); format="matpower")) == "balanced_network"
    @test module_kind(read_module(write_module(parse_module(case9)))) == "balanced_network"
end

@testset "read_module, parse_module, parse_module_str preflight the library" begin
    if !PowerIO.library_available()
        @test_skip "no library resolved in this environment"
        return
    end
    if _has_v6
        @test_skip "the resolved library already exports the ABI v6 entry points; needs one that predates them (e.g. the pinned ABI 5 artifact, POWERIO_CAPI unset) to exercise the missing-export path"
    else
        case9 = joinpath(@__DIR__, "data", "case9.m")
        cases = ((:pio_module_read_json, () -> read_module("{}")),
                 (:pio_module_parse_file, () -> parse_module(case9)),
                 (:pio_module_parse_str, () -> parse_module_str("not a case"; format="matpower")))
        for (sym, thunk) in cases
            err = try
                thunk()
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin(String(sym), sprint(showerror, err))
        end
    end
    # No library in this environment reports an ABI version outside
    # `_ACCEPTED_ABI_VERSIONS`, so the out of window branch of the preflight
    # (as opposed to the in window but export short branch just above) has no
    # live fixture to exercise here.
    @test_skip "no library in this environment reports an ABI version outside _ACCEPTED_ABI_VERSIONS"
end

@testset "the new v6 refusal codes decode correctly" begin
    if !_has_v6
        @test_skip "the resolved library predates the ABI v6 entry points"
        return
    end
    case9 = joinpath(@__DIR__, "data", "case9.m")
    m = parse_module(case9)

    # Reachable through the public API: dc_data does not validate its
    # `formula` keyword or the module's value kind before the ccall.
    err = try
        dc_data(m; formula="nodal_admittance")
        nothing
    catch e
        e
    end
    @test err isa PowerIOCError
    @test err.code == "REQUEST.CAPI.UNKNOWN_FORMULA"

    mc = parse_module_str(
        "Clear\nNew Circuit.tiny basekv=12.47 bus1=src\n" *
        "New Line.l1 bus1=src bus2=a length=1\nSet VoltageBases=[12.47]\n";
        format="dss")
    err = try
        dc_data(mc)
        nothing
    catch e
        e
    end
    @test err isa PowerIOCError
    @test err.code == "REQUEST.CAPI.NOT_A_BALANCED_NETWORK"

    # BIND.CAPI.NULL_HANDLE (a NULL module handle) and
    # REQUEST.CAPI.SELECTOR_CONFLICT (export_state given both or neither
    # selector) are C ABI refusals the safe wrappers already refuse first:
    # `_module_ptr` raises its own released-handle error before any ccall
    # sees a NULL pointer, and export_state's keyword check rejects both
    # conflicting combinations before it dispatches. Neither can surface
    # through the public API; exercised here with a direct ccall to confirm
    # PowerIOCError decodes these two codes correctly as well.
    lib = PowerIO._lib()
    err_ref = Ref{Ptr{Cvoid}}(C_NULL)
    s = ccall(PowerIO._library_symbol(lib, :pio_module_write_json), Cstring,
              (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), C_NULL, err_ref)
    @test s == C_NULL
    @test err_ref[] != C_NULL
    @test PowerIO._v6_error(lib, err_ref[]).code == "BIND.CAPI.NULL_HANDLE"

    err_ref = Ref{Ptr{Cvoid}}(C_NULL)
    ptr = ccall(PowerIO._library_symbol(lib, :pio_module_export_state), Ptr{Cvoid},
                (Ptr{Cvoid}, Int64, Cstring, Ref{Ptr{Cvoid}}), PowerIO._module_ptr(m),
                Int64(0), "s1", err_ref)
    @test ptr == C_NULL
    @test err_ref[] != C_NULL
    @test PowerIO._v6_error(lib, err_ref[]).code == "REQUEST.CAPI.SELECTOR_CONFLICT"
end
