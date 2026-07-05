using SparseArrays

@testset "Matrix API" begin
    data = joinpath(@__DIR__, "data")
    m = joinpath(data, "case14.m")
    if !(PowerIO.library_available() && PowerIO.arrow_available())
        @test_skip calc_admittance_matrix(m)
    elseif !PowerIO.matrix_available()
        @test_throws ErrorException calc_admittance_matrix(m)
        @test_throws ErrorException calc_susceptance_matrix(m)
        @test_throws ErrorException calc_incidence_matrix(m)
        @test_throws ErrorException calc_bprime_matrix(m)
        @test_throws ErrorException calc_bdoubleprime_matrix(m)
    else
        net = parse_file(m)

        sparse_from_coo(coo, values) = sparse(
            coo.row_index .+ 1,
            coo.col_index .+ 1,
            values,
            coo.row_count,
            coo.col_count,
        )

        matrix_bus_maps(net) = begin
            axis = to_arrow(net, :matrix_bus)
            idx_to_bus = Vector{Int}(undef, length(axis.index))
            for k in eachindex(axis.index)
                idx_to_bus[axis.index[k] + 1] = axis.bus_id[k]
            end
            idx_to_bus, Dict(id => idx for (idx, id) in enumerate(idx_to_bus))
        end

        idx_to_bus, bus_to_idx = matrix_bus_maps(net)

        ybus_coo = to_arrow(m, :ybus)
        ybus_expected = sparse_from_coo(ybus_coo, ybus_coo.g .+ im .* ybus_coo.b)
        ybus = calc_admittance_matrix(m)
        @test ybus isa PowerIO.AdmittanceMatrix{ComplexF64}
        @test ybus.matrix == ybus_expected
        @test calc_admittance_matrix(net).matrix == ybus.matrix
        @test ybus.idx_to_bus == idx_to_bus
        @test ybus.bus_to_idx == bus_to_idx

        bprime_coo = to_arrow(m, :bprime)
        bprime_expected = sparse_from_coo(bprime_coo, bprime_coo.value)
        bprime = calc_bprime_matrix(m)
        @test bprime isa PowerIO.AdmittanceMatrix{Float64}
        @test bprime.matrix == bprime_expected
        @test bprime.idx_to_bus == idx_to_bus
        @test bprime.bus_to_idx == bus_to_idx

        susceptance = calc_susceptance_matrix(m)
        @test susceptance isa PowerIO.AdmittanceMatrix{Float64}
        @test susceptance.matrix == -bprime.matrix
        @test susceptance.idx_to_bus == idx_to_bus
        @test susceptance.bus_to_idx == bus_to_idx

        bdoubleprime_coo = to_arrow(m, :bdoubleprime)
        bdoubleprime_expected = sparse_from_coo(bdoubleprime_coo, bdoubleprime_coo.value)
        bdoubleprime = calc_bdoubleprime_matrix(m)
        @test bdoubleprime isa PowerIO.AdmittanceMatrix{Float64}
        @test bdoubleprime.matrix == bdoubleprime_expected

        incidence_coo = to_arrow(m, :incidence)
        @test incidence_coo.row_axis == "matrix_bus"
        @test incidence_coo.col_axis == "matrix_branch"
        incidence_expected = sparse_from_coo(incidence_coo, incidence_coo.value)
        incidence = calc_incidence_matrix(m)
        @test incidence isa SparseMatrixCSC{Float64,Int}
        @test size(incidence) == (incidence_coo.row_count, incidence_coo.col_count)
        @test incidence == incidence_expected
        @test calc_incidence_matrix(net) == incidence
    end
end
