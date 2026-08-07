#!/usr/bin/env julia
# Fill Artifacts.toml from a powerio release's binary tarballs.
#
#   julia gen/update_artifacts.jl v0.0.1
#
# The release-binaries workflow in eigenergy/powerio builds
# libpowerio_capi.<triplet>.tar.gz for the five supported platforms and attaches
# them to the GitHub release for the given tag. This script downloads each one,
# computes the tarball sha256 and the unpacked tree's git-tree-sha1, and rewrites
# Artifacts.toml. Commit the result (the Update artifacts workflow runs this
# and opens the PR).
#
# The assets must be downloadable: either eigenergy/powerio is public, or `gh`
# is installed and authenticated (used automatically when available).

using Downloads
using SHA
import Libdl
import Pkg.GitTools

const REPO = "eigenergy/powerio"

# (Julia platform triplet, Artifacts.toml platform keys); must stay in sync with
# the matrix in powerio's .github/workflows/release-binaries.yml.
const PLATFORMS = [
    ("x86_64-linux-gnu", ["arch = \"x86_64\"", "os = \"linux\"", "libc = \"glibc\""]),
    ("aarch64-linux-gnu", ["arch = \"aarch64\"", "os = \"linux\"", "libc = \"glibc\""]),
    ("x86_64-apple-darwin", ["arch = \"x86_64\"", "os = \"macos\""]),
    ("aarch64-apple-darwin", ["arch = \"aarch64\"", "os = \"macos\""]),
    ("x86_64-w64-mingw32", ["arch = \"x86_64\"", "os = \"windows\""]),
]

function fetch(tag::String, name::String, dest::String)
    if Sys.which("gh") !== nothing
        run(`gh release download $tag --repo $REPO --pattern $name --output $dest --clobber`)
    else
        Downloads.download("https://github.com/$REPO/releases/download/$tag/$name", dest)
    end
end

isempty(ARGS) && error("usage: julia gen/update_artifacts.jl <powerio tag, e.g. v0.0.1>")
tag = ARGS[1]

# The Julia platform triplet of the machine running this script, in the naming
# of PLATFORMS; "" on a platform the release does not cover.
function _host_triplet()
    arch = Sys.ARCH in (:x86_64, :aarch64) ? String(Sys.ARCH) : return ""
    Sys.islinux() && return "$arch-linux-gnu"
    Sys.isapple() && return "$arch-apple-darwin"
    Sys.iswindows() && arch == "x86_64" && return "x86_64-w64-mingw32"
    return ""
end

# Parse an ABI constant from the source files that may own it after the module
# split. Keep this textual so the release updater can run before package
# instantiation.
function _binding_uint32_const(name::AbstractString, files)
    re = Regex("\\b$(name)\\s*=\\s*UInt32\\((\\d+)\\)")
    for file in files
        path = joinpath(@__DIR__, "..", "src", file)
        isfile(path) || continue
        m = match(re, read(path, String))
        m === nothing || return parse(UInt32, m.captures[1])
    end
    return nothing
end

# Same, for a string constant (`NAME = "1.2.3"`).
function _binding_string_const(name::AbstractString, files)
    re = Regex("\\b$(name)\\s*=\\s*\"([^\"]+)\"")
    for file in files
        path = joinpath(@__DIR__, "..", "src", file)
        isfile(path) || continue
        m = match(re, read(path, String))
        m === nothing || return String(m.captures[1])
    end
    return nothing
end

# The ABI version this binding targets, parsed from the source of truth.
function _binding_abi()
    value = _binding_uint32_const("PIO_ABI_VERSION", ("capi.jl", "PowerIO.jl"))
    value === nothing && error("PIO_ABI_VERSION not found in src/capi.jl or src/PowerIO.jl")
    return value
end

# The distribution ABI version this binding targets, parsed from the source of
# truth. Missing means this binding predates the separate dist ABI.
function _binding_dist_abi()
    return _binding_uint32_const("PIO_DIST_ABI_VERSION", ("dist.jl", "PowerIO.jl"))
end

function _skip_release(msg::String)
    @warn msg
    summary = get(ENV, "GITHUB_STEP_SUMMARY", "")
    isempty(summary) || open(io -> println(io, msg), summary, "a")
    exit(0)
end

# Refuse to pin binaries this binding cannot speak to: dlopen the unpacked
# host-platform library and compare its pio_abi_version with PIO_ABI_VERSION,
# when present in the binding pio_dist_abi_version with PIO_DIST_ABI_VERSION,
# and the additive matrix/package features through pio_has_feature.
# Exit 0 without touching Artifacts.toml on a mismatch, so the scheduled
# tracking run is a clean no-op until the lockstep binding PR merges. A summary
# line lands in $GITHUB_STEP_SUMMARY when running under Actions.
function _check_abi(unpack::String, triplet::String)
    libsubdir = endswith(triplet, "mingw32") ? "bin" : "lib"
    lib = joinpath(unpack, libsubdir, "libpowerio_capi.$(Libdl.dlext)")
    isfile(lib) || error("no $lib in the $triplet tarball")
    handle = Libdl.dlopen(lib)
    try
        got = ccall(Libdl.dlsym(handle, :pio_abi_version), UInt32, ())
        want = _binding_abi()
        got == want || _skip_release(
            "skipping $tag: its binaries report ABI $got, this binding targets ABI $want; " *
            "Artifacts.toml left untouched (repin after the lockstep binding PR merges)"
        )

        dist_want = _binding_dist_abi()
        if dist_want !== nothing
            dist_got = try
                ccall(Libdl.dlsym(handle, :pio_dist_abi_version), UInt32, ())
            catch e
                _skip_release(
                    "skipping $tag: its binaries do not expose pio_dist_abi_version, " *
                    "this binding targets dist ABI $dist_want; Artifacts.toml left untouched. " *
                    "Underlying: $e"
                )
            end
            dist_got == dist_want || _skip_release(
                "skipping $tag: its binaries report dist ABI $dist_got, this binding targets " *
                "dist ABI $dist_want; Artifacts.toml left untouched"
            )
        end

        has_feature = try
            Libdl.dlsym(handle, :pio_has_feature)
        catch e
            _skip_release(
                "skipping $tag: its binaries do not expose pio_has_feature for the feature " *
                "surface checks; Artifacts.toml left untouched. Underlying: $e"
            )
        end

        matrix_feature = ccall(has_feature, Cint, (Cstring,), "matrix")
        matrix_feature == 1 || _skip_release(
            "skipping $tag: its binaries do not report the matrix feature; " *
            "Artifacts.toml left untouched"
        )
        matrix_available = try
            ccall(Libdl.dlsym(handle, :pio_matrix_available), Cint, ())
        catch e
            _skip_release(
                "skipping $tag: its binaries do not expose pio_matrix_available; " *
                "Artifacts.toml left untouched. Underlying: $e"
            )
        end
        matrix_available == 1 || _skip_release(
            "skipping $tag: its binaries do not enable matrix Arrow tables; " *
            "Artifacts.toml left untouched"
        )

        pkg_feature = try
            ccall(has_feature, Cint, (Cstring,), "pkg")
        catch e
            _skip_release(
                "skipping $tag: its binaries could not report the package feature; " *
                "Artifacts.toml left untouched. Underlying: $e"
            )
        end
        pkg_feature == 1 || _skip_release(
            "skipping $tag: its binaries do not report the pkg feature; " *
            "Artifacts.toml left untouched"
        )
        Libdl.dlsym(handle, :pio_package_parse_str; throw_error=false) !== nothing || _skip_release(
            "skipping $tag: its binaries report pkg but do not expose pio_package_parse_str; " *
            "Artifacts.toml left untouched"
        )

        # Wire formats are versioned separately from the ABI on purpose: the C
        # policy is that new data arrives through versioned payloads rather
        # than signature changes, so both ABI integers above can match a
        # library whose document formats this binding can no longer read. That
        # is not hypothetical — powerio v0.8.0 moved `.pio.json` from 0.1.1 to
        # 0.2.0 with ABI 4 and dist ABI 1 unchanged, every check above passed,
        # the repin landed, and the mismatch only surfaced as a test failure
        # after the release was already public.
        #
        # So compare the versions the library reports against the constants
        # this binding mirrors. Only checked when the library exposes
        # `pio_wire_versions_json`; an older library skips this and is governed
        # by the ABI gate alone, as before.
        wire_sym = Libdl.dlsym(handle, :pio_wire_versions_json; throw_error=false)
        if wire_sym !== nothing
            ptr = ccall(wire_sym, Cstring, ())
            if ptr != C_NULL
                text = unsafe_string(ptr)
                free = Libdl.dlsym(handle, :pio_string_free; throw_error=false)
                free === nothing || ccall(free, Cvoid, (Cstring,), ptr)
                # Textual, like the constant readers above: this script runs
                # before instantiation, so it cannot depend on JSON3.
                for (key, const_name, files) in (
                    ("package", "PIO_PACKAGE_SCHEMA_VERSION", ("package.jl", "PowerIO.jl")),
                )
                    want = _binding_string_const(const_name, files)
                    want === nothing && continue
                    m = match(Regex("\"$(key)\"\\s*:\\s*\"([^\"]+)\""), text)
                    m === nothing && continue
                    got = String(m.captures[1])
                    # While the major is 0 the minor is the breaking axis, so
                    # compare the lineage rather than the whole string: a patch
                    # bump is additive and must not park the release.
                    lineage(v) = (x = VersionNumber(v); (x.major, x.minor))
                    lineage(got) == lineage(want) || _skip_release(
                        "skipping $tag: its binaries speak $key schema $got, this binding " *
                        "targets $want ($const_name in src/); Artifacts.toml left untouched " *
                        "(repin after the lockstep binding PR merges)"
                    )
                end
            end
        end
    finally
        Libdl.dlclose(handle)
    end
end

stanzas = String[]
mktempdir() do tmp
    host = _host_triplet()
    for (triplet, keys) in PLATFORMS
        name = "libpowerio_capi.$triplet.tar.gz"
        tarball = joinpath(tmp, name)
        @info "fetching" name
        fetch(tag, name, tarball)
        sha = bytes2hex(open(sha256, tarball))
        unpack = joinpath(tmp, triplet)
        mkpath(unpack)
        run(`tar -xzf $tarball -C $unpack`)
        triplet == host && _check_abi(unpack, triplet)
        tree = bytes2hex(GitTools.tree_hash(unpack))
        url = "https://github.com/$REPO/releases/download/$tag/$name"
        push!(
            stanzas,
            """
            [[powerio_capi]]
            $(join(keys, '\n'))
            git-tree-sha1 = "$tree"
            lazy = true

                [[powerio_capi.download]]
                sha256 = "$sha"
                url = "$url"
            """,
        )
    end
end

header = """
# Generated by gen/update_artifacts.jl from the $tag release of $REPO.
# Regenerate (do not hand-edit) after each powerio binary release:
#   julia gen/update_artifacts.jl <tag>
#
# `lazy = true`: nothing downloads at `Pkg.add`; the tarball for the current
# platform is fetched on the first use that needs the binary. On an unsupported
# platform the lookup fails and `_artifact_lib()` falls back to a sibling
# checkout, then a plain `libpowerio_capi` on the loader path.
#
# Windows note: the .dll ships under bin/, not lib/; `_artifact_lib()` already
# resolves the bin/ subdir on Windows.
"""

path = joinpath(@__DIR__, "..", "Artifacts.toml")
write(path, header * "\n" * join(stanzas, "\n"))
@info "wrote" path
