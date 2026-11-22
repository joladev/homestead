import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import homestead/read_only

pub type Preset {
  FullAccess
  ReadOnly
  PostOnly
}

pub const presets = [FullAccess, ReadOnly, PostOnly]

const granted_for_full_access = "transition:generic transition:chat.bsky"

pub fn label(preset: Preset) -> String {
  case preset {
    FullAccess -> "Full access"
    ReadOnly -> "Read only"
    PostOnly -> "Post only"
  }
}

pub fn scopes(preset: Preset) -> Option(String) {
  case preset {
    FullAccess -> None
    PostOnly -> Some("atproto repo:app.bsky.feed.post?action=create blob:*/*")
    ReadOnly -> {
      let methods =
        read_only.methods
        |> list.map(fn(method) { "lxm=" <> method })
        |> string.join("&")

      Some("atproto rpc?" <> methods <> "&aud=* account:status")
    }
  }
}

pub fn describe(granted: Option(String)) -> String {
  let matching =
    list.find(presets, fn(preset) {
      case granted, scopes(preset) {
        None, None -> True
        Some(granted), None -> same(granted, granted_for_full_access)
        Some(granted), Some(preset) -> same(granted, preset)
        None, Some(_) -> False
      }
    })

  case matching {
    Ok(preset) -> label(preset)
    Error(Nil) -> "Custom"
  }
}

fn same(one: String, other: String) -> Bool {
  beyond_the_baseline(one) == beyond_the_baseline(other)
}

fn beyond_the_baseline(scopes: String) -> Set(String) {
  set.from_list(string.split(scopes, " ")) |> set.delete("atproto")
}
