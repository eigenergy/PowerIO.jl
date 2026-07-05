# Build the Documenter site. Locally:
#   julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
#   julia --project=docs docs/make.jl
# CI deploys to gh-pages on pushes to main (the docs job in CI.yml).
using Documenter
using PowerIO

makedocs(;
    sitename = "PowerIO.jl",
    modules = [PowerIO],
    doctest = false,
    format = Documenter.HTML(;
        canonical = "https://eigenergy.github.io/PowerIO.jl",
        edit_link = "main",
    ),
    pages = [
        "Home" => "index.md",
        "Transmission networks" => "transmission.md",
        "Matrices" => "matrices.md",
        "Distribution networks" => "distribution.md",
        "Ecosystem interop" => "interop.md",
        "Binary distribution" => "binary.md",
        "Memory safety" => "memory-safety.md",
        "Language APIs" => "languages.md",
        "API reference" => "api.md",
    ],
)

deploydocs(; repo = "github.com/eigenergy/PowerIO.jl.git", devbranch = "main")
