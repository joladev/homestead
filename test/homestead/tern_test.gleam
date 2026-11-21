import at/did
import gleam/json
import gleam/option.{None, Some}
import homestead/tern.{Actor}

pub fn a_search_response_decodes_to_its_actors_test() {
  let assert Ok(named) = did.from_string("did:plc:k4q7m2x3vt5hwz6r2ypbn7cs")
  let assert Ok(bare) = did.from_string("did:plc:w7h2n5t3c3x6v2r4m2k4q7yp")
  let body =
    "{\"actors\":[
      {\"did\":\"did:plc:k4q7m2x3vt5hwz6r2ypbn7cs\",\"handle\":\"noor.harbor.example\",
       \"displayName\":\"Noor\",\"avatar\":\"https://cdn.example/noor.jpg\",\"labels\":[]},
      {\"did\":\"did:plc:w7h2n5t3c3x6v2r4m2k4q7yp\",\"handle\":\"bare.harbor.example\",\"labels\":[]}
    ]}"

  assert json.parse(body, tern.search_decoder())
    == Ok([
      Actor(
        did: named,
        handle: "noor.harbor.example",
        display_name: Some("Noor"),
        avatar: Some("https://cdn.example/noor.jpg"),
      ),
      Actor(
        did: bare,
        handle: "bare.harbor.example",
        display_name: None,
        avatar: None,
      ),
    ])
}
