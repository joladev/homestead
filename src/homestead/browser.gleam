import gleam/javascript/promise.{type Promise}
import lustre/effect.{type Effect}

pub fn focus(id: String) -> Effect(message) {
  use _, _ <- effect.after_paint

  do_focus(id)
}

pub fn copy(
  text: String,
  to_message: fn(Result(Nil, Nil)) -> message,
) -> Effect(message) {
  use dispatch <- effect.from

  do_copy(text)
  |> promise.tap(fn(copied) { dispatch(to_message(copied)) })

  Nil
}

@external(javascript, "./browser_ffi.mjs", "focus")
fn do_focus(id: String) -> Nil

@external(javascript, "./browser_ffi.mjs", "copy")
fn do_copy(text: String) -> Promise(Result(Nil, Nil))
