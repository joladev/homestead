import at/handle
import gleam/http/response
import gleam/option.{None, Some}
import homestead/appview.{
  Deactivated, HandleUnresolved, Known, NotFound, TakenDown, Verdict,
}
import homestead/layout.{Confirms, Contradicts}
import homestead/remote.{Failed, Loaded}
import homestead/tranquil.{Account, Email}
import rsvp

fn answered(status: Int, body: String) {
  Ok(response.new(status) |> response.set_body(body))
}

pub fn an_appview_says_what_it_has_for_the_account_test() {
  let assert Ok(noor) = handle.from_string("noor.harbor.example")
  let known =
    "{\"did\":\"did:plc:k4q7m2x3vt5hwz6r2ypbn7cs\",\"handle\":\"noor.harbor.example\"}"
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

  assert read(answered(200, known)) == Loaded(Known(handle: noor))
  assert read(answered(200, unresolved)) == Loaded(HandleUnresolved)
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

pub fn an_appview_is_judged_against_the_accounts_handle_test() {
  let assert Ok(noor) = handle.from_string("noor.harbor.example")
  let assert Ok(former) = handle.from_string("noor.cove.example")
  let account =
    Account(
      handle: noor,
      email: None,
      email_verified: False,
      contact_channel: Email,
      contact_verified: False,
      is_admin: False,
      is_active: True,
    )
  let judge = appview.verdict(_, account, from: "appview.example")

  assert judge(Known(handle: noor))
    == Verdict(
      mark: Confirms,
      fact: "has this account as @noor.harbor.example",
      detail: None,
    )
  assert judge(Known(handle: former))
    == Verdict(
      mark: Contradicts,
      fact: "has another handle: @noor.cove.example",
      detail: None,
    )
  assert judge(NotFound)
    == Verdict(
      mark: Contradicts,
      fact: "account not found",
      detail: Some("appview.example answered \"Profile not found\"."),
    )
}
