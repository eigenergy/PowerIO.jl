# AirspeedVelocity.jl suite: PowerIO's own parse and element access performance
# across commits. The benchmark workflow (.github/workflows/benchmark.yml) runs
# this on a pull request and its base branch on the same runner and comments
# the comparison. The cross tool snapshot lives in the powerio repository's
# evals/performance/RESULTS.md.
#
# Locally: build the C library in a sibling powerio checkout
# (`cargo build -p powerio-capi --release`) so PowerIO finds it, then run with
# AirspeedVelocity's `benchpkg`.

using BenchmarkTools, PowerIO

const SUITE = BenchmarkGroup()
const CASE = joinpath(@__DIR__, "..", "test", "data", "case14.m")

# Parsing is deferred into the benchmark (and into `setup` for the element
# access), so loading the suite never calls the C library; the benchmark
# process resolves the library at run time (POWERIO_CAPI in CI, the sibling
# checkout locally).
SUITE["parse"] = @benchmarkable parse($CASE)
SUITE["counts"] = @benchmarkable(
    (length(net.buses), length(net.branches), net.base_mva),
    setup = (net = parse($CASE).value),
)
SUITE["buses"] = @benchmarkable collect(net.buses) setup = (net = parse($CASE).value)
SUITE["to_dense"] = @benchmarkable to_dense(net) setup = (net = parse($CASE).value)
SUITE["admittance"] = @benchmarkable calc_admittance_matrix(net) setup = (net = parse($CASE).value)
