#!/usr/bin/env julia

module PowerIOPairedRelease

using JSON3
using SHA
using TOML
using Pkg
include("update_artifacts.jl")
const Updater = PowerIOArtifactUpdater
const ROOT = normpath(joinpath(@__DIR__, ".."))

function validate_assets(release)
    release.prerelease && error("paired release cannot be a prerelease")
    names = Set(String(asset.name) for asset in release.assets)
    binaries = Set("libpowerio_capi.$triplet.tar.gz" for (triplet, _) in Updater.PLATFORMS)
    names in (binaries, union(binaries, Set(["release-manifest.json"]))) ||
        error("release must contain exactly five binaries and an optional paired manifest")
    length(names) == length(release.assets) || error("duplicate release asset name")
    return Dict(String(asset.name) => String(asset.digest) for asset in release.assets
                if String(asset.name) in binaries)
end

function prepare(tag)
    occursin(r"^v[0-9]+\.[0-9]+\.[0-9]+$", tag) || error("tag must be vX.Y.Z")
    TOML.parsefile(joinpath(ROOT, "Project.toml"))["version"] == tag[2:end] ||
        error("Julia version differs from the paired release")
    release_url = readchomp(`gh release view $tag --repo eigenergy/powerio --json apiUrl --jq .apiUrl`)
    release = JSON3.read(read(`gh api $release_url`, String))
    String(release.tag_name) == tag || error("release tag differs from the candidate")
    release.draft || error("candidate preparation requires a draft release")
    digests = validate_assets(release)
    mktempdir() do tmp
        function fetcher(requested_tag, name, destination)
            requested_tag == tag || error("updater requested another release")
            Updater.fetch_asset(tag, name, destination)
            "sha256:" * bytes2hex(open(sha256, destination)) == digests[name] ||
                error("download hash differs from draft asset: $name")
            cp(destination, joinpath(tmp, name); force=true)
            return destination
        end
        status = joinpath(tmp, "status.toml")
        result = Updater.run_update(tag, status; fetcher)
        result.status == "ready" || error("candidate binary checks did not pass")
        host = Updater._host_triplet()
        unpack = joinpath(tmp, "host")
        mkpath(unpack)
        archive = joinpath(tmp, "libpowerio_capi.$host.tar.gz")
        run(`tar -xzf $archive -C $unpack`)
        library = Sys.iswindows() ? joinpath(unpack, "bin", "libpowerio_capi.dll") :
                  joinpath(unpack, "lib", Sys.isapple() ? "libpowerio_capi.dylib" : "libpowerio_capi.so")
        withenv("POWERIO_CAPI" => library) do
            Pkg.test()
        end
    end
    return nothing
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 2 && ARGS[1] == "prepare" || error("usage: paired_release.jl prepare vX.Y.Z")
    PowerIOPairedRelease.prepare(ARGS[2])
end
