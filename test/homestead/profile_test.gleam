import at/did.{type Did}
import at/handle
import gleam/bit_array
import gleam/http/request
import gleam/http/response
import gleam/option.{Some}
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

fn replied(reply: String) {
  let assert Ok(body) = bit_array.base64_decode(reply)

  Ok(response.new(200) |> response.set_body(body))
}

pub fn a_dns_question_asks_for_the_text_record_of_the_handle_test() {
  let assert Ok(resolver) = request.to("https://dns.example/dns-query")
  let assert Ok(handle) = handle.from_string("atproto.com")
  let question = profile.record_request(resolver, handle)

  assert question.host == "dns.example"
  assert question.path == "/dns-query"
  assert question.query
    == Some("dns=AAABAAABAAAAAAAACF9hdHByb3RvB2F0cHJvdG8DY29tAAAQAAE")
}

pub fn a_dns_reply_is_judged_by_its_text_record_test() {
  let named =
    "AACBgAABAAEAAAAACF9hdHByb3RvB2F0cHJvdG8DY29tAAAQAAHADAAQAAEAAAEsACUkZGlkPWRpZDpwbGM6ZXd2aTdueHp5b3VuNnpoeHJoczY0b2l6"
  let unknown =
    "AACBgwABAAAAAQAACF9hdHByb3RvBG5vb3IHZXhhbXBsZQAAEAABAAAGAAEAAKisAEABYQxyb290LXNlcnZlcnMDbmV0AAVuc3RsZAx2ZXJpc2lnbi1ncnMDY29tAHjEBSwAAAcIAAADhAAJOoAAAVGA"
  let failed = "AACBggABAAAAAAAA"

  assert profile.record_finding(replied(named), account()) == Ok(PointsHere)
  assert profile.record_finding(replied(unknown), account()) == Ok(Absent)
  assert profile.record_finding(replied(failed), account()) == Error(Nil)
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
