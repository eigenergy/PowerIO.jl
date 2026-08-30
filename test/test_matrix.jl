using SparseArrays

@testset "Matrix API" begin
    data = joinpath(@__DIR__, "data")
    m = joinpath(data, "case14.m")
    if !(PowerIO.library_available() && PowerIO.arrow_available())
        @test_skip calc_admittance_matrix(m)
    else
        case_module = parse_file(m)
        net = case_module.value

        # The path forms parse through the module and agree with the
        # network-first forms.
        @test calc_admittance_matrix(m).matrix == calc_admittance_matrix(net).matrix
        @test calc_susceptance_matrix(m).matrix == calc_susceptance_matrix(net).matrix
        @test calc_incidence_matrix(m).matrix == calc_incidence_matrix(net).matrix
        @test calc_bprime_matrix(m).matrix == calc_bprime_matrix(net).matrix
        @test calc_bdoubleprime_matrix(m).matrix == calc_bdoubleprime_matrix(net).matrix

        # A parsed module is the ordinary input; forwarding reaches the same
        # live value without materializing its JSON payload.
        @test calc_admittance_matrix(case_module).matrix == calc_admittance_matrix(net).matrix
        @test calc_susceptance_matrix(case_module).matrix == calc_susceptance_matrix(net).matrix
        # The module overload uses the canonical branches by buses
        # orientation. The network overload remains bus by branch for 0.10.
        @test Matrix(calc_incidence_matrix(case_module)) ==
              Matrix(calc_incidence_matrix(net).matrix)'
        @test calc_bprime_matrix(case_module).matrix == calc_bprime_matrix(net).matrix
        @test calc_bdoubleprime_matrix(case_module).matrix == calc_bdoubleprime_matrix(net).matrix

        if try
            to_arrow(m, :ybus)
            false
        catch e
            !occursin("does not support table", sprint(showerror, e)) && rethrow()
            true
        end
            @test_throws ErrorException calc_admittance_matrix(net)
            @test_throws ErrorException calc_susceptance_matrix(net)
            @test_throws ErrorException calc_incidence_matrix(net)
            @test_throws ErrorException calc_bprime_matrix(net)
            @test_throws ErrorException calc_bdoubleprime_matrix(net)
        else
            @test getfield(net, :data) === nothing

            sparse_from_coo(coo, values) = sparse(
                coo.row_index .+ 1,
                coo.col_index .+ 1,
                values,
                coo.row_count,
                coo.col_count,
            )

            matrix_bus_maps_if_available(net) = begin
                axis = try
                    to_arrow(net, :matrix_bus)
                catch e
                    occursin("does not support table", sprint(showerror, e)) || rethrow()
                    return nothing
                end
                idx_to_bus = Vector{Int}(undef, length(axis.index))
                for k in eachindex(axis.index)
                    idx_to_bus[axis.index[k] + 1] = axis.bus_id[k]
                end
                idx_to_bus, Dict(id => idx for (idx, id) in enumerate(idx_to_bus))
            end

            ybus_coo = to_arrow(m, :ybus)
            @test to_arrow(case_module, :ybus) == ybus_coo
            ybus_expected = sparse_from_coo(ybus_coo, ybus_coo.g .+ im .* ybus_coo.b)
            ybus = calc_admittance_matrix(net)
            @test ybus isa BusMappedMatrix{ComplexF64}
            @test ybus.matrix == ybus_expected
            @test getfield(net, :data) === nothing
            axis_maps = matrix_bus_maps_if_available(net)
            if axis_maps !== nothing
                @test ybus.idx_to_bus == axis_maps[1]
                @test ybus.bus_to_idx == axis_maps[2]
            end
            idx_to_bus, bus_to_idx = ybus.idx_to_bus, ybus.bus_to_idx
            @test ybus.idx_to_bus == idx_to_bus
            @test ybus.bus_to_idx == bus_to_idx

            bprime_coo = to_arrow(m, :bprime)
            bprime_expected = sparse_from_coo(bprime_coo, bprime_coo.value)
            bprime = calc_bprime_matrix(net)
            @test bprime isa BusMappedMatrix{Float64}
            @test bprime.matrix == bprime_expected
            @test getfield(net, :data) === nothing
            @test bprime.idx_to_bus == idx_to_bus
            @test bprime.bus_to_idx == bus_to_idx

            susceptance = calc_susceptance_matrix(net)
            @test susceptance isa BusMappedMatrix{Float64}
            @test susceptance.matrix == -bprime.matrix
            @test getfield(net, :data) === nothing
            @test susceptance.idx_to_bus == idx_to_bus
            @test susceptance.bus_to_idx == bus_to_idx

            bdoubleprime_coo = to_arrow(m, :bdoubleprime)
            bdoubleprime_expected = sparse_from_coo(bdoubleprime_coo, bdoubleprime_coo.value)
            bdoubleprime = calc_bdoubleprime_matrix(net)
            @test bdoubleprime isa BusMappedMatrix{Float64}
            @test bdoubleprime.matrix == bdoubleprime_expected
            @test getfield(net, :data) === nothing

            incidence_coo = to_arrow(m, :incidence)
            @test incidence_coo.row_axis in ("matrix_bus", "solver_bus")
            @test incidence_coo.col_axis in ("matrix_branch", "solver_branch")
            incidence_expected = sparse_from_coo(incidence_coo, incidence_coo.value)
            incidence = calc_incidence_matrix(net)
            # Wrapped like its four siblings, so the bus id maps travel with it. The
            # columns are branches, which the wrapper does not name.
            @test incidence isa BusMappedMatrix{Float64}
            @test incidence.matrix isa SparseMatrixCSC{Float64,Int}
            @test size(incidence.matrix) == (incidence_coo.row_count, incidence_coo.col_count)
            @test incidence.matrix == incidence_expected
            @test incidence.idx_to_bus == collect(1:14)
            @test incidence.bus_to_idx[7] == 7
            @test occursin("BusMappedMatrix", sprint(show, incidence))
            @test getfield(net, :data) === nothing
        end
    end
end
