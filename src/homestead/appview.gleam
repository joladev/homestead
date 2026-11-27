import at/did.{type Did}
import at/handle.{type Handle}
import gleam/dynamic/decode.{type Decoder}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import homestead/layout.{
  type Mark, Confirms, Contradicts, Plain, Silent, Warning,
}
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Session}
import homestead/setting.{type Appview, type Settings}
import homestead/tranquil.{type Account, type Problem, type Profile, Profile}
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
    record: Remote(Option(Profile)),
    groups: List(Group),
    announcement: Announcement,
  )
}

type Group {
  Group(appview: Appview, standing: Remote(Standing))
}

pub type Standing {
  Found(handle: Held, profile: Profile)
  NotFound
  Deactivated
  TakenDown
}

pub type Held {
  Resolved(handle: Handle)
  Unresolved
}

pub type Fact {
  Fact(mark: Mark, state: String, aside: Option(String))
}

type Announcement {
  NotAnnounced
  Announcing
  Announced
  AnnouncementRefused(problem: Problem)
}

pub fn init(session: Session, settings: Settings) -> #(Model, Effect(Message)) {
  let #(groups, effect) = ask(session, settings)

  #(
    Model(
      session:,
      settings:,
      record: Loading,
      groups:,
      announcement: NotAnnounced,
    ),
    effect,
  )
}

fn ask(
  session: Session,
  settings: Settings,
) -> #(List(Group), Effect(Message)) {
  let account = session.account(session)

  #(
    list.map(settings.appviews, fn(appview) {
      Group(appview:, standing: Loading)
    }),
    effect.batch([
      tranquil.load(session, tranquil.profile(account), ServerReturnedProfile),
      ..list.map(settings.appviews, fn(appview) {
        rsvp.send(
          profile_request(appview.address, account),
          rsvp.expect_any_response(AppviewReturnedProfile(appview, _)),
        )
      })
    ]),
  )
}

pub opaque type Message {
  ServerReturnedProfile(result: Result(Profile, Problem))
  AppviewReturnedProfile(
    appview: Appview,
    result: Result(Response(String), rsvp.Error(String)),
  )
  UserClickedCheckAgain
  UserClickedReannounce
  ServerAnnouncedAccount(result: Result(Nil, Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    ServerReturnedProfile(result: Ok(profile)) -> #(
      Model(..model, record: Loaded(Some(profile))),
      effect.none(),
    )

    ServerReturnedProfile(result: Error(tranquil.Problem(
      reason: tranquil.Refused("RecordNotFound", _),
      ..,
    ))) -> #(Model(..model, record: Loaded(None)), effect.none())

    ServerReturnedProfile(result: Error(problem)) -> #(
      Model(..model, record: Failed(problem:)),
      effect.none(),
    )

    AppviewReturnedProfile(appview:, result:) -> #(
      Model(
        ..model,
        groups: list.map(model.groups, fn(group) {
          case group.appview == appview {
            True ->
              Group(
                ..group,
                standing: read_profile(
                  result,
                  from: tranquil.server_name(appview.address),
                ),
              )
            False -> group
          }
        }),
      ),
      effect.none(),
    )

    UserClickedCheckAgain -> {
      let #(groups, effect) = ask(model.session, model.settings)

      #(Model(..model, record: Loading, groups:), effect)
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
      case json.parse(response.body, found_decoder()) {
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

fn found_decoder() -> Decoder(Standing) {
  use held <- decode.field("handle", held_decoder())
  use name <- text("displayName")
  use description <- text("description")
  use avatar <- text("avatar")
  use banner <- text("banner")

  decode.success(Found(
    handle: held,
    profile: Profile(name:, description:, avatar:, banner:),
  ))
}

fn held_decoder() -> Decoder(Held) {
  use name <- decode.then(decode.string)

  case name, handle.from_string(name) {
    "handle.invalid", _ -> decode.success(Unresolved)
    _, Ok(held) -> decode.success(Resolved(handle: held))
    _, Error(Nil) -> decode.failure(Unresolved, "Handle")
  }
}

fn text(
  field: String,
  next: fn(Option(String)) -> Decoder(final),
) -> Decoder(final) {
  use text <- decode.optional_field(field, "", decode.string)

  next(case text {
    "" -> None
    text -> Some(text)
  })
}

type Refusal {
  Refusal(error: String, message: String)
}

fn refusal_decoder() -> Decoder(Refusal) {
  use error <- decode.field("error", decode.string)
  use message <- decode.optional_field("message", "", decode.string)

  decode.success(Refusal(error:, message:))
}

pub fn account_fact(standing: Standing, is_active: Bool) -> Fact {
  case standing, is_active {
    Found(_, _), True -> Fact(mark: Confirms, state: "exists", aside: None)
    Found(_, _), False ->
      Fact(mark: Contradicts, state: "still active", aside: None)
    NotFound, _ -> Fact(mark: Contradicts, state: "not found", aside: None)
    Deactivated, True ->
      Fact(mark: Contradicts, state: "deactivated", aside: None)
    Deactivated, False ->
      Fact(mark: Confirms, state: "deactivated", aside: None)
    TakenDown, _ -> Fact(mark: Contradicts, state: "taken down", aside: None)
  }
}

pub fn handle_fact(held: Held, own: Handle) -> Fact {
  case held {
    Resolved(handle: held) if held == own ->
      Fact(mark: Confirms, state: "up to date", aside: None)
    Resolved(handle: held) ->
      Fact(
        mark: Contradicts,
        state: "out of date",
        aside: Some("@" <> handle.to_string(held)),
      )
    Unresolved ->
      Fact(
        mark: Contradicts,
        state: "not resolved",
        aside: Some("handle.invalid"),
      )
  }
}

pub fn profile_fact(shown: Profile, record: Option(Profile)) -> Fact {
  let own =
    option.unwrap(
      record,
      Profile(name: None, description: None, avatar: None, banner: None),
    )
  let stale =
    [
      Field(name: "name", is_current: shown.name == own.name),
      Field(
        name: "description",
        is_current: shown.description == own.description,
      ),
      Field(name: "avatar", is_current: is_same_image(own.avatar, shown.avatar)),
      Field(name: "banner", is_current: is_same_image(own.banner, shown.banner)),
    ]
    |> list.filter(fn(field) { !field.is_current })
    |> list.map(fn(field) { field.name })

  case stale, record {
    [], None -> Fact(mark: Silent, state: "no profile record", aside: None)
    [], Some(_) -> Fact(mark: Confirms, state: "up to date", aside: None)
    [_, ..], _ ->
      Fact(
        mark: Contradicts,
        state: "out of date",
        aside: Some(string.join(stale, ", ")),
      )
  }
}

type Field {
  Field(name: String, is_current: Bool)
}

fn is_same_image(record: Option(String), shown: Option(String)) -> Bool {
  case record, shown {
    None, None -> True
    Some(image), Some(address) -> string.contains(address, image)
    Some(_), None | None, Some(_) -> False
  }
}

fn when_found(
  standing: Remote(Standing),
  judge: fn(Held, Profile) -> Remote(Fact),
) -> Remote(Fact) {
  case standing {
    Loading -> Loading
    Loaded(value: Found(handle:, profile:)) -> judge(handle, profile)
    Loaded(value: NotFound)
    | Loaded(value: Deactivated)
    | Loaded(value: TakenDown)
    | Failed(_) -> Loaded(Fact(mark: Silent, state: "not checked", aside: None))
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
  let is_asking =
    model.record == Loading
    || list.any(model.groups, fn(group) { group.standing == Loading })

  layout.page(
    list.flatten([
      [
        layout.title_section_with_actions(
          "appviews",
          [
            html.button(
              [
                attribute.class("action"),
                attribute.disabled(is_asking),
                event.on_click(UserClickedCheckAgain),
              ],
              [html.text("Check again")],
            ),
          ],
          [],
        ),
      ],
      list.map(model.groups, view_group(_, model.record, account)),
      case account {
        Loaded(value: tranquil.Account(is_active: True, ..)) -> [
          view_announcement(model.announcement, session.server(model.session)),
        ]
        Loaded(value: tranquil.Account(is_active: False, ..))
        | Loading
        | Failed(_) -> []
      },
    ]),
  )
}

fn view_group(
  group: Group,
  record: Remote(Option(Profile)),
  account: Remote(Account),
) -> Element(Message) {
  let host = tranquil.server_name(group.appview.address)
  let #(prompt, aside) = case group.appview.name {
    Some(name) -> #(name, [layout.dim(host)])
    None -> #(host, [])
  }

  layout.section_with_actions(prompt, aside, [
    layout.block([
      view_fact("Account", {
        use standing <- remote.then(group.standing)
        use account <- remote.map(account)

        account_fact(standing, account.is_active)
      }),
      view_fact("Handle", {
        use held, _ <- when_found(group.standing)
        use account <- remote.map(account)

        handle_fact(held, account.handle)
      }),
      view_fact("Profile", {
        use _, shown <- when_found(group.standing)
        use record <- remote.map(record)

        profile_fact(shown, record)
      }),
    ]),
  ])
}

fn view_fact(name: String, fact: Remote(Fact)) -> Element(Message) {
  case fact {
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

    Loaded(value: Fact(mark:, state:, aside:)) ->
      layout.row(
        tone: case mark {
          Contradicts -> Warning
          Confirms | Silent -> Plain
        },
        name:,
        details: [
          layout.check(mark:, fact: state, detail: None),
          ..case aside {
            Some(aside) -> [html.text(" \u{00B7} "), layout.dim(aside)]
            None -> []
          }
        ],
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

  html.section([], [
    layout.block([
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
    ]),
  ])
}
