using JSON3
using TOML

include(joinpath(@__DIR__, "..", "gen", "release_state.jl"))
include(joinpath(@__DIR__, "..", "gen", "update_artifacts.jl"))

const ReleaseState = PowerIOReleaseState
const ArtifactUpdater = PowerIOArtifactUpdater

function _git_at(dir, args...)
    run(Cmd(`git $(args)`; dir))
end

function _write_release_repo(dir; changelog=
                             "# Changelog\n\n## 0.9.0\n\n" *
                             "Breaking migration; see changelog.\n\n- Candidate.\n")
    mkpath(joinpath(dir, ".github"))
    write(joinpath(dir, "Project.toml"), "name = \"PowerIO\"\nversion = \"0.9.0\"\n")
    write(joinpath(dir, "CHANGELOG.md"), changelog)
    write(joinpath(dir, "Artifacts.toml"), "old artifact\n")
    write(joinpath(dir, "source.jl"), "const X = 1\n")
    write(joinpath(dir, ".github", "powerio-release.toml"), """
          schema = 1
          state = "draft"
          julia_version = "0.9.0"
          powerio_tag = "v0.9.0"
          source_digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
          """)
    _git_at(dir, "init", "-q")
    _git_at(dir, "config", "user.name", "PowerIO tests")
    _git_at(dir, "config", "user.email", "tests@example.invalid")
    _git_at(dir, "add", ".")
    _git_at(dir, "commit", "-qm", "initial")
end

function _write_intent(path; schema=1, state="draft", version="0.9.0",
                       tag="v0.9.0", digest="sha256:" * repeat("0", 64))
    open(path, "w") do io
        TOML.print(io, Dict(
            "schema" => schema,
            "state" => state,
            "julia_version" => version,
            "powerio_tag" => tag,
            "source_digest" => digest,
        ); sorted=true)
    end
    return path
end

function _release_json(path; tag="v0.9.0", draft=false, prerelease=false,
                       assets=collect(ReleaseState.REQUIRED_ASSETS))
    write(path, JSON3.write((;
        tag_name=tag,
        draft,
        prerelease,
        assets=[(; name) for name in assets],
    )))
    return path
end

function _versions(path, versions)
    open(path, "w") do io
        for version in versions
            println(io, "[\"$version\"]")
            println(io, "git-tree-sha1 = \"0000000000000000000000000000000000000000\"")
        end
    end
    return path
end

function _parked_reason(report)
    try
        ArtifactUpdater.validate_candidate(
            report, "v0.9.0"; binding_abi=UInt32(5), binding_dist_abi=UInt32(1))
        return nothing
    catch err
        err isa ArtifactUpdater.ParkedGate || rethrow()
        return err.reason
    end
end

function _candidate(; version="0.9.0", abi=UInt32(5), dist_abi=UInt32(1),
                    features=Dict(name => true for name in ArtifactUpdater.REQUIRED_FEATURES),
                    symbols=copy(ArtifactUpdater.KNOWN_SYMBOLS), matrix_available=true,
                    schema=Dict(:powerio_version => "0.9.0", :abi => 5,
                                :bmopf_schema => "draft"),
                    build=Dict(
                        :powerio_version => "0.9.0",
                        :abi => 5,
                        :features => Dict(Symbol(name) => true for name in
                                          ArtifactUpdater.REQUIRED_FEATURES),
                        :foreign_schemas => Dict(:bmopf => "draft"),
                        :error_categories => ["parse"],
                        :diagnostic_namespaces => ["READ"],
                        :json_classes => ["model-json"],
                    ))
    ArtifactUpdater.CandidateReport(
        version, abi, dist_abi, features, symbols, matrix_available, schema, build)
end

@testset "invalid release intent" begin
    mktempdir() do dir
        path = joinpath(dir, "intent.toml")
        @test_throws ErrorException ReleaseState.read_intent(
            _write_intent(path; schema=2))
        @test_throws ErrorException ReleaseState.read_intent(
            _write_intent(path; state="armed"))
        @test_throws ErrorException ReleaseState.read_intent(
            _write_intent(path; tag="v0.9.1"))
        @test_throws ErrorException ReleaseState.read_intent(
            _write_intent(path; digest="sha256:not-a-digest"))
        write(path, "schema = 1\n")
        @test_throws ErrorException ReleaseState.read_intent(path)
    end
end

@testset "release intent and state machine" begin
    live = ReleaseState.read_intent()
    @test live.state in ("draft", "ready")
    expected = live.state == "draft" ? "waiting_intent" : "ready"
    @test ReleaseState.evaluate_initial_state("schedule"; intent=live).status == expected
    @test ReleaseState.evaluate_initial_state(
        "repository_dispatch", "v9.9.9"; intent=live).status == "ignored_tag"

    mktempdir() do dir
        _write_release_repo(dir)
        intent_path = joinpath(dir, ".github", "powerio-release.toml")
        digest1 = ReleaseState.canonical_source_digest(dir)

        # These are the only two excluded paths.
        write(joinpath(dir, "Artifacts.toml"), "new artifact\n")
        write(intent_path, replace(read(intent_path, String), "draft" => "ready"))
        _git_at(dir, "add", ".")
        _git_at(dir, "commit", "-qm", "excluded files")
        @test ReleaseState.canonical_source_digest(dir) == digest1

        write(joinpath(dir, "source.jl"), "const X = 2\n")
        _git_at(dir, "add", "source.jl")
        _git_at(dir, "commit", "-qm", "source change")
        @test ReleaseState.canonical_source_digest(dir) != digest1

        # prepare-intent is the sole final edit and can therefore hash HEAD.
        write(intent_path, replace(read(intent_path, String), "state = \"ready\"" =>
                                   "state = \"draft\""))
        _git_at(dir, "add", ".github/powerio-release.toml")
        _git_at(dir, "commit", "-qm", "draft")
        prepared = ReleaseState.prepare_intent!(intent_path; root=dir)
        intent = ReleaseState.read_intent(intent_path)
        @test intent.state == "ready"
        @test intent.source_digest == prepared
        @test ReleaseState.validate_ready_intent(intent, dir) === intent
        @test ReleaseState.evaluate_initial_state(
            "workflow_dispatch", ""; intent, root=dir).status == "ready"

        general = _versions(joinpath(dir, "Versions.toml"), ["0.8.4"])
        @test ReleaseState.general_state(intent, general; root=dir).status == "unregistered"
        release = _release_json(joinpath(dir, "release.json"))
        @test ReleaseState.evaluate_release_state(
            nothing, 0, general; intent, root=dir).status == "waiting_for_binary"
        @test ReleaseState.evaluate_release_state(
            _release_json(joinpath(dir, "draft.json"); draft=true), 0, general;
            intent, root=dir).status == "waiting_for_binary"
        @test ReleaseState.evaluate_release_state(
            release, 1, general; intent, root=dir).status == "waiting_review"
        @test ReleaseState.evaluate_release_state(
            release, 0, general; intent, root=dir).status == "ready"
        @test_throws ErrorException ReleaseState.evaluate_release_state(
            _release_json(joinpath(dir, "pre.json"); prerelease=true), 0, general;
            intent, root=dir)
        @test_throws ErrorException ReleaseState.evaluate_release_state(
            _release_json(joinpath(dir, "missing.json"); assets=String[]), 0, general;
            intent, root=dir)
        @test_throws ErrorException ReleaseState.evaluate_release_state(
            _release_json(
                joinpath(dir, "extra.json");
                assets=vcat(collect(ReleaseState.REQUIRED_ASSETS), ["checksums.txt"]),
            ), 0, general; intent, root=dir)

        registered = _versions(joinpath(dir, "Registered.toml"), ["0.8.4", "0.9.0"])
        @test ReleaseState.evaluate_release_state(
            nothing, 0, registered; intent, root=dir).status == "registered"

        _git_at(dir, "add", ".github/powerio-release.toml")
        _git_at(dir, "commit", "-qm", "ready intent")
        write(joinpath(dir, "source.jl"), "const X = 3\n")
        _git_at(dir, "add", "source.jl")
        _git_at(dir, "commit", "-qm", "stale the intent")
        @test_throws ErrorException ReleaseState.validate_ready_intent(intent, dir)
        @test_throws ErrorException ReleaseState.evaluate_release_state(
            nothing, 0, general; intent, root=dir)
        # General containing the target makes the reviewed intent terminal, so
        # normal post-release development does not break the nightly repair job.
        @test ReleaseState.evaluate_initial_state(
            "schedule"; intent, root=dir).status == "ready"
        @test ReleaseState.evaluate_release_state(
            nothing, 0, registered; intent, root=dir).status == "registered"
    end


    for changelog in (
        "# Changelog\n\n## 0.9.0\n\n",
        "# Changelog\n\n## 0.9.0\n\nBreaking migration with prose only.\n",
    )
        mktempdir() do dir
            _write_release_repo(dir; changelog)
            path = joinpath(dir, ".github", "powerio-release.toml")
            ReleaseState.prepare_intent!(path; root=dir)
            @test_throws ErrorException ReleaseState.validate_ready_intent(
                ReleaseState.read_intent(path), dir)
        end
    end

    mktempdir() do dir
        for prose in ("API migration.", "See the changelog for the migration.")
            changelog = "# Changelog\n\n## 0.9.0\n\n$prose\n\n- Candidate.\n"
            _write_release_repo(dir; changelog)
            path = joinpath(dir, ".github", "powerio-release.toml")
            ReleaseState.prepare_intent!(path; root=dir)
            intent = ReleaseState.read_intent(path)
            general = _versions(joinpath(dir, "Versions.toml"), ["0.8.4"])
            @test_throws ErrorException ReleaseState.general_state(intent, general; root=dir)
            @test_throws ErrorException ReleaseState.general_state(
                intent, joinpath(dir, "registry-outage.toml"); root=dir)
            write(joinpath(dir, "empty-registry.toml"), "")
            @test_throws ErrorException ReleaseState.general_state(
                intent, joinpath(dir, "empty-registry.toml"); root=dir)
        end
    end

    @test ReleaseState.is_next_release(v"0.8.4", v"0.8.5")
    @test ReleaseState.is_next_release(v"0.8.4", v"0.9.0")
    @test ReleaseState.is_next_release(v"0.8.4", v"1.0.0")
    @test !ReleaseState.is_next_release(v"0.8.4", v"0.9.1")
    @test ReleaseState.is_breaking_transition(v"0.8.4", v"0.9.0")
    @test !ReleaseState.is_breaking_transition(v"0.8.4", v"0.8.5")
    @test ReleaseState.require_registry_response(200)
    @test_throws ErrorException ReleaseState.require_registry_response(404)
    @test_throws ErrorException ReleaseState.require_registry_response(503)
    @test ReleaseState.tagbot_action("registered", 200) == "none"
    @test ReleaseState.tagbot_action("registered", 404) == "dispatch"
    @test ReleaseState.tagbot_action("unregistered", 404) == "none"
    @test_throws ErrorException ReleaseState.tagbot_action("registered", 503)

    mktempdir() do dir
        comments = joinpath(dir, "comments.json")
        cutoff = "2026-08-20T10:00:00Z"
        write(comments, JSON3.write([[
            (; user=(; login="github-actions[bot]"),
               body="@JuliaRegistrator register\n\nRelease notes:",
               created_at="2026-08-20T11:00:00Z"),
        ]]))
        @test ReleaseState.registration_comment_action(comments, cutoff) == "wait"
        write(comments, JSON3.write([[
            (; user=(; login="github-actions[bot]"),
               body="@JuliaRegistrator register",
               created_at="2026-08-20T09:00:00Z"),
            (; user=(; login="reviewer"),
               body="@JuliaRegistrator register",
               created_at="2026-08-20T11:00:00Z"),
        ]]))
        @test ReleaseState.registration_comment_action(comments, cutoff) == "post"
        @test_throws ErrorException ReleaseState.registration_comment_action(
            comments, "not-a-timestamp")
    end

    sha = repeat("a", 40)
    @test ReleaseState.validate_sha_state(sha, sha, sha)
    @test ReleaseState.validate_sha_state(sha, repeat("b", 40), sha;
                                          require_head=false)
    @test_throws ErrorException ReleaseState.validate_sha_state(
        sha, repeat("b", 40), sha)
    @test_throws ErrorException ReleaseState.validate_sha_state(
        sha, sha, repeat("b", 40); require_head=false)
    @test_throws ErrorException ReleaseState.validate_sha_state("short", sha, sha)
end

@testset "artifact candidate gates" begin
    @test ArtifactUpdater.validate_candidate(
        _candidate(), "v0.9.0"; binding_abi=UInt32(5), binding_dist_abi=UInt32(1)) isa
          ArtifactUpdater.CandidateReport
    @test _parked_reason(_candidate(abi=UInt32(4))) == "core_abi_mismatch"
    @test _parked_reason(_candidate(version="0.8.3")) == "schema_version_mismatch"

    no_version = setdiff(copy(ArtifactUpdater.KNOWN_SYMBOLS), Set((:pio_version,)))
    @test _parked_reason(_candidate(symbols=no_version)) == "required_symbol_missing"

    no_feature = Dict(name => name != "prob" for name in ArtifactUpdater.REQUIRED_FEATURES)
    @test _parked_reason(_candidate(features=no_feature)) == "required_feature_missing"
    no_dist_abi = setdiff(copy(ArtifactUpdater.KNOWN_SYMBOLS), Set((:pio_dist_abi_version,)))
    @test _parked_reason(_candidate(symbols=no_dist_abi, dist_abi=nothing)) ==
          "dist_abi_missing"
    @test _parked_reason(_candidate(dist_abi=UInt32(2))) == "dist_abi_mismatch"
    no_prob = setdiff(
        copy(ArtifactUpdater.KNOWN_SYMBOLS),
        Set((:pio_dc_data_build,)),
    )
    @test _parked_reason(_candidate(symbols=no_prob)) == "required_symbol_missing"
    @test _parked_reason(_candidate(schema=nothing)) == "schema_report_invalid"
    @test _parked_reason(_candidate(schema=Dict(
        :powerio_version => "0.8.3", :abi => 5, :bmopf_schema => "draft"))) ==
          "schema_version_mismatch"
    @test_throws ErrorException ArtifactUpdater._parse_report_json(
        "{not-json", :pio_schema_versions_json)

    mktempdir() do dir
        artifact = joinpath(dir, "Artifacts.toml")
        status = joinpath(dir, "status.toml")
        write(artifact, "old")
        @test ArtifactUpdater.install_ready!(artifact, status, "new", "v0.9.0")
        @test read(artifact, String) == "new"
        @test TOML.parsefile(status) ==
              Dict("status" => "ready", "tag" => "v0.9.0", "changed" => true)
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

@testset "release workflow authority" begin
    root = dirname(@__DIR__)
    update = read(joinpath(root, ".github", "workflows", "update-artifacts.yml"), String)
    register = read(joinpath(root, ".github", "workflows", "register.yml"), String)
    tagbot = read(joinpath(root, ".github", "workflows", "TagBot.yml"), String)
    @test !occursin("release=true", update)
    @test !occursin("pull --rebase", update)
    @test !occursin("git add Project.toml", update)
    @test !occursin("git add CHANGELOG.md", update)
    @test occursin("git add Artifacts.toml", update)
    @test occursin("--status-file", update)
    @test occursin("expected_sha", update)
    @test occursin("expected_sha", register)
    @test !occursin("git commit", register)
    @test !occursin("git push", register)
    @test occursin(r"actions/checkout@[0-9a-f]{40}", update)
    @test occursin(r"julia-actions/setup-julia@[0-9a-f]{40}", register)
    @test occursin(r"JuliaRegistries/TagBot@[0-9a-f]{40}", tagbot)
    @test occursin("tagbot-action registered", update)
    @test occursin("check-main-sha", update)
    @test count("check-exact-sha", register) == 2
    @test occursin("registration-comment-action", register)
    @test occursin("--paginate --slurp", register)
    @test occursin("group: update-artifacts", update)
    @test occursin("group: register-package", register)
    @test count("cancel-in-progress: false", update * register) == 2
end
