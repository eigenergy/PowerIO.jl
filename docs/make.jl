# Build the Documenter site. Locally:
#   julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
#   julia --project=docs docs/make.jl
# CI deploys to gh-pages on pushes to main (the docs job in CI.yml). The module
# loads without the C library, so the build needs no Rust toolchain.
using Documenter
using PowerIO

makedocs(;
    sitename = "PowerIO.jl",
    modules = [PowerIO],
    checkdocs = :exports,
    doctest = false,
    warnonly = [:cross_references],
    format = Documenter.HTML(;
        canonical = "https://eigenergy.github.io/PowerIO.jl",
        edit_link = "main",
    ),
    pages = [
        "Home" => "index.md",
        "Modules" => "modules.md",
        "Networks" => "networks.md",
        "Distribution" => "distribution.md",
        "Collections and instances" => "collections.md",
        "Matrices" => "matrices.md",
        "Updates" => "updates.md",
        "Interop" => "interop.md",
        "Developer Guides" => [
            "Migrating from 0.10 to 0.11" => "migration-0.11.md",
            "Binary distribution" => "binary.md",
            "Memory safety" => "memory-safety.md",
            "Language map" => "languages.md",
            "API reference" => "api.md",
        ],
    ],
)

deploydocs(; repo = "github.com/eigenergy/PowerIO.jl.git", devbranch = "main")
