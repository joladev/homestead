import gleam/option.{Some}
import homestead/identity_document.{Identity}

pub fn an_identity_document_gives_handle_server_and_signing_key_test() {
  let body =
    "{\"id\":\"did:plc:aaaaaaaaaaaaaaaaaaaaaaaa\",\"alsoKnownAs\":[\"at://noor.harbor.example\"],
      \"verificationMethod\":[{\"id\":\"did:plc:aaaaaaaaaaaaaaaaaaaaaaaa#atproto\",
      \"type\":\"Multikey\",\"controller\":\"did:plc:aaaaaaaaaaaaaaaaaaaaaaaa\",
      \"publicKeyMultibase\":\"zQ3shXjHe\"}],
      \"service\":[{\"id\":\"#atproto_pds\",
      \"type\":\"AtprotoPersonalDataServer\",
      \"serviceEndpoint\":\"https://harbor.example\"}]}"

  let assert Ok(Identity(handle:, server:, signing_key:, ..)) =
    identity_document.read(body)

  assert handle == Some("noor.harbor.example")
  assert server == Some("https://harbor.example")
  assert signing_key == Some("zQ3shXjHe")
}
