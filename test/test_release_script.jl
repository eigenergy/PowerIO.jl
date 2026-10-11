using Test

include(joinpath(@__DIR__, "..", "gen", "release.jl"))

const Release = PowerIORelease

function _release_file(dir, name, content)
    path = joinpath(dir, name)
    write(path, content)
    return path
end

_registry(dir, versions) = _release_file(dir, "Versions.toml", join(
    ("[\"$v\"]\ngit-tree-sha1 = \"$(repeat("0", 40))\"\n" for v in versions), "\n"))

# Rows as `gh release list --json tagName,isDraft,isPrerelease` renders them.
_releases(dir, rows) = _release_file(dir, "releases.tsv", join(
    ("$tag\t$draft\t$prerelease\n" for (tag, draft, prerelease) in rows)))

_published(tags...) = [(tag, false, false) for tag in tags]

function _run(args...; root=pwd())
    io = IOBuffer()
    Release.main(collect(String, args); io, root)
    return String(take!(io))
end

const CHANGELOG_HEAD = "# Changelog\n\n"
const OLD_SECTION = "## 0.11.4\n\n- Old notes.\n"

@testset "release script" begin
    @testset "target selection" begin
        mktempdir() do dir
            registry = _registry(dir, ["0.11.3", "0.11.4"])
            @test Release.latest_registered(registry) == v"0.11.4"

            listing = _releases(dir, [
                ("v0.11.6", false, false),
                ("v0.11.5", false, false),
                ("v0.11.4", false, false),
                ("v0.12.0-rc1", false, false),
            ])
            @test Release.published_versions(listing) == [v"0.11.4", v"0.11.5", v"0.11.6"]
            # The smallest newer release, not the newest.
            @test _run("next", registry, listing) == "0.11.5\n"

            # Nothing newer prints nothing.
            @test _run("next", registry, _releases(dir, _published("v0.11.4", "v0.11.3"))) == ""
            # Drafts and prereleases are not targets.
            @test _run("next", registry, _releases(dir, [
                ("v0.11.4", false, false), ("v0.11.5", true, false), ("v0.11.5", false, true),
            ])) == ""

            @test Release.next_version(v"0.11.4", [v"0.11.4", v"0.12.0"]) == v"0.12.0"
            @test Release.next_version(v"0.11.4", [v"0.11.4", v"1.0.0"]) == v"1.0.0"
            @test Release.next_version(v"0.11.4", [v"0.11.4"]) === nothing
        end
    end

    @testset "a skipped version is an error" begin
        @test_throws r"skip a version" Release.next_version(v"0.11.4", [v"0.11.4", v"0.11.6"])
        @test_throws r"skip a version" Release.next_version(v"0.11.4", [v"0.11.4", v"0.12.1"])
        mktempdir() do dir
            @test_throws ErrorException _run("next", _registry(dir, ["0.11.4"]),
                                             _releases(dir, _published("v0.11.4", "v0.11.6")))
        end
    end

    @testset "General's latest version needs a published powerio release" begin
        @test_throws r"no published powerio release v0.11.4" Release.next_version(
            v"0.11.4", [v"0.11.3", v"0.11.5"])
        mktempdir() do dir
            registry = _registry(dir, ["0.11.4"])
            @test_throws ErrorException _run("next", registry, _releases(dir, [
                ("v0.11.4", true, false), ("v0.11.5", false, false),
            ]))
            @test_throws ErrorException Release.latest_registered(_release_file(dir, "empty.toml", ""))
        end
    end

    @testset "changelog keep, rename, and insert" begin
        keep = CHANGELOG_HEAD * "## 0.11.5\n\n- Kept.\n\n" * OLD_SECTION
        @test Release.prepare_changelog(keep, v"0.11.5") == keep
        empty_unreleased = CHANGELOG_HEAD * "## Unreleased\n\n## 0.11.5\n\n- Kept.\n\n" * OLD_SECTION
        @test Release.prepare_changelog(empty_unreleased, v"0.11.5") == empty_unreleased
        # The release commit holds the Unreleased changes, so their notes
        # cannot stay out of an existing release section.
        @test_throws r"notes under ## Unreleased and a ## 0.11.5 section" Release.prepare_changelog(
            CHANGELOG_HEAD * "## Unreleased\n\n- Later work.\n\n## 0.11.5\n\n- Kept.\n\n" * OLD_SECTION,
            v"0.11.5")

        renamed = Release.prepare_changelog(
            CHANGELOG_HEAD * "## Unreleased\n\n- New notes.\n\n" * OLD_SECTION, v"0.11.5")
        @test renamed == CHANGELOG_HEAD * "## 0.11.5\n\n- New notes.\n\n" * OLD_SECTION

        entry = "## 0.11.5\n\n- Pairs with PowerIO 0.11.5; see the PowerIO changelog: " *
                "https://github.com/eigenergy/powerio/blob/v0.11.5/CHANGELOG.md\n\n"
        @test Release.prepare_changelog(CHANGELOG_HEAD * OLD_SECTION, v"0.11.5") ==
              CHANGELOG_HEAD * entry * OLD_SECTION
        # An empty Unreleased section stays in place above the new section.
        @test Release.prepare_changelog(CHANGELOG_HEAD * "## Unreleased\n\n" * OLD_SECTION, v"0.11.5") ==
              CHANGELOG_HEAD * "## Unreleased\n\n" * entry * OLD_SECTION
        @test Release.prepare_changelog(CHANGELOG_HEAD, v"0.11.5") == CHANGELOG_HEAD * chop(entry)
        @test Release.prepare_changelog(CHANGELOG_HEAD * "## Unreleased\n", v"0.11.5") ==
              CHANGELOG_HEAD * "## Unreleased\n\n" * chop(entry)
        # Deeper headings are part of the section, not a section boundary.
        nested = CHANGELOG_HEAD * "## Unreleased\n\n### Added\n\n- Item.\n\n" * OLD_SECTION
        @test Release.prepare_changelog(nested, v"0.12.0") ==
              CHANGELOG_HEAD * "## 0.12.0\n\n### Added\n\n- Item.\n\n" * OLD_SECTION
    end

    @testset "a patch release refuses a breaking change" begin
        breaking = CHANGELOG_HEAD * "## Unreleased\n\n### Breaking\n\n- Removed `f`.\n\n" * OLD_SECTION
        @test_throws r"marks a change as breaking.*### Breaking" Release.prepare_changelog(breaking, v"0.11.5")
        @test startswith(Release.prepare_changelog(breaking, v"0.12.0"), CHANGELOG_HEAD * "## 0.12.0\n")
        kept = CHANGELOG_HEAD * "## 0.11.5\n\n### Breaking changes\n\n- Removed `f`.\n\n" * OLD_SECTION
        @test_throws r"marks a change as breaking" Release.prepare_changelog(kept, v"0.11.5")
        # The labels CHANGELOG.md uses for breaking entries.
        for entry in ("- Breaking: `f` is removed.", "Breaking: `f` is removed.",
                      "  builders already read it. Breaking: `lengths` grows.",
                      "- **Breaking:** `f` is removed.", "- Removed `f` (breaking): use `g`.")
            text = CHANGELOG_HEAD * "## Unreleased\n\n" * entry * "\n\n" * OLD_SECTION
            @test_throws r"marks a change as breaking" Release.prepare_changelog(text, v"0.11.5")
            @test startswith(Release.prepare_changelog(text, v"0.12.0"), CHANGELOG_HEAD * "## 0.12.0\n")
        end
        # Prose that names breaking changes without marking one passes.
        for entry in ("No breaking changes: the Julia API is unchanged.",
                      "- A non-breaking: fix to `f`.", "- Fix a crash breaking `f`.")
            text = CHANGELOG_HEAD * "## Unreleased\n\n" * entry * "\n\n" * OLD_SECTION
            @test startswith(Release.prepare_changelog(text, v"0.11.5"), CHANGELOG_HEAD * "## 0.11.5\n")
        end
        # A breaking entry in an older section does not block the release.
        older = CHANGELOG_HEAD * "## Unreleased\n\n- Fix.\n\n## 0.11.0\n\n### Breaking\n\n- Old.\n"
        @test startswith(Release.prepare_changelog(older, v"0.11.5"), CHANGELOG_HEAD * "## 0.11.5\n")
    end

    @testset "project version" begin
        project = "name = \"PowerIO\"\nversion = \"0.11.4\"\n\n[compat]\njulia = \"1.10\"\n"
        @test Release.prepare_project(project, v"0.11.5") ==
              "name = \"PowerIO\"\nversion = \"0.11.5\"\n\n[compat]\njulia = \"1.10\"\n"
        @test Release.prepare_project(project, v"0.11.4") == project
        @test_throws r"above the release" Release.prepare_project(project, v"0.11.3")
        @test_throws ErrorException Release.prepare_project("name = \"PowerIO\"\n", v"0.11.5")
    end

    @testset "prepare edits Project.toml and CHANGELOG.md" begin
        mktempdir() do root
            write(joinpath(root, "Project.toml"), "name = \"PowerIO\"\nversion = \"0.11.4\"\n")
            write(joinpath(root, "CHANGELOG.md"), CHANGELOG_HEAD * "## Unreleased\n\n- New.\n\n" * OLD_SECTION)
            @test _run("prepare", "0.11.5"; root) == ""
            @test read(joinpath(root, "Project.toml"), String) == "name = \"PowerIO\"\nversion = \"0.11.5\"\n"
            @test read(joinpath(root, "CHANGELOG.md"), String) ==
                  CHANGELOG_HEAD * "## 0.11.5\n\n- New.\n\n" * OLD_SECTION
            @test_throws ErrorException _run("prepare", "v0.11.5"; root)
        end
    end

    @testset "release notes" begin
        text = CHANGELOG_HEAD * "## 0.11.5\n\n- New.\n\nC ABI 7 remains.\n\n" * OLD_SECTION
        notes = Release.release_notes(text, v"0.11.5")
        @test occursin("changelog", notes)
        @test notes == "- New.\n\nC ABI 7 remains.\n\nPowerIO changelog: " *
                       "https://github.com/eigenergy/powerio/blob/v0.11.5/CHANGELOG.md"
        @test !occursin("Old notes", notes)
        @test_throws ErrorException Release.release_notes(text, v"0.11.6")
        @test_throws ErrorException Release.release_notes(CHANGELOG_HEAD * "## 0.11.5\n\n" * OLD_SECTION, v"0.11.5")
        mktempdir() do root
            write(joinpath(root, "CHANGELOG.md"), text)
            @test _run("notes", "0.11.5"; root) == notes * "\n"
        end
    end

    @testset "artifact pin status" begin
        mktempdir() do dir
            ready = _release_file(dir, "ready.toml", "status = \"ready\"\ntag = \"v0.11.5\"\nchanged = true\n")
            @test Release.pin_status(ready) === nothing
            parked = _release_file(dir, "parked.toml",
                "status = \"parked\"\nreason = \"core_abi_mismatch\"\ndetail = \"binary ABI 8\"\n")
            @test_throws r"parked: core_abi_mismatch binary ABI 8" Release.pin_status(parked)
        end
    end

    @testset "General registration" begin
        mktempdir() do dir
            title = "New version: PowerIO v0.11.5"
            url = "https://github.com/JuliaRegistries/General/pull/1"
            prs(rows...) = _release_file(dir, "prs.tsv", join(("$(join(r, '\t'))\n" for r in rows)))
            @test Release.general_pr(v"0.11.5", prs()) == ("none", "")
            @test Release.general_pr(v"0.11.5", prs(
                ("New version: PowerIOX v0.11.5", url, 60, "MERGED", false),
                ("New version: PowerIO v0.11.4", url, 60, "MERGED", false))) == ("none", "")
            @test Release.general_pr(v"0.11.5", prs((title, url, 1200, "OPEN", false))) == ("wait", url)
            @test_throws r"over an hour: https://github.com/JuliaRegistries/General/pull/1" Release.general_pr(
                v"0.11.5", prs((title, url, 3601, "OPEN", false)))
            @test Release.general_pr(v"0.11.5", prs((title, url, 60, "OPEN", true))) == ("failed", url)
            @test Release.general_pr(v"0.11.5", prs((title, url, 9999, "OPEN", true))) == ("failed", url)
            # A merged registration counts while General's Versions.toml lags.
            @test Release.general_pr(v"0.11.5", prs((title, url, 9999, "MERGED", false))) == ("registered", url)
            # A closed, unmerged registration is ignored.
            @test Release.general_pr(v"0.11.5", prs((title, url, 9999, "CLOSED", true))) == ("none", "")
            @test _run("general-pr", "0.11.5", prs((title, url, 60, "OPEN", false))) == "wait $url\n"
            @test _run("general-pr", "0.11.5", prs()) == "none\n"
        end
    end

    @testset "registration requests and replies" begin
        mktempdir() do dir
            comments(rows...) = _release_file(dir, "comments.tsv", join(("$(join(r, '\t'))\n" for r in rows)))
            head, earlier = "headsha", "earliersha"
            url = "https://github.com/JuliaRegistries/General/pull/1"
            bot = "github-actions[bot]"
            request(sha, created, age) = (sha, bot, created, age, "@JuliaRegistrator register")
            reply(sha, created, line) = (sha, "JuliaRegistrator", created, 0, line)
            created_pr = "Registration pull request created: [JuliaRegistries/General/1](url)"
            refused = "Error while trying to register: Version 0.11.5 already exists"

            @test !Release.requested(comments(), head)
            @test !Release.requested(comments((head, "reviewer", "2026-10-11T10:00:00Z", 60, "Looks good")), head)
            # A recent request on any commit since the version was set is in flight.
            @test Release.requested(comments(request(head, "2026-10-11T10:00:00Z", 600)), head)
            @test Release.requested(comments(request(earlier, "2026-10-11T10:00:00Z", 600)), head)
            @test Release.requested(comments(
                request(earlier, "2026-10-11T10:00:00Z", 600),
                reply(earlier, "2026-10-11T10:00:20Z", created_pr)), head)
            @test Release.requested(comments(("x", "reviewer", "2026-10-11T10:00:00Z", 60,
                                              "@JuliaRegistrator register branch=main")), head)
            # A request six hours old is made again.
            @test !Release.requested(comments(request(head, "2026-10-11T04:00:00Z", 21600)), head)
            # An error answer on the commit to register fails; on an earlier
            # commit the run requests the newer one.
            @test_throws r"replied to the registration request on headsha: Error while" Release.requested(
                comments(request(head, "2026-10-11T10:00:00Z", 600),
                         reply(head, "2026-10-11T10:00:20Z", refused)), head)
            @test !Release.requested(comments(
                request(earlier, "2026-10-11T10:00:00Z", 600),
                reply(earlier, "2026-10-11T10:00:20Z", refused)), head)
            # Only the latest request counts.
            @test Release.requested(comments(
                request(earlier, "2026-10-11T09:00:00Z", 4200),
                reply(earlier, "2026-10-11T09:00:20Z", refused),
                request(head, "2026-10-11T10:00:00Z", 600)), head)
            @test !Release.requested(comments(
                request(head, "2026-10-11T10:00:00Z", 600),
                reply(head, "2026-10-11T10:00:20Z", created_pr),
                request(earlier, "2026-10-11T10:30:00Z", 60),
                reply(earlier, "2026-10-11T10:30:20Z", refused)), head)

            # A failed AutoMerge: a commit not yet requested is requested,
            # which updates the pull request; the requested one is an error.
            @test !Release.requested(comments(
                request(earlier, "2026-10-11T10:00:00Z", 600),
                reply(earlier, "2026-10-11T10:00:20Z", created_pr)), head; failed_url=url)
            @test_throws r"AutoMerge failed on https://github.com/JuliaRegistries/General/pull/1" Release.requested(
                comments(request(head, "2026-09-01T10:00:00Z", 999999)), head; failed_url=url)
            @test _run("requested", comments(request(head, "2026-10-11T10:00:00Z", 600)), head) == "yes\n"
            @test _run("requested", comments(request(earlier, "2026-10-11T10:00:00Z", 600)), head, url) == "no\n"

            since = "2026-10-11T10:00:00Z"
            old_reply = reply(head, "2026-10-11T09:00:00Z", "Error while trying to register: old")
            new_request = request(head, since, 600)
            @test Release.registrator_reply(comments(old_reply, new_request), since) == "none"
            @test Release.registrator_reply(comments(old_reply, new_request,
                                                     reply(head, "2026-10-11T10:00:20Z", created_pr)), since) == "ok"
            @test Release.registrator_reply(comments(new_request, reply(head, "2026-10-11T10:00:20Z",
                "Registration pull request updated: [JuliaRegistries/General/1](url)")), since) == "ok"
            @test_throws r"already exists" Release.registrator_reply(
                comments(new_request, reply(head, "2026-10-11T10:00:20Z", refused)), since)
            @test _run("reply", comments(new_request, reply(head, "2026-10-11T10:00:20Z", created_pr)), since) == "ok\n"
        end
    end

    @test_throws ErrorException _run("unknown")
end
