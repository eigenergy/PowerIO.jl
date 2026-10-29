# AC islands and DC sensitivity factors from the library. Reference values:
# MATPOWER's makePTDF over makeBdc (b = 1 / (x * tap), slack bus 1) evaluated
# on the case14.m branch table with plain LinearAlgebra, and the DC formula
# PTDF[:, nonref] = Bf[:, nonref] / B[nonref, nonref] over the matrices this
# package already reads from the library. Matrix division comes from
# LinearAlgebra, which SparseArrays loads.

@testset "islands and sensitivities" begin
    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        case14 = parse(fixture("case14.m"))
        net14 = case14.value

        @testset "case14 is one supplied island" begin
            r = network_islands(net14)
            @test r isa NetworkIslands
            @test length(r) == 1
            island = only(r)
            @test island isa Island
            @test island.bus_ids == collect(1:14)
            @test island.bus_indices == collect(1:14)
            @test island.reference_bus_ids == [1]
            @test island.reference_bus_indices == [1]
            @test island.generator_rows == collect(1:5)
            @test island.hvdc_rows == Int[]
            @test island.supplied
            @test r.isolated_bus_ids == Int[]
            @test network_islands(case14).islands[1].bus_ids == island.bus_ids
        end

        @testset "two islands and an isolated bus" begin
            net = parse(fixture("islands.m")).value
            r = network_islands(net)
            @test length(r) == 2
            a, b = r[1], r[2]
            @test a.bus_ids == [1, 2, 3]
            @test a.bus_indices == [1, 2, 3]
            @test a.reference_bus_ids == [1]
            @test a.generator_rows == [1]
            @test a.supplied
            @test b.bus_ids == [4, 5]
            @test b.bus_indices == [4, 5]
            @test b.reference_bus_ids == [4]
            @test b.reference_bus_indices == [4]
            @test b.generator_rows == [2]
            @test b.supplied
            # Bus 6 is typed isolated: it belongs to no island, and its out of
            # service branch to bus 5 joins nothing.
            @test r.isolated_bus_ids == [6]
            @test r.isolated_bus_indices == [6]
            @test [i.bus_ids for i in r] == [[1, 2, 3], [4, 5]]

            # The DC builders ground every connected component of the in
            # service branches; bus 6 stands alone with no reference.
            err = try
                calc_ptdf(net)
                nothing
            catch e
                e
            end
            @test err isa PowerIOError
            @test err.code == "BUILD.INDEX.UNGROUNDED_COMPONENT"
        end

        @testset "PTDF grounds one reference per island" begin
            net = parse(fixture("two_islands.m")).value
            for solver in (:auto, :dense, :sparse, "sparse")
                H = calc_ptdf(net; solver)
                @test H isa PtdfMatrix
                @test size(H) == (4, 5)
                @test H.idx_to_branch == [1, 2, 3, 4]
                @test H.idx_to_bus == [1, 2, 3, 4, 5]
                @test H.reference_bus_ids == [1, 4]
                @test H.reference_bus_indices == [1, 4]
                # Reference columns are zero, and an injection in one island
                # moves no flow in the other.
                @test all(iszero, H.matrix[:, [1, 4]])
                @test all(iszero, H.matrix[1:3, 5])
                @test all(iszero, H.matrix[4, 2:3])
                # A unit at bus 5 returns to reference 4 over branch 4-5.
                @test H.matrix[4, 5] ≈ -1 atol = 1e-12
                # A unit at bus 2 returns to bus 1 over two paths, branch 1-2
                # and branches 2-3 and 1-3 in series, split by their series
                # susceptances x / (r^2 + x^2).
                b = [x / (0.01^2 + x^2) for x in (0.10, 0.20, 0.25)]
                direct = b[1] / (b[1] + 1 / (1 / b[2] + 1 / b[3]))
                @test H.matrix[1, 2] ≈ -direct atol = 1e-12
            end
            @test calc_ptdf(net; solver=:dense).matrix ≈ calc_ptdf(net; solver=:sparse).matrix atol = 1e-12

            L = calc_lodf(net)
            @test L isa LodfMatrix
            @test size(L) == (4, 4)
            @test L.reference_bus_ids == [1, 4]
            @test all(L.matrix[k, k] == -1 for k in 1:4)
            # Branch 4-5 is the only path to bus 5: its outage moves its flow
            # nowhere, and no outage in the triangle reaches it.
            @test all(iszero, L.matrix[1:3, 4])
            @test all(iszero, L.matrix[4, 1:3])
        end

        @testset "case14 PTDF matches MATPOWER makePTDF" begin
            H = calc_ptdf(case14; formula="tap_adjusted_reactance")
            @test size(H) == (20, 14)
            @test H.reference_bus_ids == [1]
            @test all(iszero, H.matrix[:, 1])
            for (branch, bus, matpower) in ((1, 2, -0.8380186496174302),
                                            (7, 4, 0.5025721025342245),
                                            (8, 7, -0.6338316009274548),
                                            (20, 14, -0.39918222618560356))
                @test H.matrix[branch, H.bus_to_idx[bus]] ≈ matpower atol = 1e-12
            end
        end

        @testset "case14 PTDF and LODF match the DC formula" begin
            for formula in ("series_susceptance", "tap_adjusted_reactance", "reactance_only")
                H = calc_ptdf(net14; formula)
                index = calc_dc_index_map(net14; formula)
                @test H.idx_to_branch == index.idx_to_branch
                @test H.branch_ids == index.branch_ids
                @test H.idx_to_bus == index.idx_to_bus
                B = Matrix(calc_bus_susceptance_matrix(net14; formula))
                Bf = Matrix(calc_branch_flow_matrix(net14; formula))
                nonref = setdiff(1:14, H.reference_bus_indices)
                expected = zeros(20, 14)
                expected[:, nonref] = Bf[:, nonref] / B[nonref, nonref]
                @test H.matrix ≈ expected atol = 1e-10
                @test calc_ptdf(net14; formula, solver=:sparse).matrix ≈ expected atol = 1e-10

                # LODF[l, k] = PTDF_b[l, k] / (1 - PTDF_b[k, k]) with
                # PTDF_b = H * A', the diagonal -1, and a zero column for an
                # outage that splits the island.
                L = calc_lodf(net14; formula)
                @test L.idx_to_branch == H.idx_to_branch
                A = Matrix(calc_incidence_matrix(net14; formula))
                Pb = H.matrix * A'
                for k in 1:20, l in 1:20
                    if l == k
                        @test L.matrix[l, k] == -1
                    elseif abs(1 - Pb[k, k]) < 1e-9
                        @test L.matrix[l, k] == 0
                    else
                        @test L.matrix[l, k] ≈ Pb[l, k] / (1 - Pb[k, k]) atol = 1e-9
                    end
                end
            end
        end

        @testset "option errors" begin
            err = try
                calc_ptdf(net14; solver=:cholesky)
                nothing
            catch e
                e
            end
            @test err isa PowerIOError
            @test err.code == "BIND.CAPI.INVALID_ARGUMENT"
            err = try
                calc_lodf(net14; formula="admittance")
                nothing
            catch e
                e
            end
            @test err isa PowerIOError
            @test err.code == "REQUEST.CAPI.UNKNOWN_FORMULA"
        end
    end
end
