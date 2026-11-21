import gleam/list
import gleam/option.{Some}
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
