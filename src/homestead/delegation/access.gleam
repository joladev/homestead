import gleam/list
import homestead/layout
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/tranquil.{type AccessLevel}
import lustre/element.{type Element}

pub fn describe(levels: Remote(List(AccessLevel)), scopes: String) -> String {
  let levels = case levels {
    Loaded(value: levels) -> levels
    Loading | Failed(_) -> []
  }

  case list.find(levels, fn(level) { level.scopes == scopes }) {
    Ok(level) -> level.label
    Error(Nil) -> "Custom"
  }
}

pub fn first(levels: Remote(List(AccessLevel))) -> String {
  case levels {
    Loaded(value: [level, ..]) -> level.name
    Loaded(value: []) | Loading | Failed(_) -> ""
  }
}

pub fn scopes(levels: Remote(List(AccessLevel)), name: String) -> String {
  case levels {
    Loaded(value: levels) ->
      case list.find(levels, fn(level) { level.name == name }) {
        Ok(level) -> level.scopes
        Error(Nil) -> ""
      }
    Loading | Failed(_) -> ""
  }
}

pub fn view_choice(
  id id: String,
  levels levels: Remote(List(AccessLevel)),
  picked picked: String,
  is_disabled is_disabled: Bool,
  on_pick on_pick: fn(String) -> message,
) -> Element(message) {
  layout.choice(
    id:,
    label: "Access",
    options: case levels {
      Loaded(value: levels) ->
        list.map(levels, fn(level) { #(level.name, level.label) })
      Loading | Failed(_) -> []
    },
    picked:,
    is_disabled:,
    on_pick:,
  )
}
