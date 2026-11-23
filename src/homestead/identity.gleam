import at/did.{type Did}
import at/handle.{type Handle}
import gleam/http/request.{type Request}
import gleam/option.{type Option, None, Some}

pub fn name(account: Did, handle: Option(Handle)) -> String {
  case handle {
    Some(handle) -> handle.to_string(handle)
    None -> did.to_string(account)
  }
}

pub fn document_request(
  directory: Request(String),
  did: Did,
) -> Request(String) {
  case did.method(did) {
    did.Plc ->
      directory
      |> request.set_path("/" <> did.to_string(did))
      |> request.set_header("accept", "application/json")
    did.Web -> did.document_request(did)
  }
}

pub fn history_request(
  directory: Request(String),
  did: Did,
) -> Result(Request(String), Nil) {
  case did.method(did) {
    did.Plc ->
      directory
      |> request.set_path("/" <> did.to_string(did) <> "/log/audit")
      |> request.set_header("accept", "application/json")
      |> Ok
    did.Web -> Error(Nil)
  }
}
