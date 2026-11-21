import at/did
import at/did_document.{type DidDocument}
import at/handle
import at/oauth.{
  type AuthorisationServer, type Client, type DpopRequest, type Nonce,
  type ResourceServer, type Verified, PendingAuthorisation,
}
import gleam/dynamic/decode.{type Decoder}
import gleam/fetch
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/javascript/promise.{type Promise}
import gleam/json.{type Json}
import gleam/option.{None, Some}
import gleam/result
import gleam/uri.{type Uri, Uri}
import plinth/browser/web_storage.{type Storage}
import ywt
import ywt/algorithm
import ywt/sign_key.{type SignKey}
import ywt/verify_key

pub const callback_path = "/oauth/callback"

const scopes = [
  "repo:*?action=create",
  "repo:*?action=update",
  "repo:*?action=delete",
  "blob:*/*",
  "identity:*",
  "account:*?action=manage",
]

const pending_key = "homestead.pending-sign-in"

const session_key = "homestead.session"

pub type Session {
  Session(
    account: DidDocument,
    tokens: oauth.Session(Verified),
    sign_key: SignKey,
    token_response: String,
  )
}

pub type Problem {
  ServerUnreachable
  ServerAnsweredUnexpectedly
  CallbackRejected
  AccountMismatch
  NothingStored
  StoredDataNotUnderstood
  StorageUnavailable
}

pub fn client(app: Uri) -> Client {
  let origin =
    Uri(..uri.empty, scheme: app.scheme, host: app.host, port: app.port)

  let client = case origin.host, origin.port {
    Some("127.0.0.1"), Some(port) -> oauth.localhost_client(port, callback_path)
    _, _ ->
      oauth.public_client(
        Uri(..origin, path: "/oauth-client-metadata.json"),
        Uri(..origin, path: callback_path),
        oauth.Web,
      )
  }

  oauth.client_scopes(client, scopes)
}

pub fn handle(session: Session) -> String {
  case did_document.also_known_as(session.account) {
    Ok(handle) -> handle.to_string(handle)
    Error(Nil) -> did.to_string(session.account.id)
  }
}

pub fn begin(
  account: DidDocument,
  server: Uri,
  client: Client,
) -> Promise(Result(Uri, Problem)) {
  use authorisation_server <- promise.try_await(locate_authorisation_server(
    server,
  ))
  use sign_key <- promise.await(ywt.generate_key(algorithm.es256))

  let #(request, pkce_challenge, state) =
    oauth.request_authorisation(
      client,
      authorisation_server,
      Some(did.to_string(account.id)),
      verify_key.derived(sign_key),
      None,
    )

  use #(response, dpop_nonce) <- promise.map_try(send_signed(request, sign_key))
  use token <- result.try(parse(
    response.body,
    oauth.authorisation_token_decoder(),
  ))

  let pending =
    PendingAuthorisation(
      subject: account,
      client:,
      server: authorisation_server,
      pkce_challenge:,
      state:,
      dpop_private_key: sign_key,
      dpop_nonce:,
    )

  use storage <- result.try(tab_storage())
  use Nil <- result.map(write(
    storage,
    pending_key,
    oauth.pending_authorisation_to_json(pending),
  ))

  oauth.redirect(client, authorisation_server, token)
}

pub fn complete(callback: Uri) -> Promise(Result(Session, Problem)) {
  let exchange = {
    use storage <- result.try(tab_storage())
    use pending <- result.try(read(
      storage,
      pending_key,
      oauth.pending_authorisation_decoder(),
    ))
    web_storage.remove_item(storage, pending_key)

    use grant <- result.map(
      oauth.parse_authorisation_uri(
        callback,
        pending.client,
        pending.server,
        pending.state,
      )
      |> result.replace_error(CallbackRejected),
    )

    let request =
      oauth.create_session(
        pending.client,
        pending.server,
        grant,
        pending.pkce_challenge,
        verify_key.derived(pending.dpop_private_key),
        pending.dpop_nonce,
      )

    #(pending, request)
  }

  use #(pending, request) <- promise.try_await(promise.resolve(exchange))
  use #(response, _) <- promise.map_try(send_signed(
    request,
    pending.dpop_private_key,
  ))
  use session <- result.try(from_token_response(
    pending.subject,
    pending.dpop_private_key,
    response.body,
  ))
  use storage <- result.try(browser_storage())
  use Nil <- result.map(write(
    storage,
    session_key,
    json.object([
      #("account", did_document.to_json(session.account)),
      #("sign_key", sign_key.to_jwk(session.sign_key)),
      #("token_response", json.string(session.token_response)),
    ]),
  ))

  session
}

pub fn restore() -> Result(Session, Problem) {
  let stored = {
    use account <- decode.field("account", did_document.decoder())
    use sign_key <- decode.field("sign_key", sign_key.decoder())
    use token_response <- decode.field("token_response", decode.string)

    decode.success(#(account, sign_key, token_response))
  }

  use storage <- result.try(browser_storage())
  use #(account, sign_key, token_response) <- result.try(read(
    storage,
    session_key,
    stored,
  ))

  from_token_response(account, sign_key, token_response)
  |> result.replace_error(StoredDataNotUnderstood)
}

pub fn end(session: Session) -> Promise(Result(Nil, Problem)) {
  let revocation = {
    use storage <- result.try(browser_storage())
    web_storage.remove_item(storage, session_key)

    use server <- result.try(
      did_document.pds(session.account)
      |> result.replace_error(StoredDataNotUnderstood),
    )
    use token <- result.map(parse(
      session.token_response,
      decode.at(["refresh_token"], decode.string),
    ))

    #(server, token)
  }

  use #(server, token) <- promise.try_await(promise.resolve(revocation))
  use resource <- promise.try_await(locate_resource_server(server))
  use endpoint <- promise.try_await(fetch_json(
    oauth.query_authorisation_server(resource.authorisation_server),
    decode.at(["revocation_endpoint"], decode.string),
  ))

  let request = {
    use endpoint <- result.try(uri.parse(endpoint))
    use request <- result.map(request.from_uri(endpoint))

    request
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/x-www-form-urlencoded")
    |> request.set_body(uri.query_to_string([#("token", token)]))
  }

  use request <- promise.try_await(
    promise.resolve(result.replace_error(request, ServerAnsweredUnexpectedly)),
  )
  use response <- promise.map_try(send(request))

  case response.status {
    200 -> Ok(Nil)
    _ -> Error(ServerAnsweredUnexpectedly)
  }
}

fn from_token_response(
  account: DidDocument,
  sign_key: SignKey,
  token_response: String,
) -> Result(Session, Problem) {
  use tokens <- result.try(parse(token_response, oauth.session_decoder()))
  use tokens <- result.map(
    oauth.verify_session_subject(tokens, account.id)
    |> result.replace_error(AccountMismatch),
  )

  Session(account:, tokens:, sign_key:, token_response:)
}

fn locate_authorisation_server(
  server: Uri,
) -> Promise(Result(AuthorisationServer, Problem)) {
  use resource <- promise.try_await(locate_resource_server(server))

  fetch_json(
    oauth.query_authorisation_server(resource.authorisation_server),
    oauth.authorisation_server_decoder(resource.authorisation_server),
  )
}

fn locate_resource_server(
  server: Uri,
) -> Promise(Result(ResourceServer, Problem)) {
  fetch_json(
    oauth.locate_authorisation_server(server),
    oauth.resource_server_decoder(),
  )
}

fn fetch_json(
  request: Result(Request(String), Nil),
  decoder: Decoder(a),
) -> Promise(Result(a, Problem)) {
  use request <- promise.try_await(
    promise.resolve(result.replace_error(request, ServerAnsweredUnexpectedly)),
  )
  use response <- promise.map_try(send(request))

  parse(response.body, decoder)
}

fn send_signed(
  request: DpopRequest(String),
  sign_key: SignKey,
) -> Promise(Result(#(Response(String), Nonce), Problem)) {
  use response <- promise.try_await(send_with_proof(request, sign_key))

  case oauth.extract_nonce(response) {
    Ok(oauth.Continue(nonce)) -> promise.resolve(Ok(#(response, nonce)))

    Ok(oauth.Retry(nonce)) -> {
      let request = oauth.retry(request, nonce, None)
      use response <- promise.map_try(send_with_proof(request, sign_key))

      case oauth.extract_nonce(response) {
        Ok(oauth.Continue(nonce)) | Ok(oauth.Retry(nonce)) ->
          Ok(#(response, nonce))
        Error(Nil) -> Error(ServerAnsweredUnexpectedly)
      }
    }

    Error(Nil) -> promise.resolve(Error(ServerAnsweredUnexpectedly))
  }
}

fn send_with_proof(
  request: DpopRequest(String),
  sign_key: SignKey,
) -> Promise(Result(Response(String), Problem)) {
  use signature <- promise.await(ywt.sign_string(oauth.proof(request), sign_key))

  send(oauth.prepare(request, signature))
}

fn send(
  request: Request(String),
) -> Promise(Result(Response(String), Problem)) {
  fetch.send(request)
  |> promise.try_await(fetch.read_text_body)
  |> promise.map(result.replace_error(_, ServerUnreachable))
}

fn parse(body: String, decoder: Decoder(a)) -> Result(a, Problem) {
  json.parse(body, decoder)
  |> result.replace_error(ServerAnsweredUnexpectedly)
}

fn tab_storage() -> Result(Storage, Problem) {
  web_storage.session() |> result.replace_error(StorageUnavailable)
}

fn browser_storage() -> Result(Storage, Problem) {
  web_storage.local() |> result.replace_error(StorageUnavailable)
}

fn write(storage: Storage, key: String, value: Json) -> Result(Nil, Problem) {
  web_storage.set_item(storage, key, json.to_string(value))
  |> result.replace_error(StorageUnavailable)
}

fn read(
  storage: Storage,
  key: String,
  decoder: Decoder(a),
) -> Result(a, Problem) {
  case web_storage.get_item(storage, key) {
    Ok(Some(value)) ->
      json.parse(value, decoder)
      |> result.replace_error(StoredDataNotUnderstood)
    Ok(None) -> Error(NothingStored)
    Error(_) -> Error(StorageUnavailable)
  }
}
