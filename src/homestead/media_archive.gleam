import gleam/javascript/array.{type Array}
import homestead/session.{type Session}
import lustre/effect.{type Effect}

pub type Stopper

pub type Outcome {
  Saved
  Cancelled
  Failed
}

@external(javascript, "./media_archive_ffi.mjs", "savesToDisk")
pub fn saves_to_disk() -> Bool

pub fn save(
  session: Session,
  media: List(String),
  filename: String,
  started started: fn(Stopper) -> message,
  progressed progressed: fn(Int) -> message,
  finished finished: fn(Outcome) -> message,
) -> Effect(message) {
  use dispatch <- effect.from

  let stopper =
    start(
      session.origin(session),
      session.account(session),
      array.from_list(media),
      filename,
      fn(done) { dispatch(progressed(done)) },
      fn(result) {
        dispatch(
          finished(case result {
            Ok(Nil) -> Saved
            Error("AbortError") -> Cancelled
            Error(_) -> Failed
          }),
        )
      },
    )

  dispatch(started(stopper))
}

pub fn stop(stopper: Stopper) -> Effect(message) {
  use _ <- effect.from

  do_stop(stopper)
}

@external(javascript, "./media_archive_ffi.mjs", "start")
fn start(
  origin: String,
  account: String,
  media: Array(String),
  filename: String,
  on_progress: fn(Int) -> Nil,
  on_done: fn(Result(Nil, String)) -> Nil,
) -> Stopper

@external(javascript, "./media_archive_ffi.mjs", "stop")
fn do_stop(stopper: Stopper) -> Nil
