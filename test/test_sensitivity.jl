using Test

@testset "PTDF sensitivity" begin
    net = parse(fixture("case9.m")).value

    result = calc_ptdf(net)
    @test result isa PTDFResult
    @test result.reference_bus == 1
    @test result.bus_axis == [2, 3, 4, 5, 6, 7, 8, 9]
    @test result.branch_axis == collect(1:9)
    @test size(result.matrix) == (9, 8)

    axes = calc_dc_index_map(net)
    p = zeros(length(axes.idx_to_bus))
    p[axes.bus_to_idx[2]] = 1.0
    p[axes.bus_to_idx[1]] = -1.0
    keep = [i for i in eachindex(axes.idx_to_bus) if i != axes.bus_to_idx[1]]
    B = calc_bus_susceptance_matrix(net)
    Bf = calc_branch_flow_matrix(net)
    theta = zeros(length(axes.idx_to_bus))
    theta[keep] = -(B[keep, keep] \ p[keep])
    expected = -(Bf * theta)
    @test result.matrix[:, 1] ≈ expected atol = 1e-10

    alt = calc_ptdf(net; reference_bus=4)
    @test alt.reference_bus == 4
    @test alt.bus_axis == [1, 2, 3, 5, 6, 7, 8, 9]
    @test calc_ptdf(net; reference_bus=1).matrix == result.matrix
    @test calc_ptdf(parse(fixture("case9.m"))).matrix == result.matrix
    @test_throws ArgumentError calc_ptdf(net; reference_bus=999)
    @test_throws ArgumentError calc_ptdf(net; reference_bus=:invalid)
end