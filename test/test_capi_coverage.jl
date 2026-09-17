# Every entry point the generated raw layer declares is either called by the
# hand-written sources or listed in gen/unbound_entry_points.txt with a reason.
# A powerio release that adds an entry point therefore fails this test until
# someone binds it or records why it stays unbound.

const LIB_MODULE = PowerIO.LibPowerIO
const REPO_ROOT = dirname(@__DIR__)

# The entry points the C header declares, as the generator emitted them.
const GENERATED = Set(n for n in names(LIB_MODULE; all=true) if startswith(String(n), "pio_"))

# The entry points the hand-written sources name. `@capi` keeps the quoted name
# in the source, which is also what powerio's ABI coverage script greps for.
function _referenced()
    found = Set{Symbol}()
    for file in readdir(joinpath(REPO_ROOT, "src"); join=true)
        (endswith(file, ".jl") && basename(file) != "LibPowerIO.jl") || continue
        for m in eachmatch(r":(pio_[a-z0-9_]+)", read(file, String))
            push!(found, Symbol(m.captures[1]))
        end
    end
    return found
end
const REFERENCED = _referenced()

# name => reason, from the exemption file. Comment and blank lines are skipped.
function _exempt()
    out = Dict{Symbol,String}()
    for line in eachline(joinpath(REPO_ROOT, "gen", "unbound_entry_points.txt"))
        (isempty(strip(line)) || startswith(line, "#")) && continue
        parts = split(line, '\t')
        length(parts) == 2 || error("gen/unbound_entry_points.txt: expected name<TAB>reason, got $line")
        out[Symbol(parts[1])] = String(parts[2])
    end
    return out
end
const EXEMPT = _exempt()

@testset "C ABI entry point coverage" begin
    @test length(GENERATED) > 400
    @test length(REFERENCED) > 200

    # Bind these, or record in gen/unbound_entry_points.txt why they stay unbound.
    unbound = sort!(collect(setdiff(GENERATED, REFERENCED, keys(EXEMPT))); by=String)
    isempty(unbound) || @error "entry points that are neither called nor exempt" unbound
    @test unbound == Symbol[]

    # An exemption for a name ABI 7 no longer declares, left behind by a rename.
    unknown = sort!(collect(setdiff(keys(EXEMPT), GENERATED)); by=String)
    isempty(unknown) || @error "exemptions for entry points the header does not declare" unknown
    @test unknown == Symbol[]

    # An exemption for a name the sources now call.
    stale = sort!(collect(intersect(keys(EXEMPT), REFERENCED)); by=String)
    isempty(stale) || @error "exemptions for entry points the sources call" stale
    @test stale == Symbol[]

    # Every name the sources call resolves in the library under test. A typo in
    # a quoted name is otherwise only found when that code path runs.
    if LIBRARY_AVAILABLE
        handle = Libdl.dlopen(PowerIO._lib())
        try
            unresolved = sort!([n for n in REFERENCED
                                if Libdl.dlsym(handle, n; throw_error=false) === nothing]; by=String)
            isempty(unresolved) || @error "entry points the library does not export" unresolved
            @test unresolved == Symbol[]
        finally
            Libdl.dlclose(handle)
        end
    elseif get(ENV, "POWERIO_CAPI", "") != ""
        @test false  # POWERIO_CAPI names a library that did not load or is not ABI compatible
    else
        @warn "PowerIO: no library resolved; entry point resolution is not checked (set POWERIO_CAPI)"
        @test_skip isempty(REFERENCED)
    end

    # The view structs cross the C boundary by value, so each must be a plain
    # bits type with no Julia-managed field.
    views = [getfield(LIB_MODULE, n) for n in names(LIB_MODULE; all=true)
             if startswith(String(n), "Pio") && endswith(String(n), "View") &&
                getfield(LIB_MODULE, n) isa DataType]
    @test length(views) > 100
    @test all(isbitstype, views)
end
