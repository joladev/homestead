import at/handle
import gleam/http/response
import gleam/option.{None, Some}
import homestead/appview.{
  Avatar, Banner, Deactivated, Found, Name, NotFound, Profile, Resolved,
  TakenDown, Unresolved,
}
import homestead/remote.{Failed, Loaded}
import homestead/tranquil.{ProfileRecord}
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
  let read = appview.read_profile(_, from: "appview.example")

  assert read(answered(200, found))
    == Loaded(
      Found(profile: Profile(
        handle: Resolved(handle: noor),
        name: Some("Noor"),
        description: None,
        avatar: Some(
          "https://cdn.example/img/avatar/plain/did:plc:k4q7m2x3vt5hwz6r2ypbn7cs/bafkreiavatar@jpeg",
        ),
        banner: None,
      )),
    )
  assert read(answered(200, unresolved))
    == Loaded(
      Found(profile: Profile(
        handle: Unresolved,
        name: None,
        description: None,
        avatar: None,
        banner: None,
      )),
    )
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

pub fn an_appviews_copy_is_compared_with_the_profile_record_test() {
  let record =
    ProfileRecord(
      name: Some("Noor"),
      description: None,
      avatar: Some("bafkreiavatar"),
      banner: Some("bafkreibanner"),
    )
  let current =
    Profile(
      handle: Unresolved,
      name: Some("Noor"),
      description: None,
      avatar: Some("https://cdn.example/avatar/bafkreiavatar@jpeg"),
      banner: Some("https://cdn.example/banner/bafkreibanner@jpeg"),
    )
  let empty = Profile(..current, name: None, avatar: None, banner: None)

  assert appview.stale_fields(Some(record), current) == []
  assert appview.stale_fields(Some(record), Profile(..current, avatar: None))
    == [Avatar]
  assert appview.stale_fields(Some(record), empty) == [Name, Avatar, Banner]
  assert appview.stale_fields(None, empty) == []
  assert appview.stale_fields(None, current) == [Name, Avatar, Banner]
}
