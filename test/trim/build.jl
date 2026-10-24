# Compile app.jl with `juliac --trim=safe` and run it on case14 and a GO
# Challenge 3 instance: the trim verifier refuses any call it cannot resolve
# statically, so a regression in the typed parse or the positional
# `to_powerdata` fails the build. Julia 1.12+.
#
#     julia --project=test/trim test/trim/build.jl
using JuliaC

const HERE = @__DIR__
const CASE = joinpath(HERE, "..", "data", "case14.m")
const GOC3 = joinpath(HERE, "..", "data", "goc3", "goc3_small.json")

mktempdir() do dir
    exe = joinpath(dir, "powerio_trim")
    img = ImageRecipe(output_type = "--output-exe", file = joinpath(HERE, "app.jl"),
                      project = HERE, trim_mode = "safe", julia_args = ["--experimental"])
    compile_products(img)
    link_products(LinkRecipe(image_recipe = img, outname = exe))
    out = readchomp(`$exe $CASE $GOC3`)
    println("trimmed app: ", out)
    out == "14 5 20 40 0 100.0 2" || error("unexpected output from the trimmed app: " * out)
end
