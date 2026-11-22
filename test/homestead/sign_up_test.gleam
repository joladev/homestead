import gleam/option.{Some}
import gleam/uri
import homestead/sign_up

pub fn a_bare_server_name_becomes_a_secure_address_test() {
  let assert Ok(server) = sign_up.parse_address(" harbor.example ")

  assert uri.to_string(server) == "https://harbor.example"
}

pub fn a_full_address_keeps_its_scheme_and_drops_its_path_test() {
  let assert Ok(server) = sign_up.parse_address("http://localhost:3000/app")

  assert server.scheme == Some("http")
  assert server.host == Some("localhost")
  assert server.port == Some(3000)
  assert server.path == ""
}

pub fn nothing_typed_is_not_an_address_test() {
  assert sign_up.parse_address("  ") == Error(Nil)
}
