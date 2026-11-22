import gleam/dynamic.{type Dynamic}

@external(javascript, "./json_text_ffi.mjs", "pretty")
pub fn pretty(value: Dynamic) -> String

@external(javascript, "./json_text_ffi.mjs", "compact")
pub fn compact(value: Dynamic) -> String
