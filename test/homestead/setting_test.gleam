import gleam/json
import gleam/list
import gleam/result
import homestead/setting.{HomesteadFirst, ServerFirst}
import homestead/tranquil

pub fn a_service_that_is_not_set_uses_its_default_test() {
  let body = "{\"plc\":\"\",\"dns\":\"https://dns.example/query\"}"
  let assert Ok(settings) = json.parse(body, setting.decoder())

  assert settings.directory.host == "plc.directory"
  assert settings.typeahead.host == "typeahead.cove.town"
  assert settings.dns.host == "dns.example"
  assert settings.dns.path == "/query"
  assert settings.sign_up_servers == []
  assert list.length(settings.relays) == 6
  assert settings.password_entry == ServerFirst
}

pub fn a_malformed_address_is_refused_test() {
  assert json.parse("{\"slingshot\":\"nonsense\"}", setting.decoder())
    |> result.is_error
}

pub fn sign_up_servers_are_a_comma_separated_list_test() {
  let body =
    "{\"signUpServers\":\"harbor.example, https://cove.example\",\"relays\":\"relay.example\"}"
  let assert Ok(settings) = json.parse(body, setting.decoder())

  assert list.map(settings.relays, tranquil.server_name) == ["relay.example"]

  assert list.map(settings.sign_up_servers, tranquil.server_name)
    == ["harbor.example", "cove.example"]
}

pub fn passwords_can_be_entered_in_homestead_first_test() {
  let assert Ok(settings) =
    json.parse("{\"passwordEntry\":\"homestead\"}", setting.decoder())

  assert settings.password_entry == HomesteadFirst
  assert json.parse("{\"passwordEntry\":\"elsewhere\"}", setting.decoder())
    |> result.is_error
}
