@testset "library resolution" begin
    @test PowerIO._HEADER_RELEASE isa VersionNumber

    missing = joinpath(@__DIR__, "definitely-not-a-powerio-library")
    @test_throws Exception PowerIO._library_release(missing)
    @test PowerIO.library_available(missing) === false

    # A failed probe of another path must not replace the selected library.
    if LIBRARY_AVAILABLE
        active = PowerIO._checked_lib()
        cached = PowerIO._COMPATIBLE_LIB[]
        @test cached == active
        @test PowerIO.library_available(active) === true
        @test PowerIO._COMPATIBLE_LIB[] == cached
        @test PowerIO.library_available(missing) === false
        @test PowerIO._COMPATIBLE_LIB[] == cached
        @test PowerIO._checked_lib() == active
    else
        @test PowerIO.library_available() === false
    end
end
