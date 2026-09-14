include(joinpath(@__DIR__, "..", "gen", "paired_release.jl"))

@testset "Paired binary asset validation" begin
    names = ["libpowerio_capi.$triplet.tar.gz" for (triplet, _) in PowerIOPairedRelease.Updater.PLATFORMS]
    assets = [(name=name, digest="sha256:" * repeat("a", 64)) for name in names]
    @test length(PowerIOPairedRelease.validate_assets((prerelease=false, assets=assets))) == 5
    manifest = (name="release-manifest.json", digest="sha256:" * repeat("b", 64))
    @test length(PowerIOPairedRelease.validate_assets((prerelease=false, assets=[assets; manifest]))) == 5
    @test_throws ErrorException PowerIOPairedRelease.validate_assets((prerelease=true, assets=assets))
    @test_throws ErrorException PowerIOPairedRelease.validate_assets((prerelease=false, assets=assets[1:4]))
    @test_throws ErrorException PowerIOPairedRelease.validate_assets((prerelease=false, assets=[assets; assets[1]]))
    extra = (name="unreviewed.zip", digest="sha256:" * repeat("c", 64))
    @test_throws ErrorException PowerIOPairedRelease.validate_assets((prerelease=false, assets=[assets; extra]))
end
