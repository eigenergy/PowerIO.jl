@testset "Aqua quality" begin
    # `parse` extends `Base.parse` with single argument methods so the bare
    # name works after `using PowerIO`; Aqua counts that as piracy.
    Aqua.test_all(PowerIO; piracies=(treat_as_own=[Base.parse],))
end
