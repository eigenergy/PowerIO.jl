# Local timing of the binding against the powerio test cases in a sibling
# checkout: parse, element access, dense tables, the admittance matrix, and the
# multiconductor reader. Run with `julia --project=. benchmark/local_benchmarks.jl`
# after building the C library.

using BenchmarkTools
using Logging
using PowerIO

const ROOT = normpath(joinpath(@__DIR__, ".."))
const POWERIO_ROOT = normpath(joinpath(ROOT, "..", "powerio"))
const BALANCED_CASE = joinpath(POWERIO_ROOT, "tests", "data", "case2869pegase.m")
const DIST_CASE = joinpath(POWERIO_ROOT, "tests", "data", "dist", "opendss", "ieee13", "IEEE13Nodeckt.dss")

const HAS_PMD = try
    @eval using PowerModelsDistribution
    true
catch
    false
end

function trial(label, bench)
    result = run(bench)
    best = minimum(result)
    println(rpad(label, 44), lpad(round(best.time / 1e6; digits=3), 10), " ms  ",
            lpad(best.allocs, 10), " allocs  ",
            lpad(round(best.memory / 1024 / 1024; digits=3), 10), " MiB")
end

function main()
    println("PowerIO library: ", PowerIO._lib())
    println("PowerIO library version: ", PowerIO.library_version())
    println("balanced case: ", BALANCED_CASE)
    println("distribution case: ", DIST_CASE)
    println()
    println(rpad("benchmark", 44), lpad("time", 10), "      ",
            lpad("allocs", 10), "      ", lpad("memory", 10))

    balanced = parse(BALANCED_CASE).value
    dist = parse(DIST_CASE).value

    trial("balanced parse(case2869pegase)", @benchmarkable parse($BALANCED_CASE))
    trial("balanced collect(net.buses)", @benchmarkable collect($balanced.buses))
    trial("balanced collect(net.branches)", @benchmarkable collect($balanced.branches))
    trial("balanced counts + show", @benchmarkable begin
        (length($balanced.buses), length($balanced.branches), $balanced.base_mva, sprint(show, $balanced))
    end)
    trial("balanced to_dense", @benchmarkable to_dense($balanced))
    trial("balanced calc_admittance_matrix", @benchmarkable calc_admittance_matrix($balanced))
    trial("balanced calc_bus_susceptance_matrix", @benchmarkable calc_bus_susceptance_matrix($balanced))
    trial("balanced emit matpower", @benchmarkable emit(parse($BALANCED_CASE), "matpower"))

    trial("multiconductor parse(ieee13)", @benchmarkable parse($DIST_CASE))
    trial("multiconductor collect(net.lines)", @benchmarkable collect($dist.lines))
    trial("multiconductor collect(net.linecodes)", @benchmarkable collect($dist.linecodes))
    trial("multiconductor counts + show", @benchmarkable begin
        (length($dist.buses), length($dist.lines), $dist.base_frequency, sprint(show, $dist))
    end)

    if HAS_PMD
        trial("PowerModelsDistribution parse baseline", @benchmarkable with_logger(NullLogger()) do
            PowerModelsDistribution.parse_file($DIST_CASE)
        end)
    else
        println(rpad("PowerModelsDistribution parse baseline", 44),
                " skipped: PowerModelsDistribution not loaded")
    end
end

main()
