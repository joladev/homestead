import gleam/json
import homestead/tranquil.{OtherSoftware, Tranquil}

pub fn a_tranquil_health_answer_gives_its_version_test() {
  assert json.parse(
      "{\"version\":\"tranquil 0.8.0\"}",
      tranquil.health_decoder(),
    )
    == Ok(Tranquil(version: "0.8.0"))
}

pub fn another_servers_health_answer_is_other_software_test() {
  assert json.parse("{\"version\":\"0.4.193\"}", tranquil.health_decoder())
    == Ok(OtherSoftware)
}
