using BenchmarkTools
using JSON3
using Logging
using PowerIO

const ROOT = normpath(joinpath(@__DIR__, ".."))
const POWERIO_ROOT = normpath(joinpath(ROOT, "..", "powerio"))
const BALANCED_CASE = joinpath(POWERIO_ROOT, "tests", "data", "case2869pegase.m")
const DIST_CASE = joinpath(POWERIO_ROOT, "tests", "data", "dist", "opendss", "ieee13", "IEEE13Nodeckt.dss")

const HAS_SERDE = try
    @eval using Serde
    true
catch
    false
end

const HAS_PMD = try
    @eval using PowerModelsDistribution
    true
catch
    false
end

const MaybeFloat = Union{Nothing,Float64}

if HAS_SERDE
    struct BenchBus
        id::Int
        kind::String
        vm::Float64
        va::Float64
        base_kv::Float64
        vmax::Float64
        vmin::Float64
        area::Int
        zone::Int
    end

    struct BenchBranch
        from::Int
        to::Int
        r::Float64
        x::Float64
        b::Float64
        rate_a::Float64
        rate_b::Float64
        rate_c::Float64
        tap::Float64
        shift::Float64
        in_service::Bool
        angmin::Float64
        angmax::Float64
    end

    struct BenchGen
        bus::Int
        pg::Float64
        qg::Float64
        pmax::Float64
        pmin::Float64
        qmax::MaybeFloat
        qmin::MaybeFloat
        vg::Float64
        mbase::Float64
        in_service::Bool
    end

    struct BenchLoad
        bus::Int
        p::Float64
        q::Float64
        in_service::Bool
    end

    struct BenchShunt
        bus::Int
        g::Float64
        b::Float64
        in_service::Bool
    end

    struct BenchNetwork
        name::String
        base_mva::Float64
        base_frequency::Float64
        buses::Vector{BenchBus}
        loads::Vector{BenchLoad}
        shunts::Vector{BenchShunt}
        branches::Vector{BenchBranch}
        switches::Vector{Any}
        generators::Vector{BenchGen}
        storage::Vector{Any}
        hvdc::Vector{Any}
        source_format::String
    end
end

function trial(label, bench)
    result = run(bench)
    best = minimum(result)
    println(rpad(label, 44), lpad(round(best.time / 1e6; digits=3), 10), " ms  ",
            lpad(best.allocs, 10), " allocs  ",
            lpad(round(best.memory / 1024 / 1024; digits=3), 10), " MiB")
end

_name(net) = :name in propertynames(net) ? net.name : PowerIO.network_name(net)
_source_format(net) = :source_format in propertynames(net) ? net.source_format : PowerIO.source_format(net)
_base_mva(net) = :base_mva in propertynames(net) ? net.base_mva : PowerIO.base_mva(net)
_base_frequency(net) = :base_frequency in propertynames(net) ? net.base_frequency : PowerIO.base_frequency(net)

function main()
    println("PowerIO library: ", PowerIO._lib())
    println("PowerIO library version: ", PowerIO.library_version())
    println("balanced case: ", BALANCED_CASE)
    println("distribution case: ", DIST_CASE)
    println()
    println(rpad("benchmark", 44), lpad("time", 10), "      ",
            lpad("allocs", 10), "      ", lpad("memory", 10))

    balanced = PowerIO.parse_file(BALANCED_CASE)
    balanced_json = PowerIO.to_json(balanced)
    dist = PowerIO.parse_file(PowerIO.MulticonductorNetwork, DIST_CASE)

    trial("balanced parse_file(case2869pegase)", @benchmarkable PowerIO.parse_file($BALANCED_CASE))
    trial("balanced parse_file + net.data", @benchmarkable begin
        net = PowerIO.parse_file($BALANCED_CASE)
        net.data
    end)
    trial("balanced metadata + show", @benchmarkable begin
        net = PowerIO.parse_file($BALANCED_CASE)
        (_name(net), _source_format(net), _base_mva(net), PowerIO.n_buses(net), sprint(show, net))
    end)
    trial("balanced calc_admittance_matrix(path)", @benchmarkable PowerIO.calc_admittance_matrix($BALANCED_CASE))
    trial("balanced to_arrow(:bus)", @benchmarkable PowerIO.to_arrow($balanced, :bus))
    trial("balanced to_arrow(:branch)", @benchmarkable PowerIO.to_arrow($balanced, :branch))
    trial("JSON3.read balanced payload", @benchmarkable JSON3.read($balanced_json))
    if HAS_SERDE
        trial("Serde typed balanced payload", @benchmarkable Serde.deser_json(BenchNetwork, $balanced_json))
    else
        println(rpad("Serde typed balanced payload", 44), " skipped: Serde not loaded")
    end

    trial("multiconductor parse_file(ieee13)", @benchmarkable PowerIO.parse_file(PowerIO.MulticonductorNetwork, $DIST_CASE))
    trial("multiconductor parse_file + net.data", @benchmarkable begin
        net = PowerIO.parse_file(PowerIO.MulticonductorNetwork, $DIST_CASE)
        net.data
    end)
    trial("multiconductor metadata + show", @benchmarkable begin
        net = PowerIO.parse_file(PowerIO.MulticonductorNetwork, $DIST_CASE)
        (_name(net), _source_format(net), _base_frequency(net), PowerIO.n_buses(net), sprint(show, net))
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
