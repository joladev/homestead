import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub type Tone {
  Plain
  Warning
  Past
}

pub fn page(sections: List(Element(message))) -> Element(message) {
  html.main([attribute.class("page")], sections)
}

pub fn title_section(
  prompt: String,
  content: List(Element(message)),
) -> Element(message) {
  title_section_with_actions(prompt, [], content)
}

pub fn title_section_with_actions(
  prompt: String,
  actions: List(Element(message)),
  content: List(Element(message)),
) -> Element(message) {
  html.section([], [
    heading(html.h1([attribute.class("prompt")], [html.text(prompt)]), actions),
    ..content
  ])
}

pub fn section(
  prompt: String,
  content: List(Element(message)),
) -> Element(message) {
  section_with_actions(prompt, [], content)
}

pub fn section_with_actions(
  prompt: String,
  actions: List(Element(message)),
  content: List(Element(message)),
) -> Element(message) {
  html.section([], [
    heading(html.h2([attribute.class("prompt")], [html.text(prompt)]), actions),
    ..content
  ])
}

pub fn path_section(
  path: List(Element(message)),
  content: List(Element(message)),
) -> Element(message) {
  path_section_with_actions(path, [], content)
}

pub fn path_section_with_actions(
  path: List(Element(message)),
  actions: List(Element(message)),
  content: List(Element(message)),
) -> Element(message) {
  html.section([], [
    heading(
      html.h1(
        [attribute.class("prompt path")],
        list.intersperse(path, html.text(" / ")),
      ),
      actions,
    ),
    ..content
  ])
}

fn heading(
  title: Element(message),
  actions: List(Element(message)),
) -> Element(message) {
  case actions {
    [] -> title
    [_, ..] ->
      html.div([attribute.class("heading")], [
        title,
        html.div([attribute.class("actions")], actions),
      ])
  }
}

pub fn loading(rows: Int) -> Element(message) {
  html.div(
    [
      attribute.class("loading"),
      attribute.role("status"),
      attribute.aria_label("Loading"),
    ],
    list.repeat(
      html.div([attribute.class("row skeleton"), attribute.aria_hidden(True)], [
        html.span([attribute.class("bar label")], []),
        html.span([attribute.class("bar details")], []),
      ]),
      rows,
    ),
  )
}

pub fn loading_section() -> Element(message) {
  html.section([], [
    html.div([attribute.class("loading heading")], [
      html.span([attribute.class("bar")], []),
    ]),
    block([loading(3)]),
  ])
}

pub fn pending() -> Element(message) {
  html.span(
    [
      attribute.class("loading"),
      attribute.role("status"),
      attribute.aria_label("Loading"),
    ],
    [html.span([attribute.class("bar pending")], [])],
  )
}

pub fn block(rows: List(Element(message))) -> Element(message) {
  html.div([attribute.class("block")], rows)
}

pub fn row(
  tone tone: Tone,
  name name: String,
  details details: List(Element(message)),
  actions actions: List(Element(message)),
) -> Element(message) {
  html.div([attribute.class("row"), tone_class(tone)], [
    html.strong([], [html.text(name)]),
    html.span([attribute.class("details")], details),
    html.div([attribute.class("actions")], actions),
  ])
}

pub fn linked_row(
  to to: Attribute(message),
  name name: String,
  details details: List(Element(message)),
) -> Element(message) {
  html.div([attribute.class("row")], [
    html.a([attribute.class("name"), to], [html.text(name)]),
    html.span([attribute.class("details")], details),
  ])
}

pub fn copy_row(
  name name: String,
  value value: String,
  note note: Option(String),
  on_copy on_copy: message,
) -> Element(message) {
  row(
    tone: Plain,
    name:,
    details: [
      html.code([attribute.class("long")], [html.text(value)]),
      case note {
        Some(note) -> dim(" " <> note)
        None -> element.none()
      },
    ],
    actions: [
      html.button(
        [
          attribute.class("action"),
          attribute.type_("button"),
          event.on_click(on_copy),
        ],
        [html.text("Copy")],
      ),
    ],
  )
}

pub fn wide_row(content: List(Element(message))) -> Element(message) {
  html.div([attribute.class("row wide")], [
    html.span([attribute.class("details")], content),
  ])
}

pub fn full_row(content: List(Element(message))) -> Element(message) {
  html.div([attribute.class("row full")], [
    html.span([attribute.class("details")], content),
  ])
}

pub fn details_row(details: List(Element(message))) -> Element(message) {
  html.div([attribute.class("row")], [
    html.span([attribute.class("details")], details),
  ])
}

pub fn hint(
  details details: List(Element(message)),
  actions actions: List(Element(message)),
) -> Element(message) {
  html.div([attribute.class("row")], [
    html.span([attribute.class("details")], details),
    html.div([attribute.class("actions")], actions),
  ])
}

pub fn note(text: String, actions: List(Element(message))) -> Element(message) {
  html.div([attribute.class("row note")], [
    html.span([attribute.class("details")], [html.text(text)]),
    html.div([attribute.class("actions")], actions),
  ])
}

pub fn listing(
  empty empty: String,
  rows rows: List(Element(message)),
  actions actions: List(Element(message)),
) -> List(Element(message)) {
  case rows, actions {
    [], _ -> [note(empty, actions)]
    [_, ..], [] -> rows
    [_, ..], [_, ..] -> list.append(rows, [actions_row(actions)])
  }
}

pub fn actions_row(actions: List(Element(message))) -> Element(message) {
  html.div([attribute.class("row")], [
    html.div([attribute.class("actions")], actions),
  ])
}

pub fn field(
  label: Element(message),
  control: Element(message),
) -> Element(message) {
  html.div([attribute.class("row form-row")], [
    label,
    html.div([attribute.class("details")], [control]),
  ])
}

pub fn name_form(
  id id: String,
  name name: String,
  is_saving is_saving: Bool,
  on_input on_input: fn(String) -> message,
  on_submit on_submit: message,
  on_cancel on_cancel: message,
) -> Element(message) {
  html.form([event.on_submit(fn(_) { on_submit })], [
    html.div([attribute.class("row")], [
      html.label([attribute.for(id)], [html.text("Name")]),
      html.div([attribute.class("details")], [
        html.input([
          attribute.id(id),
          attribute.type_("text"),
          attribute.value(name),
          attribute.autocomplete("off"),
          attribute.disabled(is_saving),
          event.on_input(on_input),
        ]),
      ]),
      html.div([attribute.class("actions")], [
        html.button(
          [
            attribute.class("action"),
            attribute.type_("button"),
            event.on_click(on_cancel),
          ],
          [html.text("Cancel")],
        ),
        html.button(
          [
            attribute.class("action primary"),
            attribute.disabled(is_saving || string.trim(name) == ""),
          ],
          [html.text("Save")],
        ),
      ]),
    ]),
  ])
}

pub fn choice(
  id id: String,
  label label: String,
  options options: List(#(String, String)),
  picked picked: String,
  is_disabled is_disabled: Bool,
  on_pick on_pick: fn(String) -> message,
) -> Element(message) {
  html.div(
    [
      attribute.class("choices"),
      attribute.role("group"),
      attribute.aria_label(label),
    ],
    list.map(options, fn(option) {
      let #(value, text) = option

      html.button(
        [
          attribute.id(choice_id(id, value)),
          attribute.class("choice"),
          attribute.type_("button"),
          attribute.aria_pressed(case value == picked {
            True -> "true"
            False -> "false"
          }),
          attribute.disabled(is_disabled),
          event.on_click(on_pick(value)),
        ],
        [html.text(text)],
      )
    }),
  )
}

pub fn select(
  id id: String,
  label label: String,
  options options: List(#(String, String)),
  picked picked: String,
  is_disabled is_disabled: Bool,
  on_pick on_pick: fn(String) -> message,
) -> Element(message) {
  html.select(
    [
      attribute.id(id),
      attribute.aria_label(label),
      attribute.disabled(is_disabled),
      event.on_change(on_pick),
    ],
    list.map(options, fn(option) {
      let #(value, text) = option

      html.option(
        [attribute.value(value), attribute.selected(value == picked)],
        text,
      )
    }),
  )
}

pub fn choice_id(id: String, value: String) -> String {
  id <> "-" <> value
}

pub fn switch(
  id id: String,
  label label: String,
  is_on is_on: Bool,
  is_disabled is_disabled: Bool,
  on_pick on_pick: fn(Bool) -> message,
) -> Element(message) {
  choice(
    id:,
    label:,
    options: [#(switch_value(True), "On"), #(switch_value(False), "Off")],
    picked: switch_value(is_on),
    is_disabled:,
    on_pick: fn(value) { on_pick(value == switch_value(True)) },
  )
}

pub fn switch_choice_id(id: String, value: Bool) -> String {
  choice_id(id, switch_value(value))
}

fn switch_value(is_on: Bool) -> String {
  case is_on {
    True -> "on"
    False -> "off"
  }
}

pub fn problem(text: String) -> Element(message) {
  row(tone: Warning, name: "error", details: [html.text(text)], actions: [])
}

pub fn dim(text: String) -> Element(message) {
  html.span([attribute.class("dim")], [html.text(text)])
}

fn tone_class(tone: Tone) -> Attribute(message) {
  case tone {
    Plain -> attribute.none()
    Warning -> attribute.class("warning")
    Past -> attribute.class("past")
  }
}
