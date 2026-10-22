using TOML

include(joinpath(@__DIR__, "..", "gen", "update_artifacts.jl"))

const ArtifactUpdater = PowerIOArtifactUpdater

function _parked_reason(report)
    try
        ArtifactUpdater.validate_candidate(
            report, "v0.11.0"; binding_abi=UInt32(7))
        return nothing
    catch err
        err isa ArtifactUpdater.ParkedGate || rethrow()
        return err.reason
    end
end

function _candidate(; version="0.11.0", abi=UInt32(7),
                    symbols=copy(ArtifactUpdater.KNOWN_SYMBOLS), gridfm_available=true)
    ArtifactUpdater.CandidateReport(version, abi, symbols, gridfm_available)
end

_without(symbol::Symbol) = setdiff(copy(ArtifactUpdater.KNOWN_SYMBOLS), Set((symbol,)))

@testset "artifact candidate gates" begin
    @test ArtifactUpdater.validate_candidate(
        _candidate(), "v0.11.0"; binding_abi=UInt32(7)) isa
          ArtifactUpdater.CandidateReport
    @test _parked_reason(_candidate(abi=UInt32(6))) == "core_abi_mismatch"
    @test _parked_reason(_candidate(version="0.10.0")) == "schema_version_mismatch"
    @test _parked_reason(_candidate(gridfm_available=false)) == "required_feature_missing"
    for symbol in (:pio_version, :pio_parse, :pio_module_value, :pio_emit, :pio_module_serialize,
                   :pio_module_deserialize, :pio_calc_incidence_matrix, :pio_apply_updates,
                   :pio_balanced_network_bus_at, :pio_multiconductor_network_counts)
        @test _parked_reason(_candidate(symbols=_without(symbol))) == "required_symbol_missing"
    end
    # Removing an inert Cargo flag does not change the ABI or invalidate existing
    # release archives. Candidate checks use the binary's version and behavior,
    # not a build-feature label that older archives may still carry.
    for version in ("0.11.5", "0.11.6")
        @test ArtifactUpdater.validate_candidate(
            _candidate(; version), "v$version"; binding_abi=UInt32(7)) isa
              ArtifactUpdater.CandidateReport
        @test_throws ArtifactUpdater.ParkedGate ArtifactUpdater.validate_candidate(
            _candidate(; version=version == "0.11.5" ? "0.11.6" : "0.11.5"), "v$version";
            binding_abi=UInt32(7))
        @test_throws ArtifactUpdater.ParkedGate ArtifactUpdater.validate_candidate(
            _candidate(; version, gridfm_available=false), "v$version";
            binding_abi=UInt32(7))
    end
    @test isfile(joinpath(ArtifactUpdater.GRIDFM_FIXTURE, "gridfm_meta.json"))
    # The binding's ABI constant is what the gate compares a release binary against.
    @test ArtifactUpdater._binding_abi() == PowerIO.PIO_ABI_VERSION == UInt32(7)
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
                ArtifactUpdater.ParkedGate("core_abi_mismatch", "fixture")),
        )
        @test parked.status == "parked"
        @test read(artifact) == before
        @test TOML.parsefile(status)["reason"] == "core_abi_mismatch"

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
    end
end
