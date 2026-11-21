import gleam/int
import gleam/javascript/promise
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import homestead/browser
import homestead/confirmation
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Departure, type Session}
import homestead/tranquil.{type ActiveSession, type Problem}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub type Filter {
  Everything
  ThroughApps
}

pub opaque type Model {
  Model(
    session: Session,
    filter: Filter,
    local_offset: Duration,
    sessions: Remote(List(ActiveSession)),
    action: Action,
    has_signed_out: Bool,
  )
}

type Action {
  Idle
  Confirming(target: Target)
  Working
  Refused(problem: Problem)
}

type Target {
  OneSession(session: ActiveSession)
  OtherSessions
}

pub fn init(session: Session, filter: Filter) -> #(Model, Effect(Message)) {
  #(
    Model(
      session:,
      filter:,
      local_offset: calendar.local_offset(),
      sessions: Loading,
      action: Idle,
      has_signed_out: False,
    ),
    load(session),
  )
}

pub fn departure(model: Model) -> Option(Departure) {
  let has_ended_session =
    remote.has_ended_session(model.sessions)
    || model.action == Refused(tranquil.SessionEnded)

  case model.has_signed_out, has_ended_session {
    True, _ -> Some(session.SignedOut)
    False, True -> Some(session.Ended)
    False, False -> None
  }
}

pub opaque type Message {
  ServerReturnedSessions(result: Result(List(ActiveSession), Problem))
  UserClickedEnd(target: Target)
  UserCancelledEnd(target: Target)
  UserConfirmedEnd(target: Target)
  UserClickedSignOut
  ServerEndedSessions(result: Result(Nil, Problem))
  ServerSignedOut
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    ServerReturnedSessions(result:) -> #(
      Model(
        ..model,
        sessions: remote.from_result(result),
        action: case model.action {
          Working -> Idle
          Idle | Confirming(_) | Refused(_) -> model.action
        },
      ),
      effect.none(),
    )

    UserClickedEnd(target:) -> #(
      Model(..model, action: Confirming(target:)),
      confirmation.focus_cancel(),
    )

    UserCancelledEnd(target:) -> #(
      Model(..model, action: Idle),
      browser.focus(end_button_id(target)),
    )

    UserConfirmedEnd(target:) -> #(
      Model(..model, action: Working),
      tranquil.perform(
        model.session,
        case target {
          OneSession(session:) -> tranquil.end_session(session.id)
          OtherSessions -> tranquil.end_other_sessions()
        },
        ServerEndedSessions,
      ),
    )

    UserClickedSignOut -> #(
      Model(..model, action: Working),
      sign_out(model.session),
    )

    ServerEndedSessions(result: Ok(Nil)) -> #(model, load(model.session))

    ServerEndedSessions(result: Error(problem)) -> #(
      Model(..model, action: Refused(problem:)),
      effect.none(),
    )

    ServerSignedOut -> #(Model(..model, has_signed_out: True), effect.none())
  }
}

fn end_button_id(target: Target) -> String {
  case target {
    OneSession(session:) -> "end-" <> session.id
    OtherSessions -> "end-others"
  }
}

fn load(session: Session) -> Effect(Message) {
  tranquil.load(session, tranquil.sessions(), ServerReturnedSessions)
}

fn sign_out(session: Session) -> Effect(Message) {
  use dispatch <- effect.from

  session.end(session)
  |> promise.tap(fn(_) { dispatch(ServerSignedOut) })

  Nil
}

pub fn describe_date(timestamp: Timestamp, offset: Duration) -> String {
  let #(date, _) = timestamp.to_calendar(timestamp, offset)

  int.to_string(date.day)
  <> " "
  <> string.slice(calendar.month_to_string(date.month), 0, 3)
}

pub fn view(model: Model) -> Element(Message) {
  html.main([attribute.class("page")], [
    html.h1([attribute.class("prompt")], [html.text("sessions")]),
    view_list(model),
  ])
}

pub fn view_list(model: Model) -> Element(Message) {
  case model.sessions {
    Loading -> element.none()

    Failed(_) ->
      html.p([attribute.class("problem")], [html.text("Couldn't load")])

    Loaded(value: sessions) -> {
      let #(current, others) =
        sessions
        |> list.filter(fn(session) {
          model.filter == Everything || session.app != None
        })
        |> list.partition(fn(session) { session.is_current })
      let listed = list.append(current, others)

      element.fragment([
        case listed {
          [] -> html.p([], [html.text("none")])
          [_, ..] ->
            html.div(
              [attribute.class("rows")],
              list.append(list.map(listed, view_session(_, model)), [
                case model.action {
                  Confirming(target: OtherSessions) ->
                    confirmation.view(
                      question: "End all?",
                      consequence: "They will have to sign in again.",
                      accept: "End all sessions",
                      on_cancel: UserCancelledEnd(OtherSessions),
                      on_accept: UserConfirmedEnd(OtherSessions),
                    )
                  Confirming(target: OneSession(_))
                  | Idle
                  | Working
                  | Refused(_) -> element.none()
                },
              ]),
            )
        },
        case model.filter, listed, model.action {
          Everything, [_, _, ..], Idle
          | Everything, [_, _, ..], Working
          | Everything, [_, _, ..], Refused(_)
          | Everything, [_, _, ..], Confirming(target: OneSession(_))
          ->
            html.p([attribute.class("below-rows")], [
              html.button(
                [
                  attribute.id(end_button_id(OtherSessions)),
                  attribute.class("action"),
                  attribute.disabled(model.action == Working),
                  event.on_click(UserClickedEnd(OtherSessions)),
                ],
                [html.text("End all sessions")],
              ),
            ])
          Everything, [_, _, ..], Confirming(target: OtherSessions)
          | Everything, [], _
          | Everything, [_], _
          | ThroughApps, _, _
          -> element.none()
        },
        case model.action {
          Refused(_) ->
            html.p([attribute.class("problem")], [
              html.text("The server didn't end that"),
            ])
          Idle | Confirming(_) | Working -> element.none()
        },
      ])
    }
  }
}

fn view_session(session: ActiveSession, model: Model) -> Element(Message) {
  let target = OneSession(session:)
  let name = option.unwrap(session.app, "password sign-in")
  let kind = case session.is_current, session.app {
    True, _ -> "This session"
    False, Some(_) -> "App"
    False, None -> "Direct"
  }

  case model.action == Confirming(target:) {
    True ->
      confirmation.view(
        question: "End?",
        consequence: name <> " will have to sign in again.",
        accept: "End session",
        on_cancel: UserCancelledEnd(target),
        on_accept: UserConfirmedEnd(target),
      )

    False ->
      html.div([attribute.class("row")], [
        case model.filter {
          Everything -> html.strong([], [html.text(kind)])
          ThroughApps -> element.none()
        },
        html.span([], [html.text(name)]),
        html.time([], [
          html.text(
            "since " <> describe_date(session.created, model.local_offset),
          ),
        ]),
        html.time([], [
          html.text(
            "expires " <> describe_date(session.expires, model.local_offset),
          ),
        ]),
        case session.is_current {
          True ->
            html.button(
              [
                attribute.class("action"),
                attribute.disabled(model.action == Working),
                event.on_click(UserClickedSignOut),
              ],
              [html.text("Sign out")],
            )
          False ->
            html.button(
              [
                attribute.id(end_button_id(target)),
                attribute.class("action"),
                attribute.disabled(model.action == Working),
                event.on_click(UserClickedEnd(target)),
              ],
              [html.text("End")],
            )
        },
      ])
  }
}
