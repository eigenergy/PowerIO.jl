# AirspeedVelocity.jl suite: track PowerIO's own parse and accessor performance
# across commits. The benchmark workflow (.github/workflows/benchmark.yml) runs this
# on a PR and its base branch on the same runner and comments the comparison. This
# tracks self-regression over history; the cross-tool snapshot (powerio vs the field)
# lives in the powerio repo's benchmarks/RESULTS.md.
#
# Locally: build the C ABI in a sibling powerio checkout (`cargo build -p powerio-capi
# --release`) so PowerIO finds it, then run with AirspeedVelocity's `benchpkg`.

using BenchmarkTools, PowerIO

const SUITE = BenchmarkGroup()
const CASE = joinpath(@__DIR__, "..", "test", "data", "case14.m")

# The parse is deferred into the benchmark (and into `setup` for the accessors), so
# loading the suite never calls the C ABI; the benchmark process resolves the library
# at run time (POWERIO_CAPI in CI, the sibling checkout locally).
SUITE["parse_file"] = @benchmarkable parse_file($CASE)
SUITE["accessors"] = @benchmarkable(
    (PowerIO.n_buses(net), PowerIO.n_branches(net), PowerIO.base_mva(net)),
    setup = (net = parse_file($CASE)),
)
