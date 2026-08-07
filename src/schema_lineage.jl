# The `.pio.json` envelope and Arrow schema lineages this binding targets
# (upstream `PIO_PACKAGE_SCHEMA_VERSION` and `arrow_export::ARROW_SCHEMA_VERSION`).
# They live here so the module and gen/update_artifacts.jl read one definition.
const PIO_PACKAGE_SCHEMA_VERSION = "0.2.0"
const PIO_ARROW_SCHEMA_VERSION = "1"

# The reader's acceptance rule (powerio-pkg `supports_schema_version`):
# exact major.minor while the major is 0, major-only from 1.0.0.
# gen/update_artifacts.jl includes this file standalone: no package deps.
_same_schema_lineage(a::VersionNumber, b::VersionNumber) =
    a.major == b.major && (a.major != 0 || a.minor == b.minor)
# Upstream rejects a version it cannot parse; mirror that as `false`, so a
# malformed report reads as a lineage mismatch, not a raised parse error.
function _same_schema_lineage(a, b)
    va = tryparse(VersionNumber, string(a))
    vb = tryparse(VersionNumber, string(b))
    va === nothing || vb === nothing ? false : _same_schema_lineage(va, vb)
end
