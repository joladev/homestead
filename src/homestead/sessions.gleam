import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import homestead/browser
import homestead/confirmation
import homestead/date
import homestead/layout
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
  case model.has_signed_out {
    True -> Some(session.SignedOut)
    False -> None
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
  browser.await(fn() { session.end(session) }, fn(_) { ServerSignedOut })
}

pub fn view(model: Model) -> Element(Message) {
  layout.page([layout.title_section("sessions", [view_list(model)])])
}

pub fn view_list(model: Model) -> Element(Message) {
  case model.sessions {
    Loading -> layout.block([layout.loading(3)])

    Failed(_) -> layout.block([layout.problem("Couldn't load")])

    Loaded(value: sessions) -> {
      let #(current, others) =
        sessions
        |> list.filter(fn(session) {
          model.filter == Everything || session.app != None
        })
        |> list.partition(fn(session) { session.is_current })
      let listed = list.append(current, others)

      layout.block(
        list.flatten([
          case listed {
            [] -> [
              layout.note(
                case model.filter {
                  Everything -> "No sessions"
                  ThroughApps -> "No connected apps"
                },
                [],
              ),
            ]
            [_, ..] -> list.map(listed, view_session(_, model))
          },
          case model.filter, listed, model.action {
            Everything, [_, _, ..], Confirming(target: OtherSessions) -> [
              confirmation.view(
                question: "End all?",
                consequence: "They will have to sign in again.",
                accept: "End all sessions",
                on_cancel: UserCancelledEnd(OtherSessions),
                on_accept: UserConfirmedEnd(OtherSessions),
              ),
            ]
            Everything, [_, _, ..], Idle
            | Everything, [_, _, ..], Working
            | Everything, [_, _, ..], Refused(_)
            | Everything, [_, _, ..], Confirming(target: OneSession(_))
            -> [
              layout.actions_row([
                html.button(
                  [
                    attribute.id(end_button_id(OtherSessions)),
                    attribute.class("action"),
                    attribute.disabled(model.action == Working),
                    event.on_click(UserClickedEnd(OtherSessions)),
                  ],
                  [html.text("End all sessions")],
                ),
              ]),
            ]
            Everything, [], _ | Everything, [_], _ | ThroughApps, _, _ -> []
          },
          case model.action {
            Refused(_) -> [layout.problem("The server didn't end that")]
            Idle | Confirming(_) | Working -> []
          },
        ]),
      )
    }
  }
}

fn view_session(session: ActiveSession, model: Model) -> Element(Message) {
  let target = OneSession(session:)
  let name = option.unwrap(session.app, "Password sign-in")
  let dates =
    "since "
    <> date.describe(session.created, model.local_offset)
    <> " \u{00B7} expires "
    <> date.describe(session.expires, model.local_offset)
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
      layout.row(
        tone: layout.Plain,
        name:,
        details: case model.filter {
          Everything -> [
            html.text(kind <> " "),
            layout.dim("\u{00B7} " <> dates),
          ]
          ThroughApps -> [layout.dim(dates)]
        },
        actions: [
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
        ],
      )
  }
}
