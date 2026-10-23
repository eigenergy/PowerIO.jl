@testset "library resolution" begin
    @test PowerIO.PIO_ABI_VERSION == UInt32(7)

    missing = joinpath(@__DIR__, "definitely-not-a-powerio-library")
    @test_throws Exception PowerIO.abi_version(missing)
    @test PowerIO.library_available(missing) === false

    # A failed probe of another path must not replace the selected library.
    if LIBRARY_AVAILABLE
        active = PowerIO._checked_lib()
        @test PowerIO.library_available(active) === true
        @test PowerIO.library_available(missing) === false
        @test PowerIO._checked_lib() == active
    else
        @test PowerIO.library_available() === false
    end
end
