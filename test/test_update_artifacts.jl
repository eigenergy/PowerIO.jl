using TOML

include(joinpath(@__DIR__, "..", "gen", "update_artifacts.jl"))

const ArtifactUpdater = PowerIOArtifactUpdater

function _parked_reason(report; tag="v0.11.0", binding_release=v"0.11.0")
    try
        ArtifactUpdater.validate_candidate(report, tag; binding_release)
        return nothing
    catch err
        err isa ArtifactUpdater.ParkedGate || rethrow()
        return err.reason
    end
end

function _candidate(; version="0.11.0", release=VersionNumber(version),
                    symbols=copy(ArtifactUpdater.KNOWN_SYMBOLS), gridfm_available=true)
    ArtifactUpdater.CandidateReport(version, release, symbols, gridfm_available)
end

_without(symbol::Symbol) = setdiff(copy(ArtifactUpdater.KNOWN_SYMBOLS), Set((symbol,)))

@testset "artifact candidate gates" begin
    @test ArtifactUpdater.validate_candidate(
        _candidate(), "v0.11.0"; binding_release=v"0.11.0") isa
          ArtifactUpdater.CandidateReport
    # A binding works with a library from its header's release series at the
    # header's release or a newer one.
    release_reason(binary, header) = _parked_reason(
        _candidate(version=string(binary)); tag="v$binary", binding_release=header)
    @test release_reason(v"0.12.0", v"0.12.0") === nothing
    @test release_reason(v"0.11.3", v"0.11.0") === nothing
    @test release_reason(v"0.11.3", v"0.11.3") === nothing
    @test release_reason(v"0.11.3", v"0.11.4") == "release_too_old"
    @test release_reason(v"0.12.0", v"0.11.4") == "release_series_mismatch"
    @test release_reason(v"0.10.9", v"0.11.0") == "release_series_mismatch"
    @test release_reason(v"1.4.0", v"1.2.0") === nothing
    @test release_reason(v"1.1.9", v"1.2.0") == "release_too_old"
    @test release_reason(v"2.0.0", v"1.2.0") == "release_series_mismatch"
    @test _parked_reason(_candidate(version="0.10.0", release=v"0.11.0")) ==
          "schema_version_mismatch"
    # pio_version_numbers reports the numeric release; pio_version must match
    # the complete requested tag, including the RC number.
    rc = _candidate(version="1.0.0-rc.1", release=v"1.0.0")
    @test _parked_reason(rc; tag="v1.0.0-rc.1", binding_release=v"1.0.0") === nothing
    @test _parked_reason(rc; tag="v1.0.0-rc.2", binding_release=v"1.0.0") ==
          "schema_version_mismatch"
    @test _parked_reason(rc; tag="v1.0.0", binding_release=v"1.0.0") ==
          "schema_version_mismatch"
    @test _parked_reason(_candidate(version="1.0.0"); tag="v1.0.0-rc.1",
                        binding_release=v"1.0.0") == "schema_version_mismatch"
    @test _parked_reason(_candidate(gridfm_available=false)) == "required_feature_missing"
    for symbol in (:pio_version, :pio_parse, :pio_module_value, :pio_emit, :pio_module_serialize,
                   :pio_module_deserialize, :pio_calc_incidence_matrix, :pio_apply_updates,
                   :pio_balanced_network_bus_at, :pio_multiconductor_network_counts)
        @test _parked_reason(_candidate(symbols=_without(symbol))) == "required_symbol_missing"
    end
    # Removing an inert Cargo flag does not change the C ABI or invalidate existing
    # release archives. Candidate checks use the binary's version and behavior,
    # not a build-feature label that older archives may still carry.
    for version in ("0.11.5", "0.11.6")
        @test ArtifactUpdater.validate_candidate(
            _candidate(; version), "v$version"; binding_release=v"0.11.5") isa
              ArtifactUpdater.CandidateReport
        @test_throws ArtifactUpdater.ParkedGate ArtifactUpdater.validate_candidate(
            _candidate(; version=version == "0.11.5" ? "0.11.6" : "0.11.5"), "v$version";
            binding_release=v"0.11.5")
        @test_throws ArtifactUpdater.ParkedGate ArtifactUpdater.validate_candidate(
            _candidate(; version, gridfm_available=false), "v$version";
            binding_release=v"0.11.5")
    end
    @test isfile(joinpath(ArtifactUpdater.GRIDFM_FIXTURE, "gridfm_meta.json"))
    # The binding's header release is what the gate compares a release binary against.
    @test ArtifactUpdater._binding_release() == PowerIO._HEADER_RELEASE
    if LIBRARY_AVAILABLE
        handle = Libdl.dlopen(PowerIO._lib())
        try
            @test ArtifactUpdater._parses_gridfm(handle) isa Bool
            @test all(Libdl.dlsym(handle, sym; throw_error=false) !== nothing
                      for sym in ArtifactUpdater.CORE_SYMBOLS)
        finally
            Libdl.dlclose(handle)
        end
    end

    mktempdir() do dir
        artifact = joinpath(dir, "Artifacts.toml")
        status = joinpath(dir, "status.toml")
        write(artifact, "old")
        @test ArtifactUpdater.install_ready!(artifact, status, "new", "v0.10.0")
        @test read(artifact, String) == "new"
        @test TOML.parsefile(status) ==
              Dict("status" => "ready", "tag" => "v0.10.0", "changed" => true)
        @test !ArtifactUpdater.install_ready!(artifact, status, "new", "v0.9.0")

        blocker = joinpath(dir, "not-a-directory")
        write(blocker, "block")
        @test_throws Exception ArtifactUpdater.install_ready!(
            artifact, joinpath(blocker, "status.toml"), "third", "v0.9.0")
        @test read(artifact, String) == "new" # rolled back after status failure

        template = joinpath(dir, "asset.tar.gz")
        mktempdir() do payload
            write(joinpath(payload, "marker"), "fixture")
            run(`tar -czf $template -C $payload marker`)
        end
        function fake_fetch(_tag, _name, dest)
            cp(template, dest; force=true)
            return dest
        end

        pinned = "url = \"https://github.com/eigenergy/powerio/releases/download/" *
                 "v0.9.0/libpowerio_capi.aarch64-apple-darwin.tar.gz\"\n"
        write(artifact, pinned)
        before = read(artifact)
        parked = ArtifactUpdater.run_update(
            "v0.9.0", status; artifact_path=artifact, fetcher=fake_fetch,
            inspector=(_args...) -> throw(
                ArtifactUpdater.ParkedGate("release_series_mismatch", "fixture")),
        )
        @test parked.status == "parked"
        @test read(artifact) == before
        @test TOML.parsefile(status)["reason"] == "release_series_mismatch"

        hard_status = joinpath(dir, "hard-status.toml")
        write(hard_status, "sentinel = true\n")
        @test_throws ErrorException ArtifactUpdater.run_update(
            "v0.9.0", hard_status; artifact_path=artifact, fetcher=fake_fetch,
            inspector=(_args...) -> error("fixture hard failure"),
        )
        @test read(artifact) == before
        @test read(hard_status, String) == "sentinel = true\n"

        download_status = joinpath(dir, "download-status.toml")
        @test_throws ErrorException ArtifactUpdater.run_update(
            "v0.9.0", download_status; artifact_path=artifact,
            fetcher=(_args...) -> error("fixture download failure"),
            inspector=(_args...) -> nothing,
        )
        @test read(artifact) == before
        @test !ispath(download_status)

        write(artifact, "old")
        ready = ArtifactUpdater.run_update(
            "v0.9.0", status; artifact_path=artifact, fetcher=fake_fetch,
            inspector=(_args...) -> nothing,
        )
        @test ready.status == "ready"
        @test ready.changed
        rendered = read(artifact, String)
        @test length(TOML.parse(rendered)["powerio_capi"]) == 5
        @test length(collect(eachmatch(r"\[\[powerio_capi\]\]", rendered))) == 5
        @test length(collect(eachmatch(r"\[\[powerio_capi\.download\]\]", rendered))) == 5
        @test count(==("v0.9.0"), [m.captures[1] for m in
            eachmatch(r"/releases/download/(v[0-9.]+)/", rendered)]) == 5
        unchanged = ArtifactUpdater.run_update(
            "v0.9.0", status; artifact_path=artifact, fetcher=fake_fetch,
            inspector=(_args...) -> nothing,
        )
        @test unchanged.status == "ready"
        @test !unchanged.changed
        @test read(artifact, String) == rendered

        @testset "prerelease artifact pins" begin
            # A synthetic archive exercises all five manifest entries without
            # depending on published assets or accepting an unverified version.
            for tag in ("v1.0.0-rc.1", "v1.0.0-rc.2")
                inspected = String[]
                function inspect_rc(_unpack, _triplet, requested)
                    push!(inspected, requested)
                    report = _candidate(version=tag[2:end], release=v"1.0.0")
                    ArtifactUpdater.validate_candidate(report, requested;
                                                       binding_release=v"1.0.0")
                end
                ready = ArtifactUpdater.run_update(
                    tag, status; artifact_path=artifact, fetcher=fake_fetch,
                    inspector=inspect_rc,
                )
                @test ready.status == "ready"
                @test inspected == [tag]
                entries = TOML.parsefile(artifact)["powerio_capi"]
                @test length(entries) == 5
                @test all(occursin("/releases/download/$tag/", only(entry["download"])["url"])
                          for entry in entries)
                @test TOML.parsefile(status)["tag"] == tag
                unchanged = ArtifactUpdater.run_update(
                    tag, status; artifact_path=artifact, fetcher=fake_fetch,
                    inspector=inspect_rc,
                )
                @test !unchanged.changed
            end

            old_artifact, old_status = read(artifact), read(status)
            for tag in ("1.0.0-rc.1", "v1.0.0-rc1", "v1.0.0-rc.0",
                        "v1.0.0-rc.01", "v1.0.0-rc.-1", "v1.0.0-rc.1.2",
                        "v0.12.0-beta.1", "v0.12.0+build", "v1.0.0-rc.1+build",
                        "v00.12.0", "v0.012.0", "v0.12.00", "v1.0.0-rc.1\n")
                fetched = Ref(false)
                @test_throws r"powerio tag must be" ArtifactUpdater.run_update(
                    tag, status; artifact_path=artifact,
                    fetcher=(_args...) -> (fetched[] = true),
                    inspector=(_args...) -> nothing,
                )
                @test !fetched[]
                @test read(artifact) == old_artifact
                @test read(status) == old_status
            end

            # A valid RC tag with the wrong binary is parked, preserving pins.
            parked = ArtifactUpdater.run_update(
                "v1.0.0-rc.2", status; artifact_path=artifact, fetcher=fake_fetch,
                inspector=(_unpack, _triplet, requested) ->
                    ArtifactUpdater.validate_candidate(rc, requested; binding_release=v"1.0.0"),
            )
            @test parked.status == "parked"
            @test parked.reason == "schema_version_mismatch"
            @test read(artifact) == old_artifact
        end
    end
end
