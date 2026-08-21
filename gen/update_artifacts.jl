#!/usr/bin/env julia

module PowerIOArtifactUpdater

using Downloads
using SHA
using TOML
import JSON3
import Libdl
import Pkg.GitTools

include(joinpath(@__DIR__, "release_state.jl"))
using .PowerIOReleaseState: write_status_atomic

export CandidateReport, ParkedGate, PLATFORMS, REQUIRED_FEATURES,
       REPRESENTATIVE_SYMBOLS, install_ready!, main, run_update,
       validate_candidate

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

const REQUIRED_FEATURES = ("arrow", "matrix", "gridfm", "dist", "pkg", "prob")
const CORE_SYMBOLS = Set((
    :pio_version,
    :pio_abi_version,
    :pio_has_feature,
    :pio_schema_versions_json,
    :pio_build_info,
    :pio_string_free,
))
const REPRESENTATIVE_SYMBOLS = Dict(
    "arrow" => (:pio_to_arrow, :pio_arrow_catalog_json),
    "matrix" => (:pio_matrix_available,),
    "gridfm" => (:pio_read_dir, :pio_scenario_ids),
    "dist" => (:pio_dist_parse_str, :pio_dist_to_json),
    "pkg" => (:pio_package_parse_str, :pio_package_to_json),
    "prob" => (
        :pio_scopf_parse_str,
        :pio_scopf_to_json,
        :pio_scopf_to_json_with_index_base,
        :pio_scopf_instance_free,
    ),
)
const KNOWN_SYMBOLS = union(
    CORE_SYMBOLS,
    Set((:pio_dist_abi_version,)),
    Set(Iterators.flatten(values(REPRESENTATIVE_SYMBOLS))),
)

struct ParkedGate <: Exception
    reason::String
    detail::String
end

Base.showerror(io::IO, err::ParkedGate) =
    print(io, "artifact update parked (", err.reason, "): ", err.detail)

_park(reason::AbstractString, detail::AbstractString) =
    throw(ParkedGate(String(reason), String(detail)))

struct CandidateReport
    version::String
    abi::UInt32
    dist_abi::Union{Nothing,UInt32}
    features::Dict{String,Bool}
    symbols::Set{Symbol}
    matrix_available::Bool
    schema
    build
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
_binding_dist_abi() = _binding_const("PIO_DIST_ABI_VERSION", ("dist.jl", "PowerIO.jl"))

function _lookup(obj, key::Symbol, default=nothing)
    obj === nothing && return default
    try
        return get(obj, key, default)
    catch
        try
            return get(obj, String(key), default)
        catch
            return default
        end
    end
end

function _object_like(obj)
    obj === nothing && return false
    try
        keys(obj)
        return true
    catch
        return false
    end
end

function _nonempty_collection(value)
    value === nothing && return false
    try
        return !isempty(value)
    catch
        return false
    end
end

function validate_candidate(report::CandidateReport, tag::AbstractString;
                            binding_abi::UInt32=_binding_abi(),
                            binding_dist_abi::UInt32=_binding_dist_abi())
    missing_core = sort!(collect(setdiff(CORE_SYMBOLS, report.symbols)); by=string)
    isempty(missing_core) || _park(
        "required_symbol_missing", "missing core symbol $(first(missing_core))")
    report.abi == binding_abi || _park(
        "core_abi_mismatch", "binary ABI $(report.abi), binding ABI $binding_abi")

    version = startswith(tag, "v") ? tag[nextind(tag, firstindex(tag)):end] : String(tag)
    report.version == version || _park(
        "schema_version_mismatch",
        "pio_version reports $(report.version), requested $version")

    for feature in REQUIRED_FEATURES
        get(report.features, feature, false) || _park(
            "required_feature_missing", "binary does not report feature $feature")
    end
    :pio_dist_abi_version in report.symbols || _park(
        "dist_abi_missing", "binary does not expose pio_dist_abi_version")
    report.dist_abi === nothing && _park(
        "dist_abi_missing", "binary did not report a distribution ABI")
    report.dist_abi == binding_dist_abi || _park(
        "dist_abi_mismatch",
        "binary distribution ABI $(report.dist_abi), binding ABI $binding_dist_abi")

    for feature in REQUIRED_FEATURES, symbol in REPRESENTATIVE_SYMBOLS[feature]
        symbol in report.symbols || _park(
            "required_symbol_missing", "feature $feature is missing symbol $symbol")
    end
    report.matrix_available || _park(
        "required_feature_missing", "pio_matrix_available reports false")

    _object_like(report.schema) || _park(
        "schema_report_invalid", "pio_schema_versions_json is not an object")
    _object_like(report.build) || _park(
        "schema_report_invalid", "pio_build_info is not an object")
    schema_version = _lookup(report.schema, :powerio_version)
    build_version = _lookup(report.build, :powerio_version)
    schema_version isa AbstractString || _park(
        "schema_report_invalid", "schema report has no powerio_version string")
    build_version isa AbstractString || _park(
        "schema_report_invalid", "build report has no powerio_version string")
    String(schema_version) == version || _park(
        "schema_version_mismatch", "schema report is $schema_version, requested $version")
    String(build_version) == version || _park(
        "schema_version_mismatch", "build report is $build_version, requested $version")
    _lookup(report.schema, :abi) == Int(binding_abi) || _park(
        "core_abi_mismatch", "schema report ABI does not match binding ABI $binding_abi")
    _lookup(report.build, :abi) == Int(binding_abi) || _park(
        "core_abi_mismatch", "build report ABI does not match binding ABI $binding_abi")

    build_features = _lookup(report.build, :features)
    _object_like(build_features) || _park(
        "schema_report_invalid", "build report has no features object")
    for feature in REQUIRED_FEATURES
        _lookup(build_features, Symbol(feature), false) === true || _park(
            "required_feature_missing", "build report does not enable feature $feature")
    end
    bmopf = _lookup(report.schema, :bmopf_schema)
    bmopf isa AbstractString && !isempty(bmopf) || _park(
        "schema_report_invalid", "schema report has no BMOPF schema version")
    foreign = _lookup(report.build, :foreign_schemas)
    _object_like(foreign) || _park(
        "schema_report_invalid", "build report has no foreign_schemas object")
    _lookup(foreign, :bmopf) == bmopf || _park(
        "schema_report_invalid", "schema and build reports disagree on BMOPF")
    for key in (:error_categories, :diagnostic_namespaces, :json_classes)
        _nonempty_collection(_lookup(report.build, key)) || _park(
            "schema_report_invalid", "build report has no nonempty $key list")
    end
    return report
end

function _host_triplet()
    arch = Sys.ARCH in (:x86_64, :aarch64) ? String(Sys.ARCH) : return ""
    Sys.islinux() && return "$arch-linux-gnu"
    Sys.isapple() && return "$arch-apple-darwin"
    Sys.iswindows() && arch == "x86_64" && return "x86_64-w64-mingw32"
    return ""
end

function _owned_json(handle, symbol::Symbol)
    ptr = ccall(Libdl.dlsym(handle, symbol), Cstring, ())
    ptr == C_NULL && return nothing
    text = unsafe_string(ptr)
    ccall(Libdl.dlsym(handle, :pio_string_free), Cvoid, (Cstring,), ptr)
    return _parse_report_json(text, symbol)
end

function _parse_report_json(text::AbstractString, symbol::Symbol)
    # Malformed report bytes are a runtime parse failure, not a semantic schema
    # disagreement. They stay hard failures and never create a parked status.
    try
        return JSON3.read(text)
    catch err
        error("$symbol returned invalid JSON: $(sprint(showerror, err))")
    end
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
        version_ptr = ccall(Libdl.dlsym(handle, :pio_version), Cstring, ())
        version_ptr == C_NULL && _park(
            "schema_report_invalid", "pio_version returned null")
        version = unsafe_string(version_ptr)
        abi = ccall(Libdl.dlsym(handle, :pio_abi_version), UInt32, ())
        features = Dict(feature =>
            ccall(Libdl.dlsym(handle, :pio_has_feature), Cint,
                  (Cstring,), feature) == 1 for feature in REQUIRED_FEATURES)
        dist_abi = :pio_dist_abi_version in symbols ?
            ccall(Libdl.dlsym(handle, :pio_dist_abi_version), UInt32, ()) : nothing
        matrix_available = :pio_matrix_available in symbols &&
            ccall(Libdl.dlsym(handle, :pio_matrix_available), Cint, ()) == 1
        schema = _owned_json(handle, :pio_schema_versions_json)
        build = _owned_json(handle, :pio_build_info)
        report = CandidateReport(
            version, abi, dist_abi, features, symbols, matrix_available, schema, build)
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
