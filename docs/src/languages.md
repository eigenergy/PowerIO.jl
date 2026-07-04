# Language APIs

The cross language naming table (Rust, Python, Julia, C ABI) lives in the
powerio repository:
[docs/languages.md](https://github.com/eigenergy/powerio/blob/main/docs/languages.md).

Julia-specific notes:

- Julia adds `parse_file(io, format)` because multiple dispatch is the natural
  way to express IO input.
- Julia does not use `convert` / `convert!` for file format conversion. In
  Julia, `Base.convert` means type conversion and `!` marks mutation; PowerIO
  returns new values.
