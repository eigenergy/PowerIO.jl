# The powerio lineage this binding targets. Every document powerio authors
# states one version, the release that wrote it, so there is one number here
# rather than one per document.
# gen/update_artifacts.jl includes this file standalone: no package deps.
const POWERIO_VERSION_KEY = "powerio_version"

# The reader's acceptance rule (`powerio::version::supports`): exact
# major.minor while the major is 0, major-only from 1.0.0.
_same_schema_lineage(a::VersionNumber, b::VersionNumber) =
    a.major == b.major && (a.major != 0 || a.minor == b.minor)
# Upstream rejects a version it cannot parse; mirror that as `false`, so a
# malformed report reads as a lineage mismatch, not a raised parse error.
function _same_schema_lineage(a, b)
    va = tryparse(VersionNumber, string(a))
    vb = tryparse(VersionNumber, string(b))
    va === nothing || vb === nothing ? false : _same_schema_lineage(va, vb)
end
