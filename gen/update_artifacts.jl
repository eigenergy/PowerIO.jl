#!/usr/bin/env julia

module PowerIOArtifactUpdater

using Downloads
using SHA
using TOML
import Libdl
import Pkg.GitTools

include(joinpath(@__DIR__, "release_state.jl"))
using .PowerIOReleaseState: write_status_atomic

export CandidateReport, ParkedGate, PLATFORMS, REQUIRED_FEATURES,
       install_ready!, main, run_update, validate_candidate

const ROOT = normpath(joinpath(@__DIR__, ".."))
const REPO = "eigenergy/powerio"
const ARTIFACT_PATH = joinpath(ROOT, "Artifacts.toml")

# Must stay in sync with powerio's release-binaries workflow.
const PLATFORMS = [
    ("x86_64-linux-gnu", ["arch = \"x86_64\"", "os = \"linux\"", "libc = \"glibc\""]),
    ("aarch64-linux-gnu", ["arch = \"aarch64\"", "os = \"linux\"", "libc = \"glibc\""]),
    ("x86_64-apple-darwin", ["arch = \"x86_64\"", "os = \"macos\""]),
    ("aarch64-apple-darwin", ["arch = \"aarch64\"", "os = \"macos\""]),
    ("x86_64-w64-mingw32", ["arch = \"x86_64\"", "os = \"windows\""]),
]

# The release build features of powerio-capi. ABI 7 declares one fixed symbol
# table whatever the features, so the binary is checked by behavior: a release
# library must parse the GridFM fixture, which only the `gridfm` feature enables.
const REQUIRED_FEATURES = ("arrow", "matrix", "gridfm", "dist", "prob")
# One entry point per operation family the binding depends on.
const CORE_SYMBOLS = Set((
    :pio_version,
    :pio_abi_version,
    :pio_string_release,
    :pio_source_open,
    :pio_source_from_memory,
    :pio_parse,
    :pio_module_value,
    :pio_module_diagnostics,
    :pio_module_release,
    :pio_module_serialize,
    :pio_module_deserialize,
    :pio_value_type_name,
    :pio_value_balanced_network,
    :pio_value_multiconductor_network,
    :pio_balanced_network_bus_count,
    :pio_balanced_network_bus_at,
    :pio_multiconductor_network_counts,
    :pio_multiconductor_network_bus_at,
    :pio_emit,
    :pio_emit_result_artifact,
    :pio_calc_incidence_matrix,
    :pio_calc_branch_flow_dc,
    :pio_apply_updates,
    :pio_time_series_get,
    :pio_scenario_set_get,
    :pio_calculation_solution_get_values,
))
const KNOWN_SYMBOLS = CORE_SYMBOLS
const GRIDFM_FIXTURE = joinpath(ROOT, "test", "data", "case14_gridfm", "raw")

struct ParkedGate <: Exception
    reason::String
    detail::String
end

Base.showerror(io::IO, err::ParkedGate) =
    print(io, "artifact update parked (", err.reason, "): ", err.detail)

_park(reason::AbstractString, detail::AbstractString) =
    throw(ParkedGate(String(reason), String(detail)))

# What one release library reports: its version string, ABI number, the core
# entry points it exports, and whether it parses the GridFM fixture.
struct CandidateReport
    version::String
    abi::UInt32
    symbols::Set{Symbol}
    gridfm_available::Bool
end

function _binding_const(name::AbstractString, files)
    re = Regex("\\b$(name)\\s*=\\s*UInt32\\((\\d+)\\)")
    for file in files
        path = joinpath(ROOT, "src", file)
        isfile(path) || continue
        m = match(re, read(path, String))
        m === nothing || return parse(UInt32, m.captures[1])
    end
    error("$name not found in binding sources")
end

_binding_abi() = _binding_const("PIO_ABI_VERSION", ("capi.jl", "PowerIO.jl"))

function validate_candidate(report::CandidateReport, tag::AbstractString;
                            binding_abi::UInt32=_binding_abi())
    missing_core = sort!(collect(setdiff(CORE_SYMBOLS, report.symbols)); by=string)
    isempty(missing_core) || _park(
        "required_symbol_missing", "missing core symbol $(first(missing_core))")
    report.abi == binding_abi || _park(
        "core_abi_mismatch", "binary ABI $(report.abi), binding ABI $binding_abi")

    version = startswith(tag, "v") ? tag[nextind(tag, firstindex(tag)):end] : String(tag)
    report.version == version || _park(
        "schema_version_mismatch",
        "pio_version reports $(report.version), requested $version")

    report.gridfm_available || _park(
        "required_feature_missing",
        "the library does not parse the GridFM fixture; the gridfm feature is absent")
    return report
end

function _host_triplet()
    arch = Sys.ARCH in (:x86_64, :aarch64) ? String(Sys.ARCH) : return ""
    Sys.islinux() && return "$arch-linux-gnu"
    Sys.isapple() && return "$arch-apple-darwin"
    Sys.iswindows() && arch == "x86_64" && return "x86_64-w64-mingw32"
    return ""
end

# A borrowed (pointer, length) string, the return type of `pio_version`.
struct _StringView
    data::Ptr{UInt8}
    len::Csize_t
end

_string(v::_StringView) = (v.data == C_NULL || v.len == 0) ? "" : unsafe_string(v.data, Int(v.len))

# Parse the GridFM fixture through the library under inspection; true when a
# module comes back. Any error handle is released.
function _parses_gridfm(handle)
    path = GRIDFM_FIXTURE
    err = Ref{Ptr{Cvoid}}(C_NULL)
    source = ccall(Libdl.dlsym(handle, :pio_source_open), Ptr{Cvoid},
                   (Ptr{UInt8}, Csize_t, Ref{Ptr{Cvoid}}), path, sizeof(path), err)
    if source == C_NULL
        err[] == C_NULL || ccall(Libdl.dlsym(handle, :pio_error_release), Cvoid, (Ptr{Cvoid},), err[])
        return false
    end
    format = "gridfm"
    module_ptr = ccall(Libdl.dlsym(handle, :pio_parse), Ptr{Cvoid},
                       (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ref{Ptr{Cvoid}}), source, format, sizeof(format), err)
    ccall(Libdl.dlsym(handle, :pio_source_release), Cvoid, (Ptr{Cvoid},), source)
    if module_ptr == C_NULL
        err[] == C_NULL || ccall(Libdl.dlsym(handle, :pio_error_release), Cvoid, (Ptr{Cvoid},), err[])
        return false
    end
    ccall(Libdl.dlsym(handle, :pio_module_release), Cvoid, (Ptr{Cvoid},), module_ptr)
    return true
end

function _inspect_library(unpack::AbstractString, triplet::AbstractString,
                          tag::AbstractString)
    libsubdir = endswith(triplet, "mingw32") ? "bin" : "lib"
    lib = joinpath(unpack, libsubdir, "libpowerio_capi.$(Libdl.dlext)")
    isfile(lib) || error("release archive has no $lib")
    handle = Libdl.dlopen(lib)
    try
        symbols = Set(sym for sym in KNOWN_SYMBOLS
                      if Libdl.dlsym(handle, sym; throw_error=false) !== nothing)
        missing_core = setdiff(CORE_SYMBOLS, symbols)
        isempty(missing_core) || _park(
            "required_symbol_missing", "missing core symbol $(first(missing_core))")
        version = _string(ccall(Libdl.dlsym(handle, :pio_version), _StringView, ()))
        abi = ccall(Libdl.dlsym(handle, :pio_abi_version), UInt32, ())
        report = CandidateReport(version, abi, symbols, _parses_gridfm(handle))
        return validate_candidate(report, tag)
    finally
        Libdl.dlclose(handle)
    end
end

function fetch_asset(tag::AbstractString, name::AbstractString, dest::AbstractString)
    if Sys.which("gh") !== nothing
        run(`gh release download $tag --repo $REPO --pattern $name --output $dest --clobber`)
    else
        Downloads.download("https://github.com/$REPO/releases/download/$tag/$name", dest)
    end
    return dest
end

function _render_artifacts(tag::AbstractString; fetcher=fetch_asset,
                           inspector=_inspect_library)
    stanzas = String[]
    host = _host_triplet()
    isempty(host) && error("artifact generation cannot validate binaries on this host")
    host in first.(PLATFORMS) || error("release matrix does not contain host $host")
    mktempdir() do tmp
        for (triplet, keys) in PLATFORMS
            name = "libpowerio_capi.$triplet.tar.gz"
            tarball = joinpath(tmp, name)
            @info "fetching release asset" name
            fetcher(tag, name, tarball)
            isfile(tarball) || error("asset fetch did not create $name")
            sha = bytes2hex(open(sha256, tarball))
            unpack = joinpath(tmp, triplet)
            mkpath(unpack)
            run(`tar -xzf $tarball -C $unpack`)
            triplet == host && inspector(unpack, triplet, tag)
            tree = bytes2hex(GitTools.tree_hash(unpack))
            url = "https://github.com/$REPO/releases/download/$tag/$name"
            push!(stanzas, """
                [[powerio_capi]]
                $(join(keys, '\n'))
                git-tree-sha1 = "$tree"
                lazy = true

                    [[powerio_capi.download]]
                    sha256 = "$sha"
                    url = "$url"
                """)
        end
    end
    header = """
    # Generated by gen/update_artifacts.jl from the $tag release of $REPO.
    # Regenerate after each reviewed release intent becomes available:
    #   julia --project=. gen/update_artifacts.jl $tag --status-file update-status.toml
    #
    # `lazy = true`: nothing downloads at `Pkg.add`; the current platform's
    # tarball is fetched on the first call that needs the binary.
    """
    return header * "\n" * join(stanzas, "\n")
end

function _atomic_write(path::AbstractString, content::AbstractString)
    dir = dirname(abspath(path))
    isdir(dir) || mkpath(dir)
    tmp, io = mktemp(dir)
    try
        write(io, content)
        flush(io)
        close(io)
        mv(tmp, path; force=true)
    catch
        isopen(io) && close(io)
        ispath(tmp) && rm(tmp; force=true)
        rethrow()
    end
    return path
end

function install_ready!(artifact_path::AbstractString, status_path::AbstractString,
                        content::AbstractString, tag::AbstractString)
    abspath(artifact_path) == abspath(status_path) &&
        error("status file must not be Artifacts.toml")
    existed = isfile(artifact_path)
    original = existed ? read(artifact_path, String) : ""
    changed = !existed || original != content
    try
        changed && _atomic_write(artifact_path, content)
        write_status_atomic(status_path, Dict(
            "status" => "ready",
            "tag" => String(tag),
            "changed" => changed,
        ))
    catch
        if changed
            existed ? _atomic_write(artifact_path, original) : rm(artifact_path; force=true)
        end
        rethrow()
    end
    return changed
end

function run_update(tag::AbstractString, status_path::AbstractString;
                    artifact_path::AbstractString=ARTIFACT_PATH,
                    fetcher=fetch_asset, inspector=_inspect_library)
    occursin(r"^v[0-9]+\.[0-9]+\.[0-9]+$", tag) ||
        error("powerio tag must be vX.Y.Z")
    try
        content = _render_artifacts(tag; fetcher, inspector)
        changed = install_ready!(artifact_path, status_path, content, tag)
        @info "artifact update ready" tag changed
        return (; status="ready", tag=String(tag), changed)
    catch err
        if err isa ParkedGate
            write_status_atomic(status_path, Dict(
                "status" => "parked",
                "tag" => String(tag),
                "changed" => false,
                "reason" => err.reason,
                "detail" => err.detail,
            ))
            @warn "artifact update parked" tag reason=err.reason detail=err.detail
            return (; status="parked", tag=String(tag), changed=false,
                    reason=err.reason, detail=err.detail)
        end
        rethrow()
    end
end

function main(args=ARGS)
    length(args) == 3 && args[2] == "--status-file" || error(
        "usage: julia --project=. gen/update_artifacts.jl vX.Y.Z --status-file PATH")
    run_update(args[1], args[3])
    return nothing
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    PowerIOArtifactUpdater.main()
end
