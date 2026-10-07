@testset "release metadata" begin
    root = dirname(@__DIR__)
    project = read(joinpath(root, "Project.toml"), String)
    changelog = read(joinpath(root, "CHANGELOG.md"), String)

    version_match = match(r"(?m)^version\s*=\s*\"([0-9]+\.[0-9]+\.[0-9]+)\"\s*$", project)
    @test version_match !== nothing
    version = only(version_match.captures)

    sections = split(changelog, r"(?m)^##\s+")
    # Development notes precede the latest numbered release until preparation
    # promotes them. They must not disable the released-version guard.
    if length(sections) >= 2 && strip(first(split(sections[2], '\n'))) == "Unreleased"
        deleteat!(sections, 2)
    end
    @test length(sections) >= 2

    lines = split(sections[2], '\n')
    @test !isempty(lines)
    @test strip(first(lines)) == version

    body = strip(join(lines[2:end], "\n"))
    @test !isempty(body)
    @test occursin(r"(?m)^- ", body)
end
