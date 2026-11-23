import gleam/list
import homestead/layout
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/tranquil.{type AccessLevel}
import lustre/element.{type Element}
import lustre/element/html

pub fn view_level(
  levels: Remote(List(AccessLevel)),
  scopes: String,
) -> Element(message) {
  use levels <- layout.value(levels)

  html.text(case list.find(levels, fn(level) { level.scopes == scopes }) {
    Ok(level) -> level.label <> " "
    Error(Nil) -> "Custom "
  })
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
  use levels <- layout.value(levels)

  layout.choice(
    id:,
    label: "Access",
    options: list.map(levels, fn(level) { #(level.name, level.label) }),
    picked:,
    is_disabled:,
    on_pick:,
  )
}
