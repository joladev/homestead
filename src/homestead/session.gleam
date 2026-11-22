import at/did.{type Did}
import gleam/javascript/promise.{type Promise}
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleam/uri.{type Uri, Uri}
import homestead/browser.{type File}

pub const callback_path = "/oauth/callback"

const scopes = [
  "atproto",
  "repo:*?action=create",
  "repo:*?action=update",
  "repo:*?action=delete",
  "blob:*/*",
  "identity:*",
  "account:*?action=manage",
]

pub type Session

pub type Client {
  Client(id: String, redirect_uri: String)
}

pub type Departure {
  SignedOut
  Ended
}

pub type Problem {
  SignInRejected
  SessionEnded
  NothingStored
  Failed(error: String)
}

pub fn client(app: Uri) -> Client {
  let origin =
    Uri(..uri.empty, scheme: app.scheme, host: app.host, port: app.port)
  let redirect_uri = uri.to_string(Uri(..origin, path: callback_path))

  case origin.host {
    Some("127.0.0.1") ->
      Client(
        id: "http://localhost?"
          <> uri.query_to_string([
          #("redirect_uri", redirect_uri),
          #("scope", scope()),
        ]),
        redirect_uri:,
      )
    _ ->
      Client(
        id: uri.to_string(Uri(..origin, path: "/oauth-client-metadata.json")),
        redirect_uri:,
      )
  }
}

pub fn configure(client: Client, directory: Uri) -> Nil {
  do_configure(client.id, client.redirect_uri, uri.to_string(directory))
}

pub fn begin(account: Did) -> Promise(Result(Uri, Problem)) {
  use login <- promise.map(do_begin(did.to_string(account), scope()))
  use login <- result.try(result.map_error(login, problem))

  uri.parse(login) |> result.replace_error(Failed(error: "InvalidLoginAddress"))
}

pub fn act_as(
  session: Session,
  account: String,
) -> Promise(Result(Uri, Problem)) {
  use login <- promise.map(do_act_as(session, account, scope()))
  use login <- result.try(result.map_error(login, problem))

  uri.parse(login) |> result.replace_error(Failed(error: "InvalidLoginAddress"))
}

pub fn begin_sign_up(server: Uri) -> Promise(Result(Uri, Problem)) {
  use registration <- promise.map(do_begin_sign_up(
    uri.to_string(server),
    scope(),
  ))
  use registration <- result.try(result.map_error(registration, problem))

  uri.parse(registration)
  |> result.replace_error(Failed(error: "InvalidLoginAddress"))
}

pub fn complete(answer: String) -> Promise(Result(Session, Problem)) {
  do_complete(answer) |> promise.map(result.map_error(_, problem))
}

pub fn restore() -> Promise(Result(Session, Problem)) {
  case stored_account() {
    Ok(account) ->
      do_restore(account) |> promise.map(result.map_error(_, problem))
    Error(Nil) -> promise.resolve(Error(NothingStored))
  }
}

@external(javascript, "./session_ffi.mjs", "end")
pub fn end(session: Session) -> Promise(Nil)

pub fn get(
  session: Session,
  path: String,
) -> Promise(Result(#(Int, String), Problem)) {
  do_get(session, path) |> promise.map(result.map_error(_, problem))
}

pub fn post(
  session: Session,
  path: String,
  body: String,
) -> Promise(Result(#(Int, String), Problem)) {
  do_post(session, path, body) |> promise.map(result.map_error(_, problem))
}

pub fn upload(
  session: Session,
  path: String,
  file: File,
) -> Promise(Result(#(Int, String), Problem)) {
  do_upload(session, path, file) |> promise.map(result.map_error(_, problem))
}

pub fn save(
  session: Session,
  path: String,
  filename: String,
) -> Promise(Result(#(Int, String), Problem)) {
  do_save(session, path, filename)
  |> promise.map(result.map_error(_, problem))
}

@external(javascript, "./session_ffi.mjs", "forget")
pub fn forget(session: Session) -> Nil

@external(javascript, "./session_ffi.mjs", "account")
pub fn account(session: Session) -> String

@external(javascript, "./session_ffi.mjs", "server")
pub fn server(session: Session) -> String

@external(javascript, "./session_ffi.mjs", "origin")
pub fn origin(session: Session) -> String

fn scope() -> String {
  string.join(scopes, " ")
}

fn problem(error: String) -> Problem {
  case error {
    "AuthorizationError" | "LoginError" -> SignInRejected
    "TokenRefreshError" -> SessionEnded
    _ -> Failed(error:)
  }
}

@external(javascript, "./session_ffi.mjs", "configure")
fn do_configure(
  client_id: String,
  redirect_uri: String,
  directory: String,
) -> Nil

@external(javascript, "./session_ffi.mjs", "begin")
fn do_begin(account: String, scope: String) -> Promise(Result(String, String))

@external(javascript, "./session_ffi.mjs", "actAs")
fn do_act_as(
  session: Session,
  account: String,
  scope: String,
) -> Promise(Result(String, String))

@external(javascript, "./session_ffi.mjs", "beginSignUp")
fn do_begin_sign_up(
  server: String,
  scope: String,
) -> Promise(Result(String, String))

@external(javascript, "./session_ffi.mjs", "complete")
fn do_complete(answer: String) -> Promise(Result(Session, String))

@external(javascript, "./session_ffi.mjs", "storedAccount")
fn stored_account() -> Result(String, Nil)

@external(javascript, "./session_ffi.mjs", "restore")
fn do_restore(account: String) -> Promise(Result(Session, String))

@external(javascript, "./session_ffi.mjs", "get")
fn do_get(
  session: Session,
  path: String,
) -> Promise(Result(#(Int, String), String))

@external(javascript, "./session_ffi.mjs", "post")
fn do_post(
  session: Session,
  path: String,
  body: String,
) -> Promise(Result(#(Int, String), String))

@external(javascript, "./session_ffi.mjs", "save")
fn do_save(
  session: Session,
  path: String,
  filename: String,
) -> Promise(Result(#(Int, String), String))

@external(javascript, "./session_ffi.mjs", "upload")
fn do_upload(
  session: Session,
  path: String,
  file: File,
) -> Promise(Result(#(Int, String), String))
