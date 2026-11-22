import gleam/dynamic/decode
import homestead/browser
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub fn open(id: String) -> Effect(message) {
  browser.open_dialog(id)
}

pub fn view(
  id id: String,
  title title: String,
  on_cancel on_cancel: message,
  content content: List(Element(message)),
) -> Element(message) {
  html.dialog(
    [
      attribute.id(id),
      attribute.class("dialog"),
      attribute.aria_labelledby(id <> "-title"),
      event.on("cancel", decode.success(on_cancel)),
    ],
    [
      html.h2([attribute.id(id <> "-title"), attribute.class("prompt")], [
        html.text(title),
      ]),
      ..content
    ],
  )
}

pub fn field(
  id id: String,
  label label: String,
  control control: Element(message),
) -> Element(message) {
  html.div([attribute.class("dialog-field")], [
    html.label([attribute.for(id)], [html.text(label)]),
    control,
  ])
}

pub fn problem(text: String) -> Element(message) {
  html.p([attribute.class("dialog-problem"), attribute.role("alert")], [
    html.text(text),
  ])
}

pub fn actions(actions: List(Element(message))) -> Element(message) {
  html.div([attribute.class("dialog-actions")], actions)
}
