import at/handle
import gleam/http/response
import gleam/option.{None, Some}
import homestead/appview.{
  Deactivated, Fact, Found, NotFound, Resolved, TakenDown, Unresolved,
}
import homestead/layout.{Confirms, Contradicts, Silent}
import homestead/remote.{Failed, Loaded}
import homestead/tranquil.{Profile}
import rsvp

fn answered(status: Int, body: String) {
  Ok(response.new(status) |> response.set_body(body))
}

pub fn an_appview_says_what_it_has_for_the_account_test() {
  let assert Ok(noor) = handle.from_string("noor.harbor.example")
  let found =
    "{\"did\":\"did:plc:k4q7m2x3vt5hwz6r2ypbn7cs\",\"handle\":\"noor.harbor.example\",\"displayName\":\"Noor\",\"avatar\":\"https://cdn.example/img/avatar/plain/did:plc:k4q7m2x3vt5hwz6r2ypbn7cs/bafkreiavatar@jpeg\"}"
  let unresolved =
    "{\"did\":\"did:plc:k4q7m2x3vt5hwz6r2ypbn7cs\",\"handle\":\"handle.invalid\"}"
  let unknown =
    "{\"error\":\"InvalidRequest\",\"message\":\"Profile not found\"}"
  let deactivated =
    "{\"error\":\"AccountDeactivated\",\"message\":\"Account is deactivated\"}"
  let taken_down =
    "{\"error\":\"AccountTakedown\",\"message\":\"Account has been suspended\"}"
  let signed_out =
    "{\"error\":\"AuthMissing\",\"message\":\"Authentication Required\"}"
  let nothing =
    Profile(name: None, description: None, avatar: None, banner: None)
  let read = appview.read_profile(_, from: "appview.example")

  assert read(answered(200, found))
    == Loaded(Found(
      handle: Resolved(handle: noor),
      profile: Profile(
        ..nothing,
        name: Some("Noor"),
        avatar: Some(
          "https://cdn.example/img/avatar/plain/did:plc:k4q7m2x3vt5hwz6r2ypbn7cs/bafkreiavatar@jpeg",
        ),
      ),
    ))
  assert read(answered(200, unresolved))
    == Loaded(Found(handle: Unresolved, profile: nothing))
  assert read(answered(400, unknown)) == Loaded(NotFound)
  assert read(answered(400, deactivated)) == Loaded(Deactivated)
  assert read(answered(400, taken_down)) == Loaded(TakenDown)
  assert read(answered(401, signed_out))
    == Failed(tranquil.Problem(
      service: "appview.example",
      reason: tranquil.Refused("AuthMissing", "Authentication Required"),
    ))
  assert read(Error(rsvp.NetworkError))
    == Failed(tranquil.Problem(
      service: "appview.example",
      reason: tranquil.Unreachable,
    ))
}

pub fn an_appviews_handle_is_judged_against_the_servers_test() {
  let assert Ok(noor) = handle.from_string("noor.harbor.example")
  let assert Ok(former) = handle.from_string("noor.cove.example")

  assert appview.handle_fact(Resolved(handle: noor), noor)
    == Fact(mark: Confirms, state: "up to date", aside: None)
  assert appview.handle_fact(Resolved(handle: former), noor)
    == Fact(
      mark: Contradicts,
      state: "out of date",
      aside: Some("@noor.cove.example"),
    )
  assert appview.handle_fact(Unresolved, noor)
    == Fact(
      mark: Contradicts,
      state: "not resolved",
      aside: Some("handle.invalid"),
    )
}

pub fn an_appviews_profile_is_judged_against_the_record_test() {
  let record =
    Profile(
      name: Some("Noor"),
      description: None,
      avatar: Some("bafkreiavatar"),
      banner: Some("bafkreibanner"),
    )
  let current =
    Profile(
      ..record,
      avatar: Some("https://cdn.example/avatar/bafkreiavatar@jpeg"),
      banner: Some("https://cdn.example/banner/bafkreibanner@jpeg"),
    )
  let nothing =
    Profile(name: None, description: None, avatar: None, banner: None)

  assert appview.profile_fact(current, Some(record))
    == Fact(mark: Confirms, state: "up to date", aside: None)
  assert appview.profile_fact(Profile(..current, avatar: None), Some(record))
    == Fact(mark: Contradicts, state: "out of date", aside: Some("avatar"))
  assert appview.profile_fact(nothing, Some(record))
    == Fact(
      mark: Contradicts,
      state: "out of date",
      aside: Some("name, avatar, banner"),
    )
  assert appview.profile_fact(nothing, None)
    == Fact(mark: Silent, state: "no profile record", aside: None)
}
