import lustre/effect.{type Effect}

pub fn focus(id: String) -> Effect(message) {
  use _, _ <- effect.after_paint

  do_focus(id)
}

@external(javascript, "./browser_ffi.mjs", "focus")
fn do_focus(id: String) -> Nil
