import gleam/list
import gleam/string
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub type Tone {
  Plain
  Warning
}

pub fn page(sections: List(Element(message))) -> Element(message) {
  html.main([attribute.class("page")], sections)
}

pub fn title_section(
  prompt: String,
  content: List(Element(message)),
) -> Element(message) {
  html.section([], [
    html.h1([attribute.class("prompt")], [html.text(prompt)]),
    ..content
  ])
}

pub fn section(
  prompt: String,
  content: List(Element(message)),
) -> Element(message) {
  html.section([], [
    html.h2([attribute.class("prompt")], [html.text(prompt)]),
    ..content
  ])
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

pub fn switch(
  id id: String,
  label label: String,
  is_on is_on: Bool,
  is_disabled is_disabled: Bool,
  on_pick on_pick: fn(Bool) -> message,
) -> Element(message) {
  html.div(
    [
      attribute.class("choices"),
      attribute.role("group"),
      attribute.aria_label(label),
    ],
    list.map([#("On", True), #("Off", False)], fn(choice) {
      let #(text, value) = choice

      html.button(
        [
          attribute.id(switch_choice_id(id, value)),
          attribute.class("choice"),
          attribute.type_("button"),
          attribute.aria_pressed(case value == is_on {
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

pub fn switch_choice_id(id: String, value: Bool) -> String {
  case value {
    True -> id <> "-on"
    False -> id <> "-off"
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
  }
}
