# The PowerIO path a `juliac --trim=safe` image can carry: a typed parse and the
# ExaModelsPower bridge with the element type given positionally, and a typed
# parse of a calculation instance. Built and run by build.jl; prints the table
# sizes so the run can be checked.
using PowerIO

function (@main)(args::Vector{String})::Cint
    net = parse(BalancedNetwork, args[1])
    data = to_powerdata(net, Float64; zero_impedance = :open)
    sizes = (length(data.bus), length(data.gen), length(data.branch), length(data.arc), length(data.storage))
    instance = parse(PioModule{AcScucInstance}, args[2]).value
    println(Core.stdout, join(map(string, sizes), ' ') * " " * string(data.baseMVA) * " " *
                         string(length(instance.network.buses)))
    return 0
end
