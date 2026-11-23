import at/did.{type Did}
import gleam/http/response
import homestead/profile.{
  Absent, Malformed, PointsElsewhere, PointsHere, Unreadable,
}
import rsvp

fn account() -> Did {
  let assert Ok(account) = did.from_string("did:plc:ewvi7nxzyoun6zhxrhs64oiz")

  account
}

fn answered(body: String) {
  Ok(response.new(200) |> response.set_body(body))
}

pub fn a_dns_answer_is_judged_by_its_text_record_test() {
  let body =
    "{\"Status\":0,\"Answer\":[
      {\"name\":\"_atproto.noor.example\",\"type\":16,
       \"data\":\"\\\"did=did:plc:ewvi7nxzyoun6zhxrhs64oiz\\\"\"},
      {\"name\":\"_atproto.noor.example\",\"type\":5,\"data\":\"elsewhere.example.\"}]}"

  assert profile.record_finding(answered(body), account()) == Ok(PointsHere)
  assert profile.record_finding(answered("{\"Status\":3}"), account())
    == Ok(Absent)
  assert profile.record_finding(Error(rsvp.NetworkError), account())
    == Error(Nil)
}

pub fn a_handle_file_is_judged_by_its_content_test() {
  let finding = profile.file_finding(_, account())

  assert finding(answered("did:plc:ewvi7nxzyoun6zhxrhs64oiz\n")) == PointsHere
  assert finding(answered("did:plc:ar7c4by46qjdydhdevvrndac"))
    == PointsElsewhere
  assert finding(answered("did=did:plc:ewvi7nxzyoun6zhxrhs64oiz")) == Malformed
  assert finding(Error(rsvp.NetworkError)) == Unreadable
}
