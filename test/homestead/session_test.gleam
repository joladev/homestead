import at/oauth
import gleam/uri
import homestead/session

pub fn local_app_is_a_loopback_client_test() {
  let assert Ok(app) = uri.parse("http://127.0.0.1:1234/access/sessions")
  let client = session.client(app)

  assert client.application_type == oauth.Native
  assert uri.to_string(client.redirect_uri)
    == "http://127.0.0.1:1234/oauth/callback"
}

pub fn hosted_app_is_a_web_client_test() {
  let assert Ok(app) = uri.parse("https://homestead.example/")
  let client = session.client(app)

  assert client.application_type == oauth.Web
  assert uri.to_string(client.id)
    == "https://homestead.example/oauth-client-metadata.json"
  assert uri.to_string(client.redirect_uri)
    == "https://homestead.example/oauth/callback"
}
