import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/javascript/promise.{type Promise}
import lustre/effect.{type Effect}

pub fn focus(id: String) -> Effect(message) {
  use _, _ <- effect.after_paint

  do_focus(id)
}

pub fn open_dialog(id: String) -> Effect(message) {
  use _, _ <- effect.after_paint

  do_open_dialog(id)
}

pub type File

pub fn after(milliseconds: Int, message: message) -> Effect(message) {
  use dispatch <- effect.from

  do_after(milliseconds, fn() { dispatch(message) })
}

pub fn file_decoder() -> Decoder(File) {
  use value <- decode.then(decode.at(["target", "files", "0"], decode.dynamic))

  case to_file(value) {
    Ok(file) -> decode.success(file)
    Error(Nil) -> decode.failure(empty_file(), "File")
  }
}

@external(javascript, "./browser_ffi.mjs", "fileName")
pub fn file_name(file: File) -> String

@external(javascript, "./browser_ffi.mjs", "origin")
pub fn origin() -> String

pub fn await(
  start: fn() -> Promise(value),
  to_message: fn(value) -> message,
) -> Effect(message) {
  use dispatch <- effect.from

  start() |> promise.tap(fn(value) { dispatch(to_message(value)) })

  Nil
}

pub fn copy(
  text: String,
  to_message: fn(Result(Nil, Nil)) -> message,
) -> Effect(message) {
  await(fn() { do_copy(text) }, to_message)
}

pub fn generate_password(to_message: fn(String) -> message) -> Effect(message) {
  use dispatch <- effect.from

  dispatch(to_message(do_generate_password()))
}

@external(javascript, "./browser_ffi.mjs", "generatePassword")
fn do_generate_password() -> String

@external(javascript, "./browser_ffi.mjs", "focus")
fn do_focus(id: String) -> Nil

@external(javascript, "./browser_ffi.mjs", "copy")
fn do_copy(text: String) -> Promise(Result(Nil, Nil))

@external(javascript, "./browser_ffi.mjs", "openDialog")
fn do_open_dialog(id: String) -> Nil

@external(javascript, "./browser_ffi.mjs", "after")
fn do_after(milliseconds: Int, callback: fn() -> Nil) -> Nil

@external(javascript, "./browser_ffi.mjs", "toFile")
fn to_file(value: Dynamic) -> Result(File, Nil)

@external(javascript, "./browser_ffi.mjs", "emptyFile")
fn empty_file() -> File
