import at/did.{type Did}
import at/handle.{type Handle}
import gleam/dynamic/decode.{type Decoder}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import homestead/layout.{
  type Mark, Confirms, Contradicts, Plain, Silent, Warning,
}
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Session}
import homestead/setting.{type Settings}
import homestead/tranquil.{type Account, type Problem}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp

pub opaque type Model {
  Model(
    session: Session,
    settings: Settings,
    appviews: List(Appview),
    announcement: Announcement,
  )
}

type Appview {
  Appview(address: Request(String), standing: Remote(Standing))
}

pub type Standing {
  Known(handle: Handle)
  HandleUnresolved
  NotFound
  Deactivated
  TakenDown
}

pub type Verdict {
  Verdict(mark: Mark, fact: String, detail: Option(String))
}

type Announcement {
  NotAnnounced
  Announcing
  Announced
  AnnouncementRefused(problem: Problem)
}

pub fn init(session: Session, settings: Settings) -> #(Model, Effect(Message)) {
  let #(appviews, effect) = check(session, settings)

  #(Model(session:, settings:, appviews:, announcement: NotAnnounced), effect)
}

fn check(
  session: Session,
  settings: Settings,
) -> #(List(Appview), Effect(Message)) {
  let account = session.account(session)

  #(
    list.map(settings.appviews, fn(address) {
      Appview(address:, standing: Loading)
    }),
    effect.batch(
      list.map(settings.appviews, fn(address) {
        rsvp.send(
          profile_request(address, account),
          rsvp.expect_any_response(AppviewReturnedProfile(address, _)),
        )
      }),
    ),
  )
}

pub opaque type Message {
  AppviewReturnedProfile(
    appview: Request(String),
    result: Result(Response(String), rsvp.Error(String)),
  )
  UserClickedCheckAgain
  UserClickedReannounce
  ServerAnnouncedAccount(result: Result(Nil, Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    AppviewReturnedProfile(appview: address, result:) -> #(
      Model(
        ..model,
        appviews: list.map(model.appviews, fn(appview) {
          case appview.address == address {
            True ->
              Appview(
                ..appview,
                standing: read_profile(
                  result,
                  from: tranquil.server_name(address),
                ),
              )
            False -> appview
          }
        }),
      ),
      effect.none(),
    )

    UserClickedCheckAgain -> {
      let #(appviews, effect) = check(model.session, model.settings)

      #(Model(..model, appviews:), effect)
    }

    // `activateAccount` is a safe operation for an active account, and triggers
    // `identity`, `sync`, and `account` events to be published by the PDS,
    // which can then trigger third parties subscribing to those events to
    // update the account.
    UserClickedReannounce -> #(
      Model(..model, announcement: Announcing),
      tranquil.perform(
        model.session,
        tranquil.activate_account(),
        ServerAnnouncedAccount,
      ),
    )

    ServerAnnouncedAccount(result: Ok(Nil)) -> #(
      Model(..model, announcement: Announced),
      effect.none(),
    )

    ServerAnnouncedAccount(result: Error(problem)) -> #(
      Model(..model, announcement: AnnouncementRefused(problem:)),
      effect.none(),
    )
  }
}

pub fn profile_request(
  appview: Request(String),
  account: Did,
) -> Request(String) {
  appview
  |> request.set_path("/xrpc/app.bsky.actor.getProfile")
  |> request.set_query([#("actor", did.to_string(account))])
}

pub fn read_profile(
  result: Result(Response(String), rsvp.Error(String)),
  from appview: String,
) -> Remote(Standing) {
  case result {
    Ok(response) if response.status == 200 ->
      case json.parse(response.body, standing_decoder()) {
        Ok(standing) -> Loaded(value: standing)
        Error(_) ->
          Failed(tranquil.Problem(
            service: appview,
            reason: tranquil.NotUnderstood,
          ))
      }
    Ok(response) ->
      case json.parse(response.body, refusal_decoder()) {
        Ok(Refusal(error: "AccountDeactivated", ..)) ->
          Loaded(value: Deactivated)
        Ok(Refusal(error: "AccountTakedown", ..)) -> Loaded(value: TakenDown)
        Ok(Refusal(error: "InvalidRequest", message: "Profile not found")) ->
          Loaded(value: NotFound)
        Ok(Refusal(error:, message:)) ->
          Failed(tranquil.Problem(
            service: appview,
            reason: tranquil.Refused(error, message),
          ))
        Error(_) ->
          Failed(tranquil.Problem(
            service: appview,
            reason: tranquil.NotUnderstood,
          ))
      }
    Error(error) -> Failed(tranquil.error_to_problem(error, from: appview))
  }
}

fn standing_decoder() -> Decoder(Standing) {
  use name <- decode.field("handle", decode.string)

  case name, handle.from_string(name) {
    "handle.invalid", _ -> decode.success(HandleUnresolved)
    _, Ok(known) -> decode.success(Known(handle: known))
    _, Error(Nil) -> decode.failure(HandleUnresolved, "Handle")
  }
}

type Refusal {
  Refusal(error: String, message: String)
}

fn refusal_decoder() -> Decoder(Refusal) {
  use error <- decode.field("error", decode.string)
  use message <- decode.optional_field("message", "", decode.string)

  decode.success(Refusal(error:, message:))
}

pub fn verdict(
  standing: Standing,
  account: Account,
  from appview: String,
) -> Verdict {
  case standing, account.is_active {
    Known(handle: known), True if known == account.handle ->
      Verdict(
        mark: Confirms,
        fact: "has this account as @" <> handle.to_string(known),
        detail: None,
      )
    Known(handle: known), True ->
      Verdict(
        mark: Contradicts,
        fact: "has another handle: @" <> handle.to_string(known),
        detail: None,
      )
    Known(_), False ->
      Verdict(
        mark: Contradicts,
        fact: "shows the account as active",
        detail: None,
      )
    HandleUnresolved, True ->
      Verdict(
        mark: Contradicts,
        fact: "has the handle as invalid",
        detail: Some(
          appview <> " answers handle.invalid when it can't resolve the handle.",
        ),
      )
    HandleUnresolved, False ->
      Verdict(
        mark: Contradicts,
        fact: "shows the account as active",
        detail: None,
      )
    NotFound, True | NotFound, False ->
      Verdict(
        mark: Contradicts,
        fact: "account not found",
        detail: Some(appview <> " answered \"Profile not found\"."),
      )
    Deactivated, True ->
      Verdict(
        mark: Contradicts,
        fact: "shows the account as deactivated",
        detail: Some(appview <> " answered AccountDeactivated."),
      )
    Deactivated, False ->
      Verdict(
        mark: Confirms,
        fact: "shows the account as deactivated",
        detail: Some(appview <> " answered AccountDeactivated."),
      )
    TakenDown, True | TakenDown, False ->
      Verdict(
        mark: Contradicts,
        fact: "shows the account as taken down",
        detail: Some(appview <> " answered AccountTakedown."),
      )
  }
}

fn describe_failure(problem: Problem) -> String {
  case problem.reason {
    tranquil.Unreachable -> "couldn't reach " <> problem.service
    tranquil.Refused(error:, ..) -> problem.service <> " answered " <> error
    tranquil.NotUnderstood -> "couldn't read " <> problem.service <> "'s answer"
  }
}

fn describe_refusal(problem: Problem) -> String {
  "Couldn't re-announce: "
  <> case problem.reason {
    tranquil.Refused(_, message) if message != "" -> message
    tranquil.Refused(_, _) | tranquil.Unreachable | tranquil.NotUnderstood ->
      describe_failure(problem)
  }
}

pub fn view(model: Model, account: Remote(Account)) -> Element(Message) {
  layout.page([
    layout.title_section_with_actions(
      "appviews",
      [
        html.button(
          [
            attribute.class("action"),
            attribute.disabled(
              list.any(model.appviews, fn(appview) {
                appview.standing == Loading
              }),
            ),
            event.on_click(UserClickedCheckAgain),
          ],
          [html.text("Check again")],
        ),
      ],
      [
        layout.block(list.map(model.appviews, view_appview(_, account))),
        case account {
          Loaded(value: tranquil.Account(is_active: True, ..)) ->
            view_announcement(model.announcement, session.server(model.session))
          Loaded(value: tranquil.Account(is_active: False, ..))
          | Loading
          | Failed(_) -> element.none()
        },
      ],
    ),
  ])
}

fn view_appview(
  appview: Appview,
  account: Remote(Account),
) -> Element(Message) {
  let name = tranquil.server_name(appview.address)
  let verdict = {
    use standing <- remote.then(appview.standing)
    use account <- remote.map(account)

    verdict(standing, account, from: name)
  }

  case verdict {
    Loading ->
      layout.row(tone: Plain, name:, details: [layout.pending()], actions: [])

    Failed(problem:) ->
      layout.row(
        tone: Plain,
        name:,
        details: [
          layout.check(
            mark: Silent,
            fact: describe_failure(problem),
            detail: None,
          ),
        ],
        actions: [],
      )

    Loaded(value: Verdict(mark:, fact:, detail:)) ->
      layout.row(
        tone: case mark {
          Contradicts -> Warning
          Confirms | Silent -> Plain
        },
        name:,
        details: [layout.check(mark:, fact:, detail:)],
        actions: [],
      )
  }
}

fn view_announcement(
  announcement: Announcement,
  server: String,
) -> Element(Message) {
  let #(fact, refusal) = case announcement {
    NotAnnounced | Announcing -> #("Re-announce account to the network", [])
    Announced -> #("Re-announced account to the network", [])
    AnnouncementRefused(problem:) -> #("Re-announce account to the network", [
      layout.problem(describe_refusal(problem)),
    ])
  }

  layout.block_apart([
    layout.note_with_detail(
      fact:,
      detail: server
        <> " emits #account, #identity and #sync events for this account.",
      actions: [
        html.button(
          [
            attribute.class("action"),
            attribute.disabled(announcement == Announcing),
            event.on_click(UserClickedReannounce),
          ],
          [html.text("Re-announce")],
        ),
      ],
    ),
    ..refusal
  ])
}
