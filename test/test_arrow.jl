function arrow_test_release_array(ptr::Ptr{PowerIO.CArrowArray})
    a = unsafe_load(ptr)
    unsafe_store!(ptr, PowerIO.CArrowArray(a.length, a.null_count, a.offset, a.n_buffers,
                                           a.n_children, a.buffers, a.children, a.dictionary,
                                           C_NULL, a.private_data))
    return nothing
end

function arrow_test_release_schema(ptr::Ptr{PowerIO.CArrowSchema})
    s = unsafe_load(ptr)
    unsafe_store!(ptr, PowerIO.CArrowSchema(s.format, s.name, s.metadata, s.flags,
                                            s.n_children, s.children, s.dictionary,
                                            C_NULL, s.private_data))
    return nothing
end

function arrow_release_callback_error(arr_release::Ptr{Cvoid}, sch_release::Ptr{Cvoid})
    arr = Ref(PowerIO.CArrowArray(0, 0, 0, 0, 0, C_NULL, C_NULL, C_NULL,
                                  arr_release, C_NULL))
    sch = Ref(PowerIO.CArrowSchema(C_NULL, C_NULL, C_NULL, 0, 0, C_NULL, C_NULL,
                                   sch_release, C_NULL))
    err = try
        PowerIO._require_release_callbacks!(arr, sch)
        nothing
    catch e
        e
    end
    return err, arr, sch
end

@testset "Arrow export (copy out default and zero copy opt in)" begin
    if !(PowerIO.library_available() && PowerIO.arrow_available())
        @test_skip to_arrow("case14.m", :bus)
    else
        data = joinpath(@__DIR__, "data")
        m = joinpath(data, "case14.m")

        # Default copy=true: a NamedTuple of owned Julia Vectors, no ArrowTable.
        bus = to_arrow(m, :bus)
        @test bus isa NamedTuple
        @test bus.id isa Vector{Int64}
        @test bus.id == collect(1:14)                   # external 1-based bus ids, in order
        # Owned: mutating a returned column can't touch the producer (already
        # freed); a fresh export is unaffected, and GC after release is safe.
        bus.id[1] = -999
        GC.gc()
        @test to_arrow(m, :bus).id[1] == 1
        @test bus.id[2] == 2

        # The Arrow gen table matches the dense extractor on the shared columns.
        d = to_dense(m)
        gen = to_arrow(m, :gen)
        @test gen.bus == d.gen.bus
        @test gen.pg ≈ d.gen.pg

        function optional_arrow(table)
            try
                return to_arrow(m, table)
            catch e
                if occursin("does not support table", sprint(showerror, e))
                    return nothing
                end
                rethrow()
            end
        end

        # Every raw table's row count matches the JSON view's element count.
        net = parse_file(m)
        @test length(to_arrow(m, :shunt).bus) == length(PowerIO.shunts(net))
        @test length(to_arrow(m, :branch).from) == length(PowerIO.branches(net))
        switch = optional_arrow(:switch)
        if switch === nothing
            @test_skip to_arrow(m, :switch)
        else
            @test isempty(switch.from)
        end

        # Normalized solver tables use dense 0-based indices and per unit/radian values.
        solver_bus = optional_arrow(:solver_bus)
        if solver_bus === nothing
            @test_skip to_arrow(m, :solver_bus)
        else
            @test solver_bus.index == collect(0:13)
            @test solver_bus.bus_id == collect(1:14)
            @test solver_bus.source_row[2] == 1
            @test solver_bus.pd[2] ≈ 21.7 / 100.0
            @test solver_bus.is_reference[1] == 0x01

            solver_branch = to_arrow(m, :solver_branch)
            @test length(solver_branch.index) == 20
            @test solver_branch.from_bus_index[1] == 0
            @test solver_branch.to_bus_index[1] == 1

            solver_arc = to_arrow(m, :solver_arc)
            @test length(solver_arc.index) == 40
            @test solver_arc.branch_index[1:2] == [0, 0]
            @test solver_arc.terminal[1:2] == [0, 1]

            solver_gen = to_arrow(m, :solver_gen)
            @test solver_gen.bus_index == [0, 1, 2, 5, 7]
            @test isempty(to_arrow(m, :solver_storage).index)
            @test isempty(to_arrow(m, :solver_hvdc).index)
            @test isempty(to_arrow(m, :solver_switch).index)
        end

        # The BalancedNetwork-first method matches the path method.
        @test to_arrow(net, :bus).id == collect(1:14)

        @test_throws ArgumentError to_arrow(m, :nonesuch)

        # Malformed Arrow structs from a bad producer must throw Julia errors
        # before any unsafe load from null child or buffer pointers.
        bad_arr = PowerIO.CArrowArray(1, 0, 0, 0, 1, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL)
        bad_sch = PowerIO.CArrowSchema(C_NULL, C_NULL, C_NULL, 0, 1, C_NULL, C_NULL, C_NULL, C_NULL)
        @test_throws ErrorException PowerIO._decode_arrow(Ref(bad_arr), Ref(bad_sch);
                                                         copy=true, table=:bus)
        bad_child = PowerIO.CArrowArray(1, 0, 0, 2, 0, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL)
        @test_throws ErrorException PowerIO._column(Float64, bad_child, 1, :bad,
                                                    Ref(PowerIO._zero(PowerIO.CArrowArray)), true)
        raw_values = [1.0, 2.0]
        raw_buffers = Ptr{Cvoid}[C_NULL, pointer(raw_values)]
        offset_child = PowerIO.CArrowArray(1, 0, 1, 2, 0, pointer(raw_buffers),
                                           C_NULL, C_NULL, C_NULL, C_NULL)
        GC.@preserve raw_values raw_buffers begin
            @test_throws ErrorException PowerIO._check_child_array(offset_child, 1, :bad)
        end
        meta_values = [Int64(7)]
        meta_buffers = Ptr{Cvoid}[C_NULL, pointer(meta_values)]
        meta_child_arr = Ref(PowerIO.CArrowArray(1, 0, 0, 2, 0, pointer(meta_buffers),
                                                 C_NULL, C_NULL, C_NULL, C_NULL))
        meta_format = UInt8[0x6c, 0x00]
        meta_name = UInt8[0x69, 0x64, 0x00]
        meta_child_sch = Ref(PowerIO.CArrowSchema(Ptr{Cchar}(pointer(meta_format)),
                                                  Ptr{Cchar}(pointer(meta_name)),
                                                  C_NULL, 0, 0, C_NULL, C_NULL,
                                                  C_NULL, C_NULL))
        meta_arr_children = Ptr{PowerIO.CArrowArray}[
            Base.unsafe_convert(Ptr{PowerIO.CArrowArray}, meta_child_arr)]
        meta_sch_children = Ptr{PowerIO.CArrowSchema}[
            Base.unsafe_convert(Ptr{PowerIO.CArrowSchema}, meta_child_sch)]
        bad_metadata = UInt8[0xff, 0xff, 0xff, 0xff]
        meta_root_arr = PowerIO.CArrowArray(1, 0, 0, 0, 1, C_NULL,
                                            pointer(meta_arr_children), C_NULL, C_NULL, C_NULL)
        meta_root_sch = PowerIO.CArrowSchema(C_NULL, C_NULL, Ptr{Cchar}(pointer(bad_metadata)),
                                             0, 1, pointer(meta_sch_children), C_NULL,
                                             C_NULL, C_NULL)
        GC.@preserve meta_values meta_buffers meta_child_arr meta_child_sch begin
            GC.@preserve meta_arr_children meta_sch_children meta_format meta_name bad_metadata begin
                decoded = PowerIO._decode_arrow(Ref(meta_root_arr), Ref(meta_root_sch);
                                                copy=true, table=:bus)
                @test decoded.id == [7]
                @test_throws ErrorException PowerIO._decode_arrow(Ref(meta_root_arr),
                                                                  Ref(meta_root_sch);
                                                                  copy=true, table=:bprime)
            end
        end
        @test_throws ErrorException PowerIO._require_release_callbacks!(
            Ref(PowerIO._zero(PowerIO.CArrowArray)),
            Ref(PowerIO._zero(PowerIO.CArrowSchema)))
        release_array = @cfunction(arrow_test_release_array, Cvoid, (Ptr{PowerIO.CArrowArray},))
        release_schema = @cfunction(arrow_test_release_schema, Cvoid, (Ptr{PowerIO.CArrowSchema},))
        err, arr, sch = arrow_release_callback_error(C_NULL, release_schema)
        @test occursin("ArrowArray release callback is null", sprint(showerror, err))
        @test sch[].release == C_NULL
        err, arr, sch = arrow_release_callback_error(release_array, C_NULL)
        @test occursin("ArrowSchema release callback is null", sprint(showerror, err))
        @test arr[].release == C_NULL

        # copy=false: the zero copy ArrowTable path, same values. A column
        # extracted from the table roots the shared buffers on its own, so
        # it survives the table being collected (the old footgun).
        z = to_arrow(m, :bus; copy=false)
        @test z isa ArrowTable
        @test z.id == collect(1:14)
        @test z.id isa PowerIO.ArrowColumn{Int64}
        @test PowerIO.columns(z) isa NamedTuple
        # The raw unsafe_wrap view must not escape its rooting wrapper.
        @test_throws ErrorException z.id.data
        @test collect(z.id) isa Vector{Int64}
        col = z.id
        z = nothing
        GC.gc(); GC.gc()
        @test col == collect(1:14)
        col = nothing
        GC.gc()

        # close releases the producer eagerly and marks surviving columns
        # closed, so reading an extracted column throws instead of touching
        # released buffers.
        z2 = to_arrow(m, :bus; copy=false)
        z2_col = z2.id
        b = getfield(z2, :_buffers)
        @test b.array[].release != C_NULL
        close(z2)
        @test b.array[].release == C_NULL
        @test b.schema[].release == C_NULL
        @test_throws ErrorException z2_col[1]
        @test_throws ErrorException collect(z2_col)
        close(z2)
        finalize(z2)
        @test true

        function f64_bits(xs)
            ["0x" * string(reinterpret(UInt64, Float64(x)); base=16, pad=16) for x in xs]
        end

        function check_matrix_fixture(case_name)
            path = joinpath(data, case_name)
            fixture_path = joinpath(data, "capi_matrix",
                                    replace(case_name, ".m" => "_arrow_coo.json"))
            fixture = PowerIO._json_plain(JSON3.read(read(fixture_path, String)))
            for table_name in ("ybus", "incidence", "bprime", "bdoubleprime")
                got = to_arrow(path, Symbol(table_name))
                expected = fixture["tables"][table_name]
                @test got.table == expected["table"]
                @test got.row_count == expected["row_count"]
                @test got.col_count == expected["col_count"]
                @test got.row_index == expected["row_index"]
                @test got.col_index == expected["col_index"]
                if table_name == "ybus"
                    @test f64_bits(got.g) == expected["g_bits"]
                    @test f64_bits(got.b) == expected["b_bits"]
                else
                    @test f64_bits(got.value) == expected["value_bits"]
                end
            end
        end

        if PowerIO.matrix_available()
            check_matrix_fixture("case9.m")
            check_matrix_fixture("case30.m")
            zmat = to_arrow(m, :bprime; copy=false)
            @test zmat.row_count == 14
            @test zmat.col_count == 14
            @test zmat.row_index isa PowerIO.ArrowColumn{Int64}
            close(zmat)
        else
            @test_throws ErrorException to_arrow(m, :bprime)
        end
    end
end
