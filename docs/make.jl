# Build the Documenter site. Locally:
#   julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
#   julia --project=docs docs/make.jl
# CI deploys to gh-pages on pushes to main (the docs job in CI.yml).
using Documenter
using PowerIO

makedocs(;
    sitename = "PowerIO.jl",
    modules = [PowerIO],
    checkdocs = :exports,
    doctest = false,
    format = Documenter.HTML(;
        canonical = "https://eigenergy.github.io/PowerIO.jl",
        edit_link = "main",
    ),
    pages = [
        "Home" => "index.md",
        "Modules" => "modules.md",
        "Networks" => "transmission.md",
        "Matrices" => "matrices.md",
        "OPF" => "opf-backends.md",
        "Distribution" => "distribution.md",
        "Interop" => "interop.md",
        "Developer Guides" => [
            "Migrating from 0.9" => "migration-0.10.md",
            "Binary distribution" => "binary.md",
            "Memory safety" => "memory-safety.md",
            "Language map" => "languages.md",
            "API reference" => "api.md",
        ],
    ],
)

deploydocs(; repo = "github.com/eigenergy/PowerIO.jl.git", devbranch = "main")
