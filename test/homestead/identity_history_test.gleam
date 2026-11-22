import gleam/option.{Some}
import homestead/identity_history.{
  Created, Event, HandleChanged, History, RotationKeyAdded,
}

pub fn a_log_becomes_changes_with_the_newest_first_test() {
  let body =
    "[{\"cid\":\"first\",\"nullified\":false,\"createdAt\":\"2022-11-17T00:35:16.391Z\",
       \"operation\":{\"type\":\"create\",\"prev\":null,\"handle\":\"noor.harbor.example\",
       \"service\":\"https://harbor.example\",\"signingKey\":\"did:key:zSigning\",
       \"recoveryKey\":\"did:key:zRecovery\"}},
      {\"cid\":\"second\",\"nullified\":false,\"createdAt\":\"2023-04-26T17:16:46.827Z\",
       \"operation\":{\"type\":\"plc_operation\",\"prev\":\"first\",
       \"alsoKnownAs\":[\"at://noor.example\"],
       \"services\":{\"atproto_pds\":{\"type\":\"AtprotoPersonalDataServer\",
       \"endpoint\":\"https://harbor.example\"}},
       \"verificationMethods\":{\"atproto\":\"did:key:zSigning\"},
       \"rotationKeys\":[\"did:key:zRecovery\",\"did:key:zSigning\"]}},
      {\"cid\":\"third\",\"nullified\":true,\"createdAt\":\"2023-05-01T08:00:00.000Z\",
       \"operation\":{\"type\":\"plc_operation\",\"prev\":\"second\",
       \"alsoKnownAs\":[\"at://noor.example\"],
       \"services\":{\"atproto_pds\":{\"type\":\"AtprotoPersonalDataServer\",
       \"endpoint\":\"https://harbor.example\"}},
       \"verificationMethods\":{\"atproto\":\"did:key:zSigning\"},
       \"rotationKeys\":[\"did:key:zRecovery\",\"did:key:zSigning\",\"did:key:zNew\"]}}]"

  let assert Ok(History(events: [third, second, first], rotation_keys:)) =
    identity_history.read(body)

  let assert Event(is_cancelled: True, changes: [RotationKeyAdded(key:)], ..) =
    third
  assert key == "did:key:zNew"
  let assert Event(is_cancelled: False, changes: [HandleChanged(to:)], ..) =
    second
  assert to == Some("noor.example")
  let assert Event(changes: [Created(handle:, server:)], ..) = first
  assert handle == Some("noor.harbor.example")
  assert server == Some("https://harbor.example")
  assert rotation_keys == ["did:key:zRecovery", "did:key:zSigning"]
}
