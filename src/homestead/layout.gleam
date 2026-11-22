import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html

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
