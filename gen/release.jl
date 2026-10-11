#!/usr/bin/env julia

# The decisions behind .github/workflows/release.yml. The workflow fetches
# General's Versions.toml and tab separated GitHub listings into files; the
# commands here read those files, so every decision runs offline and
# test/test_release_script.jl covers it. Only the TOML standard library is
# used, so the script runs without instantiating a project.
#
#   julia gen/release.jl latest VERSIONS_TOML
#   julia gen/release.jl next VERSIONS_TOML RELEASES_TSV
#   julia gen/release.jl prepare X.Y.Z
#   julia gen/release.jl pin-status STATUS_TOML
#   julia gen/release.jl notes X.Y.Z
#   julia gen/release.jl general-pr X.Y.Z PRS_TSV
#   julia gen/release.jl requested COMMENTS_TSV HEAD [FAILED_PR_URL]
#   julia gen/release.jl reply COMMENTS_TSV SINCE
module PowerIORelease

using TOML

const ROOT = normpath(joinpath(@__DIR__, ".."))
const REGISTER = "@JuliaRegistrator register"
# A General pull request normally merges within 20 minutes of opening.
const PENDING_PR_SECONDS = 3600
# Registrator answers a request within minutes; this window keeps the hourly
# schedule from repeating a request that is still being handled.
const REQUEST_SECONDS = 6 * 3600

powerio_changelog(version) =
    "https://github.com/eigenergy/powerio/blob/v$version/CHANGELOG.md"

function parse_version(text::AbstractString)
    occursin(r"^[0-9]+\.[0-9]+\.[0-9]+$", text) || error("version must be X.Y.Z, got $text")
    return VersionNumber(text)
end

# Tab separated rows as written by `gh ... --jq '... | @tsv'`.
function _rows(path::AbstractString, width::Integer)
    rows = Vector{SubString{String}}[]
    for line in eachline(path)
        isempty(strip(line)) && continue
        fields = split(line, '\t')
        length(fields) >= width || error("$path: expected $width fields in row: $line")
        push!(rows, fields)
    end
    return rows
end

"""
    latest_registered(versions_toml) -> VersionNumber

The highest version in General's `P/PowerIO/Versions.toml`.
"""
function latest_registered(path::AbstractString)
    versions = VersionNumber[]
    for key in keys(TOML.parsefile(path))
        version = tryparse(VersionNumber, key)
        version === nothing || push!(versions, version)
    end
    isempty(versions) && error("$path lists no PowerIO versions")
    return maximum(versions)
end

"""
    published_versions(releases_tsv) -> Vector{VersionNumber}

The published, non-prerelease `vX.Y.Z` powerio releases, sorted. Each row is
`tag`, `isDraft`, `isPrerelease` from `gh release list --json`.
"""
function published_versions(path::AbstractString)
    versions = VersionNumber[]
    for (tag, draft, prerelease) in _rows(path, 3)
        draft == "false" && prerelease == "false" || continue
        m = match(r"^v([0-9]+\.[0-9]+\.[0-9]+)$", tag)
        m === nothing || push!(versions, VersionNumber(m.captures[1]))
    end
    return sort!(unique!(versions))
end

is_next_release(previous::VersionNumber, target::VersionNumber) =
    target == VersionNumber(previous.major, previous.minor, previous.patch + 1) ||
    target == VersionNumber(previous.major, previous.minor + 1, 0) ||
    target == VersionNumber(previous.major + 1, 0, 0)

"""
    next_version(latest, published) -> Union{VersionNumber,Nothing}

The smallest published powerio release above `latest`, General's latest
PowerIO version, or `nothing` when there is none. Every PowerIO.jl version
pairs with the powerio release of the same number, so it is an error when
`latest` has no published powerio release or when the next published release
would skip a version.
"""
function next_version(latest::VersionNumber, published::AbstractVector{VersionNumber})
    latest in published || error(
        "General's latest PowerIO version $latest has no published powerio release v$latest")
    newer = sort!(filter(>(latest), collect(published)))
    isempty(newer) && return nothing
    target = first(newer)
    is_next_release(latest, target) || error(
        "the next published powerio release is v$target, but General's latest PowerIO " *
        "version is $latest; releasing $target would skip a version")
    return target
end

_heading(line::AbstractString) = startswith(line, "## ") ? strip(line[4:end]) : nothing

# Line range of the `## title` section: its heading through the line before
# the next `## ` heading.
function _section(lines, title::AbstractString)
    first_line = findfirst(line -> _heading(line) == title, lines)
    first_line === nothing && return nothing
    next_heading = findnext(line -> _heading(line) !== nothing, lines, first_line + 1)
    return first_line:(next_heading === nothing ? length(lines) : next_heading - 1)
end

_body(lines, range) = strip(join(lines[(first(range) + 1):last(range)], '\n'))

# A change marked breaking: a `### Breaking` heading, a `Breaking:` label
# anywhere in a line, or `(breaking)`. Prose such as "No breaking changes" or
# "non-breaking" does not match.
const BREAKING_MARK = r"^#{3,}\s+breaking\b|(?<![\w-])breaking\b[*_)]*:|\(breaking\)"i

"""
    prepare_changelog(text, version) -> String

Give `CHANGELOG.md` a `## X.Y.Z` section. An existing section is kept; a
non-empty `## Unreleased` section is renamed; otherwise a section pointing to
the powerio changelog is inserted. The release is built from the checked out
commit, which holds the changes under `## Unreleased`, so notes there next to
an existing `## X.Y.Z` section are refused. A patch release whose section
marks a change as breaking is refused.
"""
function prepare_changelog(text::AbstractString, version::VersionNumber)
    lines = split(text, '\n')
    title = string(version)
    unreleased = _section(lines, "Unreleased")
    if _section(lines, title) !== nothing
        unreleased === nothing || isempty(_body(lines, unreleased)) || error(
            "CHANGELOG.md has notes under ## Unreleased and a ## $title section. " *
            "PowerIO.jl $title is released from this commit, which holds the " *
            "Unreleased changes: move those notes into ## $title, or release an " *
            "earlier commit with source_sha")
    elseif unreleased !== nothing && !isempty(_body(lines, unreleased))
        lines[first(unreleased)] = "## $title"
    else
        at = if unreleased !== nothing
            last(unreleased) + 1
        else
            something(findfirst(line -> _heading(line) !== nothing, lines), length(lines) + 1)
        end
        entry = ["## $title", "",
                 "- Pairs with PowerIO $title; see the PowerIO changelog: " *
                 powerio_changelog(title), ""]
        if at > length(lines)
            # Appended at the end: one blank line before the heading.
            while !isempty(lines) && isempty(strip(last(lines)))
                pop!(lines)
            end
            append!(lines, ["", entry...])
        else
            splice!(lines, at:(at - 1), entry)
        end
    end
    section = _section(lines, title)
    marked = findfirst(line -> occursin(BREAKING_MARK, line), lines[section])
    if version.patch > 0 && marked !== nothing
        error("CHANGELOG.md section $title marks a change as breaking, but $title is a " *
              "patch release: $(strip(lines[section][marked]))")
    end
    return join(lines, '\n')
end

"""
    prepare_project(text, version) -> String

Set the `version` line of `Project.toml`. A version above `version` is refused.
"""
function prepare_project(text::AbstractString, version::VersionNumber)
    m = match(r"(?m)^version[ \t]*=[ \t]*\"([^\"]*)\"[ \t]*$", text)
    m === nothing && error("Project.toml has no version line")
    current = VersionNumber(m.captures[1])
    current > version && error("Project.toml version $current is above the release $version")
    stop = m.offset + ncodeunits(m.match)
    return text[1:prevind(text, m.offset)] * "version = \"$version\"" * text[stop:end]
end

function prepare!(root::AbstractString, version::VersionNumber)
    project = joinpath(root, "Project.toml")
    changelog = joinpath(root, "CHANGELOG.md")
    project_text = prepare_project(read(project, String), version)
    changelog_text = prepare_changelog(read(changelog, String), version)
    write(project, project_text)
    write(changelog, changelog_text)
    return nothing
end

"""
    pin_status(status_toml)

Accept only a `ready` status from `gen/update_artifacts.jl`.
"""
function pin_status(path::AbstractString)
    status = TOML.parsefile(path)
    get(status, "status", "") == "ready" && return nothing
    error("gen/update_artifacts.jl reported $(get(status, "status", "no status")): " *
          "$(get(status, "reason", "")) $(get(status, "detail", ""))")
end

"""
    release_notes(text, version) -> String

The `## X.Y.Z` section of `CHANGELOG.md` followed by a link to the powerio
changelog. General's AutoMerge requires release notes that mention a
changelog.
"""
function release_notes(text::AbstractString, version::VersionNumber)
    lines = split(text, '\n')
    section = _section(lines, string(version))
    section === nothing && error("CHANGELOG.md has no ## $version section")
    body = _body(lines, section)
    isempty(body) && error("CHANGELOG.md section $version is empty")
    return body * "\n\nPowerIO changelog: " * powerio_changelog(version)
end

"""
    general_pr(version, prs_tsv) -> (state, url)

Rows are `title`, `url`, seconds since the pull request opened or
Registrator last pushed to it, `state` (`OPEN`, `CLOSED` or `MERGED`), and
whether AutoMerge failed, for JuliaRegistrator's General pull requests. The
state is

- `registered` when the registration merged, since General's `Versions.toml`
  can trail the merge by several minutes;
- `failed` when the open registration failed AutoMerge;
- `wait` when the open registration changed within the hour;
- `none` otherwise. A closed, unmerged registration is ignored.

An open registration unchanged for over an hour that has not failed
AutoMerge is an error naming its link.
"""
function general_pr(version::VersionNumber, path::AbstractString)
    title = "New version: PowerIO v$version"
    rows = filter(row -> row[1] == title, _rows(path, 5))
    for (_, url, _, state, _) in rows
        state == "MERGED" && return ("registered", url)
    end
    for (_, url, age, state, failed) in rows
        state == "OPEN" || continue
        failed == "true" && return ("failed", url)
        parse(Int, age) > PENDING_PR_SECONDS &&
            error("the PowerIO $version registration has waited over an hour: $url")
        return ("wait", url)
    end
    return ("none", "")
end

# Comment rows are the commit sha, `login`, `created_at`, age in seconds, and
# the first line of the body. `created_at` is an RFC 3339 UTC timestamp as
# GitHub writes it, so string order is time order.

_reports_pr(line) = startswith(line, "Registration pull request")

"""
    requested(comments_tsv, head; failed_url="") -> Bool

Whether a registration request is still being handled, so the run must not
ask again. The rows cover the commits from the one that set `Project.toml`
to the release version through `head`. The latest `@JuliaRegistrator
register` request counts while it is younger than six hours, unless
JuliaRegistrator answered it with an error. The same commit gets the same
answer, so an error answer to a request on `head` is itself an error; an
error answer to a request on an earlier commit gives false, and the run
requests `head`, which may hold the fix.

`failed_url` names an open General pull request whose AutoMerge failed.
Requesting a new commit makes Registrator update that pull request, so the
result is false unless `head` was already requested, which is an error.
"""
function requested(path::AbstractString, head::AbstractString; failed_url::AbstractString="")
    rows = _rows(path, 5)
    requests = filter(row -> startswith(row[5], REGISTER), rows)
    if !isempty(failed_url)
        any(row -> row[1] == head, requests) && error(
            "AutoMerge failed on $failed_url, and registration of $head was already " *
            "requested. Fix the cause on main: the next run requests the new commit, " *
            "and Registrator updates the pull request")
        return false
    end
    isempty(requests) && return false
    sha, _, since, age, _ = requests[argmax([row[3] for row in requests])]
    parse(Int, age) < REQUEST_SECONDS || return false
    for (row_sha, login, created, _, line) in rows
        row_sha == sha && login == "JuliaRegistrator" && created >= since || continue
        _reports_pr(line) && return true
        sha == head && error("JuliaRegistrator replied to the registration request on $head: $line")
        return false
    end
    return true
end

"""
    registrator_reply(comments_tsv, since) -> "ok" | "none"

Read the first JuliaRegistrator comment created at or after `since`. A reply
that does not report a registration pull request is an error carrying its
first line.
"""
function registrator_reply(path::AbstractString, since::AbstractString)
    for (_, login, created, _, line) in _rows(path, 5)
        login == "JuliaRegistrator" && created >= since || continue
        _reports_pr(line) && return "ok"
        error("JuliaRegistrator replied: $line")
    end
    return "none"
end

const USAGE = """
usage: julia gen/release.jl COMMAND ...
  latest VERSIONS_TOML
  next VERSIONS_TOML RELEASES_TSV
  prepare X.Y.Z
  pin-status STATUS_TOML
  notes X.Y.Z
  general-pr X.Y.Z PRS_TSV
  requested COMMENTS_TSV HEAD [FAILED_PR_URL]
  reply COMMENTS_TSV SINCE"""

function main(args=ARGS; io::IO=stdout, root::AbstractString=ROOT)
    command = isempty(args) ? "" : first(args)
    n = length(args)
    if command == "latest" && n == 2
        println(io, latest_registered(args[2]))
    elseif command == "next" && n == 3
        target = next_version(latest_registered(args[2]), published_versions(args[3]))
        target === nothing || println(io, target)
    elseif command == "prepare" && n == 2
        prepare!(root, parse_version(args[2]))
    elseif command == "pin-status" && n == 2
        pin_status(args[2])
    elseif command == "notes" && n == 2
        println(io, release_notes(read(joinpath(root, "CHANGELOG.md"), String),
                                  parse_version(args[2])))
    elseif command == "general-pr" && n == 3
        state, url = general_pr(parse_version(args[2]), args[3])
        println(io, isempty(url) ? state : "$state $url")
    elseif command == "requested" && n in (3, 4)
        failed_url = n == 4 ? args[4] : ""
        println(io, requested(args[2], args[3]; failed_url) ? "yes" : "no")
    elseif command == "reply" && n == 3
        println(io, registrator_reply(args[2], args[3]))
    else
        error(USAGE)
    end
    return nothing
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    try
        PowerIORelease.main()
    catch err
        err isa ErrorException || rethrow()
        # A workflow command, so the reason shows on the run page.
        println(stderr, "::error::", replace(err.msg, '\n' => "%0A"))
        exit(1)
    end
end
