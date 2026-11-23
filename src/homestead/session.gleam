import at/did.{type Did}
import at/handle.{type Handle}
import gleam/javascript/array.{type Array}
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option.{type Option, None, Some}
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

pub opaque type Session {
  Session(agent: Agent, account: Did)
}

type Agent

pub type Client {
  Client(id: String, redirect_uri: String)
}

pub type Departure {
  SignedOut
  SwitchedAccount(account: Did)
}

pub type StoredAccount {
  StoredAccount(account: Did, handle: Option(Handle))
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

pub fn act_as(session: Session, account: Did) -> Promise(Result(Uri, Problem)) {
  use login <- promise.map(do_act_as(
    session.agent,
    did.to_string(account),
    scope(),
  ))
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
  do_complete(answer) |> promise.map(checked)
}

pub fn restore() -> Promise(Result(Session, Problem)) {
  case stored_account() |> result.try(did.from_string) {
    Ok(account) -> switch_to(account)
    Error(Nil) -> promise.resolve(Error(NothingStored))
  }
}

pub fn switch_to(account: Did) -> Promise(Result(Session, Problem)) {
  do_restore(did.to_string(account)) |> promise.map(checked)
}

fn checked(agent: Result(Agent, String)) -> Result(Session, Problem) {
  use agent <- result.try(result.map_error(agent, problem))

  did.from_string(do_account(agent))
  |> result.map(Session(agent:, account: _))
  |> result.replace_error(Failed(error: "InvalidAccount"))
}

pub fn when_expired(session: Session, do: fn() -> Nil) -> Nil {
  do_watch(session.agent, do)
}

@external(javascript, "./session_ffi.mjs", "watch")
fn do_watch(agent: Agent, do: fn() -> Nil) -> Nil

pub fn expire(session: Session) -> Nil {
  do_expire(session.agent)
}

@external(javascript, "./session_ffi.mjs", "expire")
fn do_expire(agent: Agent) -> Nil

pub fn stored_accounts() -> List(StoredAccount) {
  array.to_list(do_stored_accounts())
  |> list.filter_map(did.from_string)
  |> list.map(fn(account) {
    StoredAccount(
      account:,
      handle: remembered_handle(did.to_string(account))
        |> result.try(handle.from_string)
        |> option.from_result,
    )
  })
  |> list.sort(fn(one, other) {
    string.compare(account_name(one), account_name(other))
  })
}

pub fn account_name(account: StoredAccount) -> String {
  case account.handle {
    Some(handle) -> "@" <> handle.to_string(handle)
    None -> did.to_string(account.account)
  }
}

pub fn remove(account: Did) -> Promise(Nil) {
  do_remove(did.to_string(account))
}

@external(javascript, "./session_ffi.mjs", "remove")
fn do_remove(account: String) -> Promise(Nil)

pub fn remember_handle(session: Session, handle: Handle) -> Nil {
  do_remember_handle(session.agent, handle.to_string(handle))
}

@external(javascript, "./session_ffi.mjs", "rememberHandle")
fn do_remember_handle(agent: Agent, handle: String) -> Nil

pub fn end(session: Session) -> Promise(Nil) {
  do_end(session.agent)
}

@external(javascript, "./session_ffi.mjs", "end")
fn do_end(agent: Agent) -> Promise(Nil)

pub fn get(
  session: Session,
  path: String,
) -> Promise(Result(#(Int, String), Problem)) {
  do_get(session.agent, path) |> promise.map(result.map_error(_, problem))
}

pub fn post(
  session: Session,
  path: String,
  body: String,
) -> Promise(Result(#(Int, String), Problem)) {
  do_post(session.agent, path, body)
  |> promise.map(result.map_error(_, problem))
}

pub fn upload(
  session: Session,
  path: String,
  file: File,
) -> Promise(Result(#(Int, String), Problem)) {
  do_upload(session.agent, path, file)
  |> promise.map(result.map_error(_, problem))
}

pub fn save(
  session: Session,
  path: String,
  filename: String,
) -> Promise(Result(#(Int, String), Problem)) {
  do_save(session.agent, path, filename)
  |> promise.map(result.map_error(_, problem))
}

pub fn forget(session: Session) -> Nil {
  do_forget(session.agent)
}

@external(javascript, "./session_ffi.mjs", "forget")
fn do_forget(agent: Agent) -> Nil

pub fn account(session: Session) -> Did {
  session.account
}

@external(javascript, "./session_ffi.mjs", "account")
fn do_account(agent: Agent) -> String

pub fn server(session: Session) -> String {
  do_server(session.agent)
}

@external(javascript, "./session_ffi.mjs", "server")
fn do_server(agent: Agent) -> String

pub fn origin(session: Session) -> String {
  do_origin(session.agent)
}

@external(javascript, "./session_ffi.mjs", "origin")
fn do_origin(agent: Agent) -> String

pub fn scope() -> String {
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
  agent: Agent,
  account: String,
  scope: String,
) -> Promise(Result(String, String))

@external(javascript, "./session_ffi.mjs", "beginSignUp")
fn do_begin_sign_up(
  server: String,
  scope: String,
) -> Promise(Result(String, String))

@external(javascript, "./session_ffi.mjs", "complete")
fn do_complete(answer: String) -> Promise(Result(Agent, String))

@external(javascript, "./session_ffi.mjs", "storedAccount")
fn stored_account() -> Result(String, Nil)

@external(javascript, "./session_ffi.mjs", "storedAccounts")
fn do_stored_accounts() -> Array(String)

@external(javascript, "./session_ffi.mjs", "rememberedHandle")
fn remembered_handle(account: String) -> Result(String, Nil)

@external(javascript, "./session_ffi.mjs", "restore")
fn do_restore(account: String) -> Promise(Result(Agent, String))

@external(javascript, "./session_ffi.mjs", "get")
fn do_get(agent: Agent, path: String) -> Promise(Result(#(Int, String), String))

@external(javascript, "./session_ffi.mjs", "post")
fn do_post(
  agent: Agent,
  path: String,
  body: String,
) -> Promise(Result(#(Int, String), String))

@external(javascript, "./session_ffi.mjs", "save")
fn do_save(
  agent: Agent,
  path: String,
  filename: String,
) -> Promise(Result(#(Int, String), String))

@external(javascript, "./session_ffi.mjs", "upload")
fn do_upload(
  agent: Agent,
  path: String,
  file: File,
) -> Promise(Result(#(Int, String), String))
