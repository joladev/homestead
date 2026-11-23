import homestead/browser
import homestead/confirmation
import homestead/layout
import homestead/remote.{type Remote, Loaded, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{type Problem}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

const link_button_id = "link-signal"

const unlink_button_id = "unlink-signal"

const check_every_milliseconds = 2000

const checks_before_giving_up = 65

pub opaque type Model {
  Model(session: Session, is_linked: Remote(Bool), action: Action)
}

type Action {
  Resting
  Preparing
  Scanning(qr_image: String, checks_left: Int)
  TimedOut
  ConfirmingUnlink
  Unlinking
  Refused(problem: Problem)
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  #(
    Model(session:, is_linked: Loading, action: Resting),
    tranquil.load(session, tranquil.signal_linked(), ServerReturnedStatus),
  )
}

pub opaque type Message {
  ServerReturnedStatus(result: Result(Bool, Problem))
  UserClickedLink
  ServerPreparedLink(result: Result(String, Problem))
  TimerElapsed
  ServerCheckedLink(result: Result(Bool, Problem))
  UserCancelledLink
  UserClickedUnlink
  UserCancelledUnlink
  UserConfirmedUnlink
  ServerUnlinked(result: Result(Nil, Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  let session = model.session

  case message, model.action {
    ServerReturnedStatus(result:), _ -> #(
      Model(..model, is_linked: remote.from_result(result)),
      effect.none(),
    )

    UserClickedLink, _ -> #(
      Model(..model, action: Preparing),
      tranquil.perform(session, tranquil.link_signal(), ServerPreparedLink),
    )

    ServerPreparedLink(result: Ok(qr_image)), _ -> #(
      Model(
        ..model,
        action: Scanning(qr_image:, checks_left: checks_before_giving_up),
      ),
      wait(),
    )

    ServerPreparedLink(result: Error(problem)), _ -> #(
      Model(..model, action: Refused(problem:)),
      effect.none(),
    )

    TimerElapsed, Scanning(..) -> #(
      model,
      tranquil.load(session, tranquil.signal_linked(), ServerCheckedLink),
    )

    ServerCheckedLink(result: Ok(True)), Scanning(..) -> #(
      Model(..model, is_linked: Loaded(True), action: Resting),
      effect.none(),
    )

    ServerCheckedLink(_), Scanning(checks_left: 1, ..) -> #(
      Model(..model, action: TimedOut),
      effect.none(),
    )

    ServerCheckedLink(_), Scanning(qr_image:, checks_left:) -> #(
      Model(..model, action: Scanning(qr_image:, checks_left: checks_left - 1)),
      wait(),
    )

    UserCancelledLink, _ -> #(
      Model(..model, action: Resting),
      browser.focus(link_button_id),
    )

    UserClickedUnlink, _ -> #(
      Model(..model, action: ConfirmingUnlink),
      confirmation.focus_cancel(),
    )

    UserCancelledUnlink, _ -> #(
      Model(..model, action: Resting),
      browser.focus(unlink_button_id),
    )

    UserConfirmedUnlink, _ -> #(
      Model(..model, action: Unlinking),
      tranquil.perform(session, tranquil.unlink_signal(), ServerUnlinked),
    )

    ServerUnlinked(result: Ok(Nil)), _ -> #(
      Model(..model, is_linked: Loaded(False), action: Resting),
      effect.none(),
    )

    ServerUnlinked(result: Error(problem)), _ -> #(
      Model(..model, action: Refused(problem:)),
      effect.none(),
    )

    TimerElapsed, _ | ServerCheckedLink(_), _ -> #(model, effect.none())
  }
}

fn wait() -> Effect(Message) {
  browser.after(check_every_milliseconds, TimerElapsed)
}

pub fn describe_refusal(problem: Problem) -> String {
  case problem {
    tranquil.Refused("InvalidRequest", message) if message != "" -> message
    tranquil.Refused(_, _) | tranquil.Unreachable | tranquil.NotUnderstood ->
      tranquil.describe(problem)
  }
}

pub fn view(model: Model) -> List(Element(Message)) {
  let status = {
    use is_linked <- layout.awaited_row(name: "Signal", of: model.is_linked)

    view_status(is_linked, model.action)
  }

  [
    layout.block(case model.action {
      Scanning(qr_image:, ..) -> [
        layout.row(
          tone: layout.Plain,
          name: "Scan",
          details: [
            html.img([
              attribute.class("qr"),
              attribute.src("data:image/png;base64," <> qr_image),
              attribute.alt("QR code to link Signal"),
            ]),
            layout.dim("with Signal on your phone, under Linked devices"),
          ],
          actions: [
            html.button(
              [attribute.class("action"), event.on_click(UserCancelledLink)],
              [html.text("Cancel")],
            ),
          ],
        ),
      ]

      ConfirmingUnlink -> [
        confirmation.view(
          question: "Unlink?",
          consequence: "Messages over Signal stop.",
          accept: "Unlink Signal",
          on_cancel: UserCancelledUnlink,
          on_accept: UserConfirmedUnlink,
        ),
      ]

      TimedOut -> [status, layout.problem("Linking timed out")]

      Refused(problem:) -> [status, layout.problem(describe_refusal(problem))]

      Resting | Preparing | Unlinking -> [status]
    }),
  ]
}

fn view_status(is_linked: Bool, action: Action) -> Element(Message) {
  let is_busy = case action {
    Preparing | Unlinking -> True
    Resting | Scanning(..) | TimedOut | ConfirmingUnlink | Refused(_) -> False
  }

  layout.row(
    tone: layout.Plain,
    name: "Signal",
    details: [
      html.text(case is_linked {
        True -> "linked"
        False -> "not linked"
      }),
    ],
    actions: [
      case is_linked {
        True ->
          html.button(
            [
              attribute.id(unlink_button_id),
              attribute.class("action"),
              attribute.disabled(is_busy),
              event.on_click(UserClickedUnlink),
            ],
            [html.text("Unlink")],
          )
        False ->
          html.button(
            [
              attribute.id(link_button_id),
              attribute.class("action"),
              attribute.disabled(is_busy),
              event.on_click(UserClickedLink),
            ],
            [html.text("Link device")],
          )
      },
    ],
  )
}
