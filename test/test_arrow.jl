const _POWERIO_ARROW_TEST_RELEASE_COUNT = Ref(0)

function _powerio_arrow_test_release_array(ptr::Ptr{PowerIO.CArrowArray})
    _POWERIO_ARROW_TEST_RELEASE_COUNT[] += 1
    a = unsafe_load(ptr)
    unsafe_store!(ptr, PowerIO.CArrowArray(a.length, a.null_count, a.offset,
                                           a.n_buffers, a.n_children, a.buffers,
                                           a.children, a.dictionary, C_NULL,
                                           a.private_data))
    return nothing
end

function _powerio_arrow_test_release_schema(ptr::Ptr{PowerIO.CArrowSchema})
    _POWERIO_ARROW_TEST_RELEASE_COUNT[] += 1
    s = unsafe_load(ptr)
    unsafe_store!(ptr, PowerIO.CArrowSchema(s.format, s.name, s.metadata, s.flags,
                                            s.n_children, s.children, s.dictionary,
                                            C_NULL, s.private_data))
    return nothing
end

const _POWERIO_ARROW_TEST_RELEASE_ARRAY =
    @cfunction(_powerio_arrow_test_release_array, Cvoid, (Ptr{PowerIO.CArrowArray},))
const _POWERIO_ARROW_TEST_RELEASE_SCHEMA =
    @cfunction(_powerio_arrow_test_release_schema, Cvoid, (Ptr{PowerIO.CArrowSchema},))

function _powerio_arrow_release_callback_error(arr_release::Ptr{Cvoid},
                                               sch_release::Ptr{Cvoid})
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
    @testset "C Data Interface layout" begin
        @test sizeof(PowerIO.CArrowSchema) == 9 * sizeof(Ptr{Cvoid})
        @test sizeof(PowerIO.CArrowArray) == 10 * sizeof(Ptr{Cvoid})
        @test PowerIO.ArrowSchema === PowerIO.CArrowSchema
        @test PowerIO.ArrowArray === PowerIO.CArrowArray

        cc = get(ENV, "CC", "cc")
        dir = mktempdir()
        source = joinpath(dir, "arrow_layout_probe.c")
        exe = joinpath(dir, Sys.iswindows() ? "arrow_layout_probe.exe" : "arrow_layout_probe")
        write(source, """
        #include <stddef.h>
        #include <stdint.h>
        #include <stdio.h>

        struct ArrowSchema {
            const char *format;
            const char *name;
            const char *metadata;
            int64_t flags;
            int64_t n_children;
            struct ArrowSchema **children;
            struct ArrowSchema *dictionary;
            void (*release)(struct ArrowSchema *);
            void *private_data;
        };

        struct ArrowArray {
            int64_t length;
            int64_t null_count;
            int64_t offset;
            int64_t n_buffers;
            int64_t n_children;
            const void **buffers;
            struct ArrowArray **children;
            struct ArrowArray *dictionary;
            void (*release)(struct ArrowArray *);
            void *private_data;
        };

        int main(void) {
            printf("%zu\\n", sizeof(struct ArrowSchema));
            printf("%zu\\n", sizeof(struct ArrowArray));
            printf("%zu %zu %zu %zu %zu %zu %zu %zu %zu\\n",
                   offsetof(struct ArrowSchema, format),
                   offsetof(struct ArrowSchema, name),
                   offsetof(struct ArrowSchema, metadata),
                   offsetof(struct ArrowSchema, flags),
                   offsetof(struct ArrowSchema, n_children),
                   offsetof(struct ArrowSchema, children),
                   offsetof(struct ArrowSchema, dictionary),
                   offsetof(struct ArrowSchema, release),
                   offsetof(struct ArrowSchema, private_data));
            printf("%zu %zu %zu %zu %zu %zu %zu %zu %zu %zu\\n",
                   offsetof(struct ArrowArray, length),
                   offsetof(struct ArrowArray, null_count),
                   offsetof(struct ArrowArray, offset),
                   offsetof(struct ArrowArray, n_buffers),
                   offsetof(struct ArrowArray, n_children),
                   offsetof(struct ArrowArray, buffers),
                   offsetof(struct ArrowArray, children),
                   offsetof(struct ArrowArray, dictionary),
                   offsetof(struct ArrowArray, release),
                   offsetof(struct ArrowArray, private_data));
            return 0;
        }
        """)
        compiled = try
            run(Cmd([cc, source, "-o", exe]))
            true
        catch
            false
        end
        if !compiled
            @test_skip "C compiler unavailable for Arrow layout probe"
        else
            lines = split(readchomp(Cmd([exe])), '\n')
            @test parse(Int, lines[1]) == sizeof(PowerIO.CArrowSchema)
            @test parse(Int, lines[2]) == sizeof(PowerIO.CArrowArray)
            schema_offsets = parse.(Int, split(lines[3]))
            array_offsets = parse.(Int, split(lines[4]))
            @test schema_offsets == [fieldoffset(PowerIO.CArrowSchema, i) for i in 1:fieldcount(PowerIO.CArrowSchema)]
            @test array_offsets == [fieldoffset(PowerIO.CArrowArray, i) for i in 1:fieldcount(PowerIO.CArrowArray)]
        end
    end

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

        # Every raw table's row count matches the JSON payload's element count.
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

            # solver_bus grew area and zone at the end of its column list.
            @test solver_bus.area == fill(1, 14)
            @test solver_bus.zone == fill(1, 14)

            solver_gen = to_arrow(m, :solver_gen)
            @test solver_gen.bus_index == [0, 1, 2, 5, 7]

            # One cost header row per generator, slicing the coefficient table.
            cost = to_arrow(m, :solver_gen_cost)
            coeff = to_arrow(m, :solver_gen_cost_coeff)
            @test cost.index == solver_gen.index
            @test all(==(2), cost.model)
            @test cost.ncost == fill(3, 5)
            @test cost.coeff_count == fill(3, 5)
            @test cost.coeff_offset == collect(0:3:12)
            @test length(coeff.value) == sum(cost.coeff_count)
            @test coeff.gen_index[1:3] == fill(0, 3)
            @test coeff.position[1:3] == collect(0:2)
            # Position i of a k term polynomial scales by base^(k-1-i).
            @test coeff.value[1] ≈ 0.0430292599 * 100.0^2
            @test coeff.value[2] ≈ 20.0 * 100.0
            @test coeff.value[3] ≈ 0.0

            @test isempty(to_arrow(m, :solver_storage).index)
            @test isempty(to_arrow(m, :solver_hvdc).index)
            @test isempty(to_arrow(m, :solver_switch).index)
        end

        matrix_bus = optional_arrow(:matrix_bus)
        if matrix_bus === nothing
            @test_skip to_arrow(m, :matrix_bus)
        else
            @test matrix_bus.index == collect(0:13)
            @test matrix_bus.bus_id == collect(1:14)
            @test matrix_bus.source_row == collect(0:13)
            @test matrix_bus.is_reference[1] == 0x01
            @test all(==(0), matrix_bus.component)

            matrix_branch = to_arrow(m, :matrix_branch)
            @test matrix_branch.index == collect(0:19)
            @test matrix_branch.source_row == collect(0:19)
            @test matrix_branch.from_bus_id[1] == 1
            @test matrix_branch.to_bus_id[1] == 2
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
        err, arr, sch = _powerio_arrow_release_callback_error(
            C_NULL, _POWERIO_ARROW_TEST_RELEASE_SCHEMA)
        @test occursin("ArrowArray release callback is null", sprint(showerror, err))
        @test sch[].release == C_NULL
        err, arr, sch = _powerio_arrow_release_callback_error(
            _POWERIO_ARROW_TEST_RELEASE_ARRAY, C_NULL)
        @test occursin("ArrowSchema release callback is null", sprint(showerror, err))
        @test arr[].release == C_NULL

        @testset "explicit release callbacks" begin
            _POWERIO_ARROW_TEST_RELEASE_COUNT[] = 0
            arr = Ref(PowerIO.CArrowArray(0, 0, 0, 0, 0, C_NULL, C_NULL, C_NULL,
                                          _POWERIO_ARROW_TEST_RELEASE_ARRAY, C_NULL))
            sch = Ref(PowerIO.CArrowSchema(C_NULL, C_NULL, C_NULL, 0, 0, C_NULL,
                                           C_NULL, _POWERIO_ARROW_TEST_RELEASE_SCHEMA,
                                           C_NULL))
            buffers = PowerIO.ArrowBuffers(arr, sch)
            PowerIO._release_buffers!(buffers)
            @test _POWERIO_ARROW_TEST_RELEASE_COUNT[] == 2
            @test arr[].release == C_NULL
            @test sch[].release == C_NULL
            @test_nowarn PowerIO._release_buffers!(buffers)
            @test _POWERIO_ARROW_TEST_RELEASE_COUNT[] == 2
        end

        # copy=false: the zero copy ArrowTable path, same values. A column
        # extracted from the table roots the shared buffers on its own, so
        # it survives the table being collected (the old footgun).
        z = to_arrow(m, :bus; copy=false)
        @test z isa ArrowTable
        @test z.id == collect(1:14)
        @test z.id isa PowerIO.ArrowColumn{Int64}
        @test PowerIO.columns(z) isa NamedTuple
        # The raw unsafe_wrap array must not escape its rooting wrapper.
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

        z2b = to_arrow(m, :bus; copy=false)
        z2b_col = z2b.id
        release_c_data(z2b)
        @test_throws ErrorException z2b_col[1]
        @test_nowarn release_c_data(z2b)

        z3 = to_arrow(m, :bus; copy=false)
        z3_col = z3.id
        b3 = getfield(z3, :_buffers)
        finalize(b3)
        @test b3.array[].release == C_NULL
        @test b3.schema[].release == C_NULL
        @test_throws ErrorException z3_col[1]
        @test_nowarn finalize(b3)
        z3 = nothing
        z3_col = nothing
        GC.gc()

        z4 = to_arrow(m, :bus; copy=false)
        z4_col = z4.id
        release_c_data(z4_col)
        @test_throws ErrorException z4_col[1]
        @test_nowarn release_c_data(z4_col)

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
                # The version names the release that wrote the document, so it
                # moves every release while the rest of the fixture does not.
                # Hold it to what the library reports rather than re-vendoring.
                @test got.powerio_version == schema_versions().powerio_version
                @test got.format == expected["format"]
                @test got.row_axis == expected["row_axis"]
                @test got.col_axis == expected["col_axis"]
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
            bus_axis = to_arrow(path, :matrix_bus)
            expected_bus = fixture["axes"]["matrix_bus"]
            @test bus_axis.index == expected_bus["index"]
            @test bus_axis.bus_id == expected_bus["bus_id"]
            @test bus_axis.source_row == expected_bus["source_row"]
            @test bus_axis.is_reference == UInt8.(expected_bus["is_reference"])
            @test bus_axis.component == expected_bus["component"]

            branch_axis = to_arrow(path, :matrix_branch)
            expected_branch = fixture["axes"]["matrix_branch"]
            @test branch_axis.index == expected_branch["index"]
            @test branch_axis.source_row == expected_branch["source_row"]
            @test branch_axis.from_bus_id == expected_branch["from_bus_id"]
            @test branch_axis.to_bus_id == expected_branch["to_bus_id"]
        end

        if PowerIO.matrix_available() && matrix_bus !== nothing
            check_matrix_fixture("case9.m")
            check_matrix_fixture("case30.m")
            zmat = to_arrow(m, :bprime; copy=false)
            @test zmat.row_axis == "matrix_bus"
            @test zmat.col_axis == "matrix_bus"
            @test zmat.row_count == 14
            @test zmat.col_count == 14
            @test zmat.row_index isa PowerIO.ArrowColumn{Int64}
            zaxis = to_arrow(m, :matrix_bus; copy=false)
            @test zaxis.index isa PowerIO.ArrowColumn{Int64}
            @test zaxis.bus_id[1] == 1
            close(zmat)
            close(zaxis)
        elseif PowerIO.matrix_available()
            @test_skip to_arrow(m, :matrix_bus)
        else
            @test_throws ErrorException to_arrow(m, :bprime)
        end
    end
end

@testset "matrix Arrow fast-path validation" begin
    # `_check_matrix_axes` guards the row/col axis convention the sparse helpers
    # assume. Correct axes pass; a mismatch errors; a producer that omits the
    # axis (nothing) is tolerated for forward compatibility.
    @test PowerIO._check_matrix_axes(:ybus, "matrix_bus", "matrix_bus") === nothing
    @test PowerIO._check_matrix_axes(:incidence, "matrix_bus", "matrix_branch") === nothing
    @test PowerIO._check_matrix_axes(:ybus, nothing, nothing) === nothing
    @test_throws ErrorException PowerIO._check_matrix_axes(:ybus, "solver_bus", "matrix_bus")
    @test_throws ErrorException PowerIO._check_matrix_axes(:incidence, "matrix_bus", "matrix_bus")

    @test PowerIO._arrow_format_code(Int64) == "l"
    @test PowerIO._arrow_format_code(Float64) == "g"
    @test_throws ArgumentError PowerIO._arrow_format_code(Int32)

    # `_fast_child_column` must reject a producer whose declared Arrow format code
    # disagrees with the Julia type the matrix path reinterprets the buffer as —
    # otherwise a wrong-typed column would be read as garbage (or out of bounds).
    child_values = Int64[10, 20, 30]
    child_buffers = Ptr{Cvoid}[C_NULL, pointer(child_values)]
    child_arr = Ref(PowerIO.CArrowArray(3, 0, 0, 2, 0, pointer(child_buffers),
                                        C_NULL, C_NULL, C_NULL, C_NULL))
    name_bytes = UInt8[0x72, 0x6f, 0x77, 0x00]  # "row"
    good_format = UInt8[0x6c, 0x00]             # "l" (int64)
    bad_format = UInt8[0x67, 0x00]              # "g" (float64), mismatched
    arr_children = Ptr{PowerIO.CArrowArray}[
        Base.unsafe_convert(Ptr{PowerIO.CArrowArray}, child_arr)]
    root_arr = Ref(PowerIO.CArrowArray(3, 0, 0, 0, 1, C_NULL,
                                       pointer(arr_children), C_NULL, C_NULL, C_NULL))
    GC.@preserve child_values child_buffers child_arr arr_children name_bytes good_format bad_format begin
        good_child_sch = Ref(PowerIO.CArrowSchema(Ptr{Cchar}(pointer(good_format)),
                                                  Ptr{Cchar}(pointer(name_bytes)),
                                                  C_NULL, 0, 0, C_NULL, C_NULL, C_NULL, C_NULL))
        bad_child_sch = Ref(PowerIO.CArrowSchema(Ptr{Cchar}(pointer(bad_format)),
                                                 Ptr{Cchar}(pointer(name_bytes)),
                                                 C_NULL, 0, 0, C_NULL, C_NULL, C_NULL, C_NULL))
        good_sch_children = Ptr{PowerIO.CArrowSchema}[
            Base.unsafe_convert(Ptr{PowerIO.CArrowSchema}, good_child_sch)]
        bad_sch_children = Ptr{PowerIO.CArrowSchema}[
            Base.unsafe_convert(Ptr{PowerIO.CArrowSchema}, bad_child_sch)]
        GC.@preserve good_child_sch bad_child_sch good_sch_children bad_sch_children begin
            good_root_sch = Ref(PowerIO.CArrowSchema(C_NULL, C_NULL, C_NULL, 0, 1,
                                                     pointer(good_sch_children), C_NULL, C_NULL, C_NULL))
            bad_root_sch = Ref(PowerIO.CArrowSchema(C_NULL, C_NULL, C_NULL, 0, 1,
                                                    pointer(bad_sch_children), C_NULL, C_NULL, C_NULL))
            @test PowerIO._fast_child_column(Int64, root_arr, good_root_sch, 1, 3, :row) == child_values
            @test_throws ErrorException PowerIO._fast_child_column(Int64, root_arr, bad_root_sch, 1, 3, :row)
        end
    end

    # A corrupt metadata length prefix (here a huge key length) must error at the
    # ceiling instead of walking `unsafe_load` off the end of the block.
    huge = reinterpret(UInt8, [Int32(1)])                    # npairs = 1
    huge = vcat(huge, reinterpret(UInt8, [Int32(1 << 24)]))  # klen far past the byte ceiling
    GC.@preserve huge begin
        bad_meta_sch = PowerIO.CArrowSchema(C_NULL, C_NULL, Ptr{Cchar}(pointer(huge)),
                                            0, 0, C_NULL, C_NULL, C_NULL, C_NULL)
        @test_throws ErrorException PowerIO._matrix_axis_metadata(bad_meta_sch)
    end
end

@testset "arrow catalog" begin
    if !PowerIO.library_available() || !PowerIO._exports_symbol(:pio_arrow_catalog_json)
        @test_skip arrow_catalog()
    else
        catalog = arrow_catalog()
        @test haskey(catalog, :powerio_version)
        @test occursin("powerio", String(catalog.producer))
        names = Set(String(t.name) for t in catalog.tables)
        # The catalog is feature based: it lists every table this build can
        # export, and each entry says whether it is available here.
        for known in keys(PowerIO._ARROW_TABLE_IDS)
            @test String(known) in names
        end
        for t in catalog.tables
            @test haskey(t, :id) && haskey(t, :available) && haskey(t, :columns)
        end
        bus = only(t for t in catalog.tables if String(t.name) == "bus")
        @test any(c -> String(c.name) == "id", bus.columns)
    end
end
