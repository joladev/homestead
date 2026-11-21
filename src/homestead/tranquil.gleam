import gleam/dynamic/decode.{type Decoder}
import gleam/http/request.{type Request}
import gleam/javascript/promise.{type Promise}
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import gleam/uri.{type Uri}
import homestead/session.{type Session}
import lustre/effect.{type Effect}

pub type Software {
  Tranquil(version: String)
  OtherSoftware
}

pub fn health_request(server: Uri) -> Result(Request(String), Nil) {
  request.from_uri(server)
  |> result.map(request.set_path(_, "/xrpc/_health"))
}

pub fn health_decoder() -> Decoder(Software) {
  use version <- decode.field("version", decode.string)

  case version {
    "tranquil " <> version -> decode.success(Tranquil(version:))
    _ -> decode.success(OtherSoftware)
  }
}

pub type Problem {
  SessionEnded
  Unreachable
  Refused(error: String)
  NotUnderstood
}

pub opaque type Query(answer) {
  Query(path: String, decoder: Decoder(answer))
}

pub type Account {
  Account(
    handle: String,
    contact_channel: String,
    contact_verified: Bool,
    is_admin: Bool,
  )
}

pub type Passkey {
  Passkey(id: String, name: Option(String))
}

pub type Authenticator {
  Authenticator(enabled: Bool, backup_codes_remaining: Int)
}

pub type ActiveSession {
  ActiveSession(
    id: String,
    app: Option(String),
    created: Timestamp,
    expires: Timestamp,
    is_current: Bool,
  )
}

pub type RememberedApp {
  RememberedApp(client_id: String, scopes: List(String))
}

pub opaque type Command {
  Command(path: String, body: Json)
}

pub fn account() -> Query(Account) {
  query("com.atproto.server.getSession", [], {
    use handle <- decode.field("handle", decode.string)
    use contact_channel <- decode.field("preferredChannel", decode.string)
    use contact_verified <- decode.field(
      "preferredChannelVerified",
      decode.bool,
    )
    use is_admin <- decode.field("isAdmin", decode.bool)

    decode.success(Account(
      handle:,
      contact_channel:,
      contact_verified:,
      is_admin:,
    ))
  })
}

pub fn display_name(account: String) -> Query(Option(String)) {
  query(
    "com.atproto.repo.getRecord",
    [
      #("repo", account),
      #("collection", "app.bsky.actor.profile"),
      #("rkey", "self"),
    ],
    {
      use name <- decode.then(decode.optionally_at(
        ["value", "displayName"],
        "",
        decode.string,
      ))

      case string.trim(name) {
        "" -> decode.success(None)
        name -> decode.success(Some(name))
      }
    },
  )
}

pub fn passkeys() -> Query(List(Passkey)) {
  query(
    "com.atproto.server.listPasskeys",
    [],
    decode.at(["passkeys"], {
      decode.list({
        use id <- decode.field("id", decode.string)
        use name <- decode.field("friendlyName", decode.optional(decode.string))

        decode.success(Passkey(id:, name:))
      })
    }),
  )
}

pub fn authenticator() -> Query(Authenticator) {
  query("com.atproto.server.getTotpStatus", [], {
    use enabled <- decode.field("enabled", decode.bool)
    use backup_codes_remaining <- decode.field(
      "backupCodesRemaining",
      decode.int,
    )

    decode.success(Authenticator(enabled:, backup_codes_remaining:))
  })
}

pub fn has_password() -> Query(Bool) {
  query(
    "_account.getPasswordStatus",
    [],
    decode.at(["hasPassword"], decode.bool),
  )
}

pub fn sessions() -> Query(List(ActiveSession)) {
  query(
    "_account.listSessions",
    [],
    decode.at(["sessions"], {
      decode.list({
        use id <- decode.field("id", decode.string)
        use app <- decode.field("clientName", decode.optional(decode.string))
        use created <- decode.field("createdAt", timestamp_decoder())
        use expires <- decode.field("expiresAt", timestamp_decoder())
        use is_current <- decode.field("isCurrent", decode.bool)

        decode.success(ActiveSession(id:, app:, created:, expires:, is_current:))
      })
    }),
  )
}

pub fn remembered_apps() -> Query(List(RememberedApp)) {
  query(
    "_account.listRememberedAppChoices",
    [],
    decode.at(["choices"], {
      decode.list({
        use client_id <- decode.field("clientId", decode.string)
        use scopes <- decode.field("scopes", decode.list(decode.string))

        decode.success(RememberedApp(client_id:, scopes:))
      })
    }),
  )
}

pub fn end_session(id: String) -> Command {
  command(
    "_account.revokeSession",
    json.object([#("sessionId", json.string(id))]),
  )
}

pub fn end_other_sessions() -> Command {
  command("_account.revokeAllSessions", json.object([]))
}

pub fn forget_remembered_app(client_id: String) -> Command {
  command(
    "_account.forgetRememberedAppChoice",
    json.object([#("clientId", json.string(client_id))]),
  )
}

pub fn parse(query: Query(answer), body: String) -> Result(answer, Problem) {
  json.parse(body, query.decoder) |> result.replace_error(NotUnderstood)
}

pub fn fetch(
  session: Session,
  query: Query(answer),
) -> Promise(Result(answer, Problem)) {
  use response <- promise.map(session.get(session, query.path))
  use body <- result.try(accepted(session, response))

  parse(query, body)
}

pub fn run(
  session: Session,
  command: Command,
) -> Promise(Result(Nil, Problem)) {
  let body = json.to_string(command.body)
  use response <- promise.map(session.post(session, command.path, body))

  accepted(session, response) |> result.replace(Nil)
}

pub fn load(
  session: Session,
  query: Query(answer),
  to_message: fn(Result(answer, Problem)) -> message,
) -> Effect(message) {
  use dispatch <- effect.from

  fetch(session, query)
  |> promise.tap(fn(answer) { dispatch(to_message(answer)) })

  Nil
}

pub fn perform(
  session: Session,
  command: Command,
  to_message: fn(Result(Nil, Problem)) -> message,
) -> Effect(message) {
  use dispatch <- effect.from

  run(session, command)
  |> promise.tap(fn(outcome) { dispatch(to_message(outcome)) })

  Nil
}

fn accepted(
  session: Session,
  response: Result(#(Int, String), session.Problem),
) -> Result(String, Problem) {
  case response {
    Ok(#(200, body)) -> Ok(body)

    Ok(#(401, _)) | Error(session.SessionEnded) -> {
      session.forget(session)

      Error(SessionEnded)
    }

    Ok(#(_, body)) ->
      case json.parse(body, decode.at(["error"], decode.string)) {
        Ok(error) -> Error(Refused(error:))
        Error(_) -> Error(NotUnderstood)
      }

    Error(session.SignInRejected)
    | Error(session.NothingStored)
    | Error(session.Failed(_)) -> Error(Unreachable)
  }
}

fn timestamp_decoder() -> Decoder(Timestamp) {
  use text <- decode.then(decode.string)

  case timestamp.parse_rfc3339(text) {
    Ok(timestamp) -> decode.success(timestamp)
    Error(Nil) -> decode.failure(timestamp.from_unix_seconds(0), "Timestamp")
  }
}

fn command(name: String, body: Json) -> Command {
  Command(path: "/xrpc/" <> name, body:)
}

fn query(
  name: String,
  parameters: List(#(String, String)),
  decoder: Decoder(answer),
) -> Query(answer) {
  let path = case parameters {
    [] -> "/xrpc/" <> name
    [_, ..] -> "/xrpc/" <> name <> "?" <> uri.query_to_string(parameters)
  }

  Query(path:, decoder:)
}
