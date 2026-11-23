import gleam/json
import gleam/result
import homestead/setting

pub fn a_service_that_is_not_set_uses_its_default_test() {
  let body = "{\"plc\":\"\",\"dns\":\"https://dns.example/query\"}"
  let assert Ok(settings) = json.parse(body, setting.decoder())

  assert settings.directory.host == "plc.directory"
  assert settings.typeahead.host == "typeahead.cove.town"
  assert settings.dns.host == "dns.example"
  assert settings.dns.path == "/query"
}

pub fn a_malformed_address_is_refused_test() {
  assert json.parse("{\"slingshot\":\"nonsense\"}", setting.decoder())
    |> result.is_error
}
