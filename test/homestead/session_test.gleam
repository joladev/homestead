import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/uri.{Uri}
import homestead/session.{Client}

pub fn local_app_is_a_loopback_client_test() {
  let assert Ok(app) = uri.parse("http://127.0.0.1:1234/access/sessions")
  let Client(id:, redirect_uri:) = session.client(app)
  let assert Ok(Uri(host: Some("localhost"), query: Some(query), ..)) =
    uri.parse(id)
  let assert Ok(parameters) = uri.parse_query(query)

  assert redirect_uri == "http://127.0.0.1:1234/oauth/callback"
  assert list.key_find(parameters, "redirect_uri") == Ok(redirect_uri)
}

pub fn hosted_app_is_a_web_client_test() {
  let assert Ok(app) = uri.parse("https://homestead.example/")

  assert session.client(app)
    == Client(
      id: "https://homestead.example/oauth-client-metadata.json",
      redirect_uri: "https://homestead.example/oauth/callback",
    )
}

pub fn the_hosted_client_file_matches_what_the_app_sends_test() {
  let assert Ok(app) = uri.parse("https://homestead.at/")
  let Client(id:, redirect_uri:) = session.client(app)
  let assert Ok(#(file_id, file_redirects, file_scope)) =
    read("docker/oauth-client-metadata.json")
    |> string.replace(each: "{{env \"HOMESTEAD_HOST\"}}", with: "homestead.at")
    |> json.parse({
      use id <- decode.field("client_id", decode.string)
      use redirects <- decode.field("redirect_uris", decode.list(decode.string))
      use scope <- decode.field("scope", decode.string)

      decode.success(#(id, redirects, scope))
    })

  assert file_id == id
  assert file_redirects == [redirect_uri]
  assert file_scope == session.scope()
}

pub fn a_sign_in_attempt_carries_its_request_test() {
  let assert Ok(attempt) =
    session.attempt(
      "https://harbor.example/oauth/authorize?client_id=app&request_uri=urn%3Aietf%3Aparams%3Aoauth%3Arequest_uri%3Aabc",
    )

  assert attempt.request == "urn:ietf:params:oauth:request_uri:abc"
  assert attempt.server_page.host == Some("harbor.example")
}

@external(javascript, "./file_ffi.mjs", "read")
fn read(path: String) -> String
