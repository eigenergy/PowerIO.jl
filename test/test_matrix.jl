# Reference values: the Python binding (`powerio` 0.11.0) on the same fixtures,
# and the coordinate lists the powerio matrix crate wrote for case9 and case30.

function coo_from_fixture(path)
    doc = JSON3.read(read(path, String))
    bus_ids = Int.(doc.axes.matrix_bus.bus_id)
    tables = Dict{String,Any}()
    for (name, table) in pairs(doc.tables)
        n = Int(table.row_count)
        rows = Int.(table.row_index) .+ 1
        cols = Int.(table.col_index) .+ 1
        bits(key) = [reinterpret(Float64, Base.parse(UInt64, s)) for s in getproperty(table, key)]
        values = haskey(table, :b_bits) ? complex.(bits(:g_bits), bits(:b_bits)) : bits(:value_bits)
        tables[String(name)] = sparse(rows, cols, values, n, Int(table.col_count))
    end
    return bus_ids, tables
end

@testset "matrices" begin
    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        m = parse(fixture("case9.m"))
        net = m.value

        @testset "DC calculations from the library" begin
            A = calc_incidence_matrix(net)
            @test A isa SparseMatrixCSC{Float64,Int}
            @test size(A) == (9, 9)
            @test nnz(A) == 18
            @test Vector(A[1, :]) == [1, 0, 0, -1, 0, 0, 0, 0, 0]
            @test all(sum(A; dims=2) .== 0)

            b = calc_branch_susceptances(net)
            @test length(b) == 9
            @test b[1] ≈ -1 / 0.0576
            @test b ≈ [-17.3611, -10.5107, -5.5882, -17.0648, -9.7843, -13.698, -16.0, -5.9751, -11.6041] atol = 1e-4

            B = calc_bus_susceptance_matrix(net)
            @test size(B) == (9, 9)
            @test B ≈ A' * spdiagm(b) * A
            @test Vector(B[1, :]) ≈ [-17.3611, 0, 0, 17.3611, 0, 0, 0, 0, 0] atol = 1e-4
            @test abs(sum(B)) < 1e-9

            Bf = calc_branch_flow_matrix(net)
            @test size(Bf) == (9, 9)
            @test Bf ≈ spdiagm(b) * A

            @test calc_branch_phase_shift_injection(net) == zeros(9)
            @test calc_bus_phase_shift_injection(net) == zeros(9)

            va = zeros(9)
            va[2] = 0.1
            flow = calc_branch_flow_dc(net, va)
            @test length(flow) == 9
            @test flow ≈ [0, 0, 0, 0, 0, 0, -1.6, 0, 0] atol = 1e-9
            injection = calc_bus_injection_dc(net, va)
            @test injection ≈ [0, 1.6, 0, 0, 0, 0, 0, -1.6, 0] atol = 1e-9
            # The bus injection is the negated susceptance product plus the phase
            # shift injection, which is zero for case9.
            @test calc_bus_injection_dc(net, va) ≈ -(B * va)
            @test calc_branch_flow_dc(net, va) ≈ -(Bf * va)
            @test calc_branch_flow_dc(m, va) == flow
            @test calc_incidence_matrix(m) == A
            @test_throws PowerIOError calc_incidence_matrix(net; formula="not-a-formula")
            @test_throws PowerIOError calc_branch_flow_dc(net, zeros(3))
        end

        @testset "DC index map" begin
            axes = calc_dc_index_map(net)
            @test axes.idx_to_bus == [b.id for b in net.buses]
            @test axes.bus_to_idx[axes.idx_to_bus[3]] == 3
            @test axes.idx_to_branch == 1:9
            @test length(axes.branch_ids) == 9 && all(id -> id isa String, axes.branch_ids)
            @test isempty(axes.skipped_branch_rows)
            @test size(calc_incidence_matrix(net)) == (length(axes.branch_ids), length(axes.idx_to_bus))
            @test calc_dc_index_map(m) == axes

            # An out of service branch has no row; the map says which rows remain.
            raw = parse(fixture("psse", "case3_3w_v33.raw")).value
            raw_axes = calc_dc_index_map(raw)
            @test length(raw_axes.branch_ids) == size(calc_incidence_matrix(raw), 1)
            @test all(1 .<= raw_axes.idx_to_branch)
        end

        @testset "zero impedance branches" begin
            tie = parse(fixture("zero_impedance.m")).value
            err = try
                calc_incidence_matrix(tie)
                nothing
            catch e
                e
            end
            @test err isa PowerIOError && err.code == "BUILD.OPERATOR.ZERO_IMPEDANCE"
            @test_throws PowerIOError calc_bus_susceptance_matrix(tie)
            @test_throws PowerIOError calc_dc_index_map(tie)

            axes = calc_dc_index_map(tie; skip_zero_impedance=true)
            @test axes.skipped_branch_rows == [1]
            @test axes.idx_to_branch == [2]
            @test size(calc_incidence_matrix(tie; skip_zero_impedance=true)) == (1, 3)
            @test length(calc_branch_susceptances(tie; skip_zero_impedance=true)) == 1
            @test size(calc_bus_susceptance_matrix(tie; skip_zero_impedance=true)) == (3, 3)
            @test length(calc_branch_flow_dc(tie, [0.0, 0.0, 0.1]; skip_zero_impedance=true)) == 1
            @test length(calc_bus_injection_dc(tie, [0.0, 0.0, 0.1]; skip_zero_impedance=true)) == 3

            # The Julia assembled matrices report the same code and honor the same option.
            yerr = try
                calc_admittance_matrix(tie)
                nothing
            catch e
                e
            end
            @test yerr isa PowerIOError && yerr.code == "BUILD.OPERATOR.ZERO_IMPEDANCE"
            @test_throws PowerIOError calc_bprime_matrix(tie)
            @test size(calc_admittance_matrix(tie; skip_zero_impedance=true)) == (3, 3)
            @test length(calc_branch_admittances(tie; skip_zero_impedance=true)) == 1
            @test_throws PowerIOError calc_branch_admittances(tie)
        end

        @testset "branch admittances" begin
            prims = calc_branch_admittances(net)
            @test length(prims) == 9
            @test all(p -> p isa NTuple{4,ComplexF64}, prims)
            Y = calc_admittance_matrix(net)
            rebuilt = zeros(ComplexF64, 9, 9)
            for (k, br) in enumerate(net.branches)
                i = Y.bus_to_idx[br.from_bus_id]
                j = Y.bus_to_idx[br.to_bus_id]
                y_ff, y_ft, y_tf, y_tt = prims[k]
                rebuilt[i, i] += y_ff
                rebuilt[j, j] += y_tt
                rebuilt[i, j] += y_ft
                rebuilt[j, i] += y_tf
            end
            @test rebuilt ≈ Matrix(Y.matrix)   # case9 has no bus shunts
            pd = to_powerdata(net)
            for (k, row) in enumerate(pd.branch)
                y_ff, y_ft, y_tf, y_tt = prims[k]
                @test complex(row.c1, row.c2) ≈ y_tf
                @test complex(row.c3, row.c4) ≈ y_ft
                @test complex(row.c5, row.c6) ≈ y_ff
                @test complex(row.c7, row.c8) ≈ y_tt
            end
        end

        @testset "admittance matrix" begin
            Y = calc_admittance_matrix(net)
            @test Y isa BusMappedMatrix{ComplexF64}
            @test Y.idx_to_bus == 1:9
            @test Y.bus_to_idx[4] == 4
            @test size(Y) == (9, 9)
            @test nnz(Y.matrix) == 27
            @test Y.matrix[1, 1] ≈ -17.36111111111111im
            @test Y.matrix[1, 4] ≈ 17.36111111111111im
            @test Y.matrix ≈ transpose(Y.matrix)
            @test calc_admittance_matrix(m).matrix == Y.matrix
            @test calc_admittance_matrix(fixture("case9.m")).matrix == Y.matrix
            @test occursin("9 buses, 27 stored entries", sprint(show, Y))

            Bp = calc_bprime_matrix(net)
            @test Bp isa BusMappedMatrix{Float64}
            @test Bp.matrix[1, 1] ≈ 17.36111111111111
            @test Bp.matrix[1, 4] ≈ -17.36111111111111
            Bpp = calc_bdoubleprime_matrix(net)
            @test Bpp.matrix[1, 1] ≈ 17.36111111111111
            @test_throws ArgumentError calc_bprime_matrix(net; scheme=:zz)

            Y14 = calc_admittance_matrix(parse(fixture("case14.m")).value)
            @test nnz(Y14.matrix) == 54
            @test Y14.matrix[1, 1] ≈ 6.025029055768224 - 19.44707020551438im
            @test Y14.matrix[4, 7] ≈ 4.889512660317341im
            @test Y14.matrix[4, 7] == Y14.matrix[7, 4]
        end

        @testset "admittance matrices match the Rust matrix crate" begin
            for (case, path) in (("case9.m", fixture("capi_matrix", "case9_arrow_coo.json")),
                                 ("case30.m", fixture("capi_matrix", "case30_arrow_coo.json")))
                bus_ids, tables = coo_from_fixture(path)
                network = parse(fixture(case)).value
                Y = calc_admittance_matrix(network)
                @test Y.idx_to_bus == bus_ids
                @test Matrix(Y.matrix) ≈ Matrix(tables["ybus"]) rtol = 1e-12
                @test nnz(Y.matrix) == nnz(tables["ybus"])
                @test Matrix(calc_bprime_matrix(network).matrix) ≈ Matrix(tables["bprime"]) rtol = 1e-12
                @test Matrix(calc_bdoubleprime_matrix(network).matrix) ≈ Matrix(tables["bdoubleprime"]) rtol = 1e-12
                # The fixture stores the bus by branch orientation; ABI 7 is branch by bus.
                @test Matrix(calc_incidence_matrix(network)) ≈ Matrix(tables["incidence"])'
            end
        end

        @testset "taps and shifts" begin
            raw = parse(fixture("psse", "case3_3w_v33.raw")).value
            # No two winding branches: the admittance matrix is the shunts alone.
            Y = calc_admittance_matrix(raw)
            @test size(Y) == (3, 3)
            net14 = parse(fixture("case14.m")).value
            with = calc_admittance_matrix(net14)
            without = calc_admittance_matrix(net14; include_taps=false)
            @test with.matrix != without.matrix
            @test calc_admittance_matrix(net14; include_shifts=false).matrix == with.matrix
        end
    end
end
