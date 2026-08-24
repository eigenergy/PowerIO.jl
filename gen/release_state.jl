#!/usr/bin/env julia

module PowerIOReleaseState

using SHA
using TOML
import JSON3

export ReleaseIntent, ReleaseDecision, INTENT_PATH, REQUIRED_ASSETS,
       artifact_tag, canonical_source_digest, changelog_section,
       evaluate_initial_state, evaluate_release_state, general_state,
       is_breaking_transition, is_next_release, prepare_intent!,
       project_version, read_intent, validate_ready_intent,
       registration_comment_action, require_registry_response, tagbot_action,
       validate_sha_state, write_status_atomic

const ROOT = normpath(joinpath(@__DIR__, ".."))
const INTENT_PATH = joinpath(ROOT, ".github", "powerio-release.toml")
const DIGEST_EXCLUDES = Set(("Artifacts.toml", ".github/powerio-release.toml"))
const REQUIRED_ASSETS = Set([
    "libpowerio_capi.x86_64-linux-gnu.tar.gz",
    "libpowerio_capi.aarch64-linux-gnu.tar.gz",
    "libpowerio_capi.x86_64-apple-darwin.tar.gz",
    "libpowerio_capi.aarch64-apple-darwin.tar.gz",
    "libpowerio_capi.x86_64-w64-mingw32.tar.gz",
])

struct ReleaseIntent
    schema::Int
    state::String
    julia_version::VersionNumber
    powerio_tag::String
    source_digest::String
end

struct ReleaseDecision
    status::String
    version::VersionNumber
    tag::String
    detail::String
end

function read_intent(path::AbstractString=INTENT_PATH)
    raw = TOML.parsefile(path)
    required = ("schema", "state", "julia_version", "powerio_tag", "source_digest")
    missing = filter(k -> !haskey(raw, k), required)
    isempty(missing) || error("release intent is missing: $(join(missing, ", "))")
    schema = raw["schema"]
    schema isa Integer || error("release intent schema must be an integer")
    state = raw["state"]
    state in ("draft", "ready") || error("release intent state must be draft or ready")
    version = tryparse(VersionNumber, string(raw["julia_version"]))
    version === nothing && error("release intent julia_version is not semantic version X.Y.Z")
    version.prerelease == () && version.build == () ||
        error("release intent julia_version must not be a prerelease or build")
    tag = string(raw["powerio_tag"])
    occursin(r"^v[0-9]+\.[0-9]+\.[0-9]+$", tag) ||
        error("release intent powerio_tag must be vX.Y.Z")
    tag == "v$version" ||
        error("release intent powerio_tag $tag does not match Julia version $version")
    digest = string(raw["source_digest"])
    occursin(r"^sha256:[0-9a-f]{64}$", digest) ||
        error("release intent source_digest must be sha256 followed by 64 lowercase hex digits")
    schema == 1 || error("unsupported release intent schema $schema")
    return ReleaseIntent(Int(schema), String(state), version, tag, digest)
end

function _git(root::AbstractString, args...)
    readchomp(Cmd(`git $(args)`; dir=root))
end

"""
    canonical_source_digest(root=ROOT; rev="HEAD") -> String

Hash the tracked Git objects that define a PowerIO.jl release. Records are
sorted by path and encoded as `path\0mode\0type\0object id\0`. `Artifacts.toml`
and the release intent are the only exclusions: the former is the one file the
release bot can change, and the latter contains this digest.
"""
function canonical_source_digest(root::AbstractString=ROOT; rev::AbstractString="HEAD")
    raw = read(Cmd(`git ls-tree -r -z --full-tree $rev`; dir=root), String)
    records = NamedTuple{(:path, :mode, :type, :oid),NTuple{4,String}}[]
    for entry in split(raw, '\0'; keepempty=false)
        tab = findfirst(==('\t'), entry)
        tab === nothing && error("malformed git ls-tree record")
        header = split(entry[firstindex(entry):prevind(entry, tab)]; limit=3)
        length(header) == 3 || error("malformed git ls-tree header")
        path = entry[nextind(entry, tab):end]
        path in DIGEST_EXCLUDES && continue
        push!(records, (; path, mode=header[1], type=header[2], oid=header[3]))
    end
    sort!(records; by=r -> r.path)
    canonical = IOBuffer()
    for record in records
        for field in (record.path, record.mode, record.type, record.oid)
            write(canonical, field)
            write(canonical, UInt8(0))
        end
    end
    return "sha256:" * bytes2hex(sha256(take!(canonical)))
end

project_version(root::AbstractString=ROOT) =
    VersionNumber(TOML.parsefile(joinpath(root, "Project.toml"))["version"])

function changelog_section(root::AbstractString=ROOT)
    text = read(joinpath(root, "CHANGELOG.md"), String)
    m = match(r"(?ms)^##\s+([0-9]+\.[0-9]+\.[0-9]+)\s*\n(.*?)(?=^##\s+|\z)", text)
    m === nothing && error("CHANGELOG.md has no semantic version section")
    return (; version=VersionNumber(m.captures[1]), body=strip(m.captures[2]))
end

function _validate_release_metadata(intent::ReleaseIntent, root::AbstractString)
    project_version(root) == intent.julia_version || error(
        "Project.toml version $(project_version(root)) does not match intent $(intent.julia_version)")
    section = changelog_section(root)
    section.version == intent.julia_version || error(
        "top CHANGELOG.md section $(section.version) does not match intent $(intent.julia_version)")
    isempty(section.body) && error("top CHANGELOG.md section is empty")
    occursin(r"(?m)^-\s+\S", section.body) ||
        error("top CHANGELOG.md section must contain a bullet")
    return section
end

function validate_ready_intent(intent::ReleaseIntent=read_intent(),
                               root::AbstractString=ROOT; rev::AbstractString="HEAD")
    intent.state == "ready" || error("release intent is $(intent.state), not ready")
    _validate_release_metadata(intent, root)
    actual = canonical_source_digest(root; rev)
    actual == intent.source_digest || error(
        "release intent digest is stale: expected $(intent.source_digest), got $actual")
    return intent
end

function evaluate_initial_state(event_name::AbstractString,
                                dispatch_tag::AbstractString="";
                                intent::ReleaseIntent=read_intent(),
                                root::AbstractString=ROOT,
                                rev::AbstractString="HEAD")
    if event_name == "repository_dispatch" && dispatch_tag != intent.powerio_tag
        return ReleaseDecision("ignored_tag", intent.julia_version, intent.powerio_tag,
                               "dispatch named $(isempty(dispatch_tag) ? "no tag" : dispatch_tag)")
    end
    if intent.state != "ready"
        return ReleaseDecision("waiting_intent", intent.julia_version, intent.powerio_tag,
                               "release intent is $(intent.state)")
    end
    return ReleaseDecision("ready", intent.julia_version, intent.powerio_tag,
                           "release intent is ready for registry evaluation")
end

function is_next_release(previous::VersionNumber, target::VersionNumber)
    target == VersionNumber(previous.major, previous.minor, previous.patch + 1) && return true
    target == VersionNumber(previous.major, previous.minor + 1, 0) && return true
    target == VersionNumber(previous.major + 1, 0, 0) && return true
    return false
end

is_breaking_transition(previous::VersionNumber, target::VersionNumber) =
    target.major > previous.major ||
    (previous.major == 0 && target.major == 0 && target.minor > previous.minor)

function general_state(intent::ReleaseIntent, versions_path::AbstractString;
                       root::AbstractString=ROOT)
    raw = TOML.parsefile(versions_path)
    versions = VersionNumber[]
    for key in keys(raw)
        parsed = tryparse(VersionNumber, key)
        parsed === nothing || push!(versions, parsed)
    end
    isempty(versions) && error("General Versions.toml contains no semantic versions")
    target = intent.julia_version
    target in versions && return (; status="registered", latest=maximum(versions))
    latest = maximum(versions)
    is_next_release(latest, target) || error(
        "intent version $target is not the next patch, minor, or major release after General $latest")
    if is_breaking_transition(latest, target)
        body = changelog_section(root).body
        occursin(r"(?i)\bbreaking\b", body) || error(
            "$latest -> $target is breaking, but the top changelog section has no breaking marker")
    end
    return (; status="unregistered", latest)
end

function _json_bool(obj, key::Symbol)
    haskey(obj, key) || error("release response is missing $key")
    value = getproperty(obj, key)
    value isa Bool || error("release response $key is not boolean")
    return value
end

function evaluate_release_state(release_json::Union{Nothing,AbstractString},
                                open_artifact_prs::Integer,
                                versions_path::AbstractString;
                                intent::ReleaseIntent=read_intent(),
                                root::AbstractString=ROOT)
    registry = general_state(intent, versions_path; root)
    if registry.status == "registered"
        return ReleaseDecision(
            "registered", intent.julia_version, intent.powerio_tag,
            "PowerIO $(intent.julia_version) is already in General")
    end
    # Registration makes an intent terminal. Once General contains the target,
    # later development must not be held hostage by the old source digest; the
    # branch above also keeps TagBot repair available. Before registration,
    # every source and release mutation still requires the reviewed exact tree.
    validate_ready_intent(intent, root)
    release_json === nothing && return ReleaseDecision(
        "waiting_for_binary", intent.julia_version, intent.powerio_tag,
        "the intended powerio release does not exist")
    release = try
        JSON3.read(read(release_json, String))
    catch err
        error("invalid GitHub release response: $(sprint(showerror, err))")
    end
    String(get(release, :tag_name, "")) == intent.powerio_tag ||
        error("GitHub release tag does not match intent $(intent.powerio_tag)")
    _json_bool(release, :draft) && return ReleaseDecision(
        "waiting_for_binary", intent.julia_version, intent.powerio_tag,
        "the intended powerio release is still a draft")
    _json_bool(release, :prerelease) && error("the intended powerio release is a prerelease")
    haskey(release, :assets) || error("release response is missing assets")
    asset_names = [String(get(asset, :name, "")) for asset in release.assets]
    names = Set(asset_names)
    missing = sort!(collect(setdiff(REQUIRED_ASSETS, names)))
    isempty(missing) || error("powerio release is missing assets: $(join(missing, ", "))")
    extra = sort!(collect(setdiff(names, REQUIRED_ASSETS)))
    isempty(extra) || error("powerio release has unexpected assets: $(join(extra, ", "))")
    length(asset_names) == length(REQUIRED_ASSETS) ||
        error("powerio release must contain exactly $(length(REQUIRED_ASSETS)) assets")
    open_artifact_prs >= 0 || error("open artifact PR count cannot be negative")
    open_artifact_prs > 0 && return ReleaseDecision(
        "waiting_review", intent.julia_version, intent.powerio_tag,
        "$open_artifact_prs artifacts/* PR(s) are open")
    return ReleaseDecision(
        "ready", intent.julia_version, intent.powerio_tag,
        "PowerIO $(intent.julia_version) follows General $(registry.latest)")
end

function artifact_tag(path::AbstractString=joinpath(ROOT, "Artifacts.toml"))
    text = read(path, String)
    tags = Set(m.captures[1] for m in eachmatch(
        r"/releases/download/(v[0-9]+\.[0-9]+\.[0-9]+)/", text))
    length(tags) == 1 || error("Artifacts.toml must select exactly one powerio release tag")
    return only(tags)
end

function tagbot_action(registry_status::AbstractString, http_status::Integer)
    registry_status == "registered" || return "none"
    http_status == 200 && return "none"
    http_status == 404 && return "dispatch"
    error("PowerIO release API returned HTTP $http_status")
end

function registration_comment_action(comments_path::AbstractString,
                                     cutoff::AbstractString)
    occursin(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", cutoff) ||
        error("registration comment cutoff must be an RFC 3339 UTC timestamp")
    raw = try
        JSON3.read(read(comments_path, String))
    catch err
        error("invalid commit comments response: $(sprint(showerror, err))")
    end
    pages = raw isa AbstractVector && all(page -> page isa AbstractVector, raw) ? raw : (raw,)
    for page in pages
        page isa AbstractVector || error("commit comments response is not an array")
        for comment in page
            user = get(comment, :user, nothing)
            login = user === nothing ? "" : get(user, :login, "")
            body = get(comment, :body, "")
            created = get(comment, :created_at, "")
            login isa AbstractString || continue
            body isa AbstractString || continue
            created isa AbstractString || continue
            login == "github-actions[bot]" || continue
            startswith(body, "@JuliaRegistrator register") || continue
            created >= cutoff && return "wait"
        end
    end
    return "post"
end

function require_registry_response(http_status::Integer)
    http_status == 200 || error("General registry returned HTTP $http_status")
    return true
end

function validate_sha_state(expected::AbstractString, head::AbstractString,
                            main::AbstractString; require_head::Bool=true)
    occursin(r"^[0-9a-f]{40}$", expected) ||
        error("expected SHA must be 40 lowercase hexadecimal characters")
    main == expected || error("origin/main is $main, expected $expected")
    require_head && head != expected && error("HEAD is $head, expected $expected")
    return true
end

function _check_git_sha(expected::AbstractString; require_head::Bool)
    head = _git(ROOT, "rev-parse", "HEAD")
    main = _git(ROOT, "rev-parse", "origin/main")
    return validate_sha_state(expected, head, main; require_head)
end

function write_status_atomic(path::AbstractString, values::AbstractDict)
    dir = dirname(abspath(path))
    isdir(dir) || mkpath(dir)
    tmp, io = mktemp(dir)
    try
        TOML.print(io, values; sorted=true)
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

function _write_decision(path::AbstractString, decision::ReleaseDecision)
    write_status_atomic(path, Dict(
        "status" => decision.status,
        "version" => string(decision.version),
        "tag" => decision.tag,
        "detail" => decision.detail,
    ))
end

function prepare_intent!(path::AbstractString=INTENT_PATH; root::AbstractString=ROOT)
    intent = read_intent(path)
    isempty(_git(root, "status", "--porcelain")) ||
        error("prepare-intent requires a clean worktree")
    digest = canonical_source_digest(root)
    content = """\
    # Merge this file last. Any later tracked change except Artifacts.toml
    # invalidates source_digest and parks the release.
    schema = 1
    state = "ready"
    julia_version = "$(intent.julia_version)"
    powerio_tag = "$(intent.powerio_tag)"
    source_digest = "$digest"
    """
    write(path, content)
    return digest
end

function _emit_github_output(status_path::AbstractString, output_path::AbstractString)
    values = TOML.parsefile(status_path)
    allowed = ("status", "version", "tag", "changed", "reason", "detail")
    open(output_path, "a") do io
        for key in allowed
            haskey(values, key) || continue
            value = values[key]
            text = value isa Bool ? string(value) : String(value)
            occursin('\n', text) && error("status value $key contains a newline")
            println(io, key, "=", text)
        end
    end
end

function main(args=ARGS)
    isempty(args) && error(
        "usage: release_state.jl <initial|release|check|digest|prepare-intent|" *
        "check-main-sha|check-exact-sha|check-registry-http|tagbot-action|" *
        "registration-comment-action|github-output> ...")
    command = popfirst!(args)
    if command == "initial"
        length(args) == 3 || error("usage: release_state.jl initial EVENT DISPATCH_TAG STATUS")
        _write_decision(args[3], evaluate_initial_state(args[1], args[2]))
    elseif command == "release"
        length(args) == 4 || error("usage: release_state.jl release RELEASE_JSON|- OPEN_PRS VERSIONS STATUS")
        release_path = args[1] == "-" ? nothing : args[1]
        decision = evaluate_release_state(release_path, parse(Int, args[2]), args[3])
        _write_decision(args[4], decision)
    elseif command == "check"
        isempty(args) || error("usage: release_state.jl check")
        validate_ready_intent()
        artifact_tag() == read_intent().powerio_tag ||
            error("Artifacts.toml does not select the intended powerio tag")
    elseif command == "digest"
        length(args) <= 1 || error("usage: release_state.jl digest [REV]")
        println(canonical_source_digest(ROOT; rev=isempty(args) ? "HEAD" : only(args)))
    elseif command == "prepare-intent"
        isempty(args) || error("usage: release_state.jl prepare-intent")
        println(prepare_intent!())
    elseif command == "check-main-sha"
        length(args) == 1 || error("usage: release_state.jl check-main-sha EXPECTED")
        _check_git_sha(only(args); require_head=false)
    elseif command == "check-exact-sha"
        length(args) == 1 || error("usage: release_state.jl check-exact-sha EXPECTED")
        _check_git_sha(only(args); require_head=true)
    elseif command == "check-registry-http"
        length(args) == 1 || error("usage: release_state.jl check-registry-http STATUS")
        require_registry_response(parse(Int, only(args)))
    elseif command == "tagbot-action"
        length(args) == 2 || error(
            "usage: release_state.jl tagbot-action REGISTRY_STATUS HTTP_STATUS")
        println(tagbot_action(args[1], parse(Int, args[2])))
    elseif command == "registration-comment-action"
        length(args) == 2 || error(
            "usage: release_state.jl registration-comment-action COMMENTS_JSON CUTOFF")
        println(registration_comment_action(args[1], args[2]))
    elseif command == "github-output"
        length(args) == 2 || error("usage: release_state.jl github-output STATUS GITHUB_OUTPUT")
        _emit_github_output(args[1], args[2])
    else
        error("unknown release_state.jl command $command")
    end
    return nothing
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    PowerIOReleaseState.main()
end
