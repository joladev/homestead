import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import homestead/date

pub type History {
  History(events: List(Event), rotation_keys: List(String))
}

pub type Event {
  Event(at: Timestamp, is_cancelled: Bool, changes: List(Change))
}

pub type Change {
  Created(handle: Option(String), server: Option(String))
  HandleChanged(to: Option(String))
  ServerChanged(to: Option(String))
  SigningKeyChanged
  RotationKeyAdded(key: String)
  RotationKeyRemoved(key: String)
  Deleted
  OtherDetailsChanged
}

type Entry {
  Entry(
    cid: String,
    previous: Option(String),
    at: Timestamp,
    is_cancelled: Bool,
    state: State,
  )
}

type State {
  Active(
    handle: Option(String),
    server: Option(String),
    signing_key: Option(String),
    rotation_keys: List(String),
  )
  Tombstone
}

pub fn read(body: String) -> Result(History, Nil) {
  use entries <- result.try(
    json.parse(body, decode.list(entry_decoder()))
    |> result.replace_error(Nil),
  )
  let states =
    dict.from_list(list.map(entries, fn(entry) { #(entry.cid, entry.state) }))
  let rotation_keys = case
    list.last(list.filter(entries, fn(entry) { !entry.is_cancelled }))
  {
    Ok(Entry(state: Active(rotation_keys:, ..), ..)) -> rotation_keys
    Ok(Entry(state: Tombstone, ..)) | Error(Nil) -> []
  }
  use events <- result.map(
    list.try_map(entries, fn(entry) {
      use previous <- result.map(case entry.previous {
        Some(cid) -> dict.get(states, cid) |> result.map(Some)
        None -> Ok(None)
      })

      Event(
        at: entry.at,
        is_cancelled: entry.is_cancelled,
        changes: changes(previous, entry.state),
      )
    }),
  )

  History(events: list.reverse(events), rotation_keys:)
}

fn changes(previous: Option(State), state: State) -> List(Change) {
  case previous, state {
    _, Tombstone -> [Deleted]

    None, Active(handle:, server:, ..)
    | Some(Tombstone), Active(handle:, server:, ..)
    -> [Created(handle:, server:)]

    Some(Active(
      handle: old_handle,
      server: old_server,
      signing_key: old_signing_key,
      rotation_keys: old_rotation_keys,
    )),
      Active(handle:, server:, signing_key:, rotation_keys:)
    -> {
      let found =
        list.flatten([
          case handle == old_handle {
            True -> []
            False -> [HandleChanged(to: handle)]
          },
          case server == old_server {
            True -> []
            False -> [ServerChanged(to: server)]
          },
          case signing_key == old_signing_key {
            True -> []
            False -> [SigningKeyChanged]
          },
          rotation_keys
            |> list.filter(fn(key) { !list.contains(old_rotation_keys, key) })
            |> list.map(RotationKeyAdded),
          old_rotation_keys
            |> list.filter(fn(key) { !list.contains(rotation_keys, key) })
            |> list.map(RotationKeyRemoved),
        ])

      case found {
        [] -> [OtherDetailsChanged]
        [_, ..] -> found
      }
    }
  }
}

fn entry_decoder() -> Decoder(Entry) {
  use cid <- decode.field("cid", decode.string)
  use is_cancelled <- decode.field("nullified", decode.bool)
  use at <- decode.field("createdAt", date.decoder())
  use previous <- decode.subfield(
    ["operation", "prev"],
    decode.optional(decode.string),
  )
  use state <- decode.field("operation", state_decoder())

  decode.success(Entry(cid:, previous:, at:, is_cancelled:, state:))
}

fn state_decoder() -> Decoder(State) {
  use kind <- decode.field("type", decode.string)

  case kind {
    "plc_operation" -> {
      use names <- decode.field("alsoKnownAs", decode.list(decode.string))
      use server <- decode.then(decode.optionally_at(
        ["services", "atproto_pds", "endpoint"],
        None,
        decode.map(decode.string, Some),
      ))
      use signing_key <- decode.then(decode.optionally_at(
        ["verificationMethods", "atproto"],
        None,
        decode.map(decode.string, Some),
      ))
      use rotation_keys <- decode.field(
        "rotationKeys",
        decode.list(decode.string),
      )
      let handle =
        list.find_map(names, fn(name) {
          case name {
            "at://" <> handle -> Ok(handle)
            _ -> Error(Nil)
          }
        })

      decode.success(Active(
        handle: option.from_result(handle),
        server:,
        signing_key:,
        rotation_keys:,
      ))
    }

    "create" -> {
      use handle <- decode.field("handle", decode.string)
      use server <- decode.field("service", decode.string)
      use signing_key <- decode.field("signingKey", decode.string)
      use recovery_key <- decode.field("recoveryKey", decode.string)

      decode.success(
        Active(
          handle: Some(handle),
          server: Some(server),
          signing_key: Some(signing_key),
          rotation_keys: [recovery_key, signing_key],
        ),
      )
    }

    "plc_tombstone" -> decode.success(Tombstone)

    _ -> decode.failure(Tombstone, "Operation")
  }
}
