import at/did.{type Did}
import at/handle.{type Handle}
import gleam/dynamic/decode.{type Decoder}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import homestead/browser
import homestead/layout.{
  type Mark, type Tone, Confirms, Contradicts, Plain, Silent, Warning,
}
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Session}
import homestead/setting.{type Appview, type Settings}
import homestead/tranquil.{
  type Account, type Problem, type ProfileRecord, ProfileRecord,
}
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
    attempt: Int,
    record: Remote(Option(ProfileRecord)),
    cards: List(Card),
    announcement: Announcement,
  )
}

type Card {
  Card(appview: Appview, standing: Remote(Standing))
}

pub type Standing {
  Found(profile: Profile)
  NotFound
  Deactivated
  TakenDown
}

pub type Profile {
  Profile(
    handle: Resolution,
    name: Option(String),
    description: Option(String),
    avatar: Option(String),
    banner: Option(String),
  )
}

pub type Resolution {
  Resolved(handle: Handle)
  Unresolved
}

pub type Field {
  Name
  Description
  Avatar
  Banner
}

type Row {
  Row(verdict: Verdict, aside: Option(String))
}

type Verdict {
  Waiting
  Judged(mark: Mark, fact: String, detail: List(String))
}

type Announcement {
  NotAnnounced
  Announcing
  Announced
  AnnouncementRefused(problem: Problem)
}

const announcement_wait_milliseconds = 3000

pub fn init(session: Session, settings: Settings) -> #(Model, Effect(Message)) {
  ask(Model(
    session:,
    settings:,
    attempt: 0,
    record: Loading,
    cards: [],
    announcement: NotAnnounced,
  ))
}

fn ask(model: Model) -> #(Model, Effect(Message)) {
  let account = session.account(model.session)
  let attempt = model.attempt + 1

  #(
    Model(
      ..model,
      attempt:,
      record: Loading,
      cards: list.map(model.settings.appviews, fn(appview) {
        Card(appview:, standing: Loading)
      }),
    ),
    effect.batch([
      tranquil.load(
        model.session,
        tranquil.profile_record(account),
        ServerReturnedProfile(attempt, _),
      ),
      ..list.map(model.settings.appviews, ask_appview(model, attempt, _))
    ]),
  )
}

fn ask_appview(
  model: Model,
  attempt: Int,
  appview: Appview,
) -> Effect(Message) {
  rsvp.send(
    profile_request(appview.address, session.account(model.session)),
    rsvp.expect_any_response(AppviewReturnedProfile(attempt, appview, _)),
  )
}

fn set_standing(
  cards: List(Card),
  appview: Appview,
  standing: Remote(Standing),
) -> List(Card) {
  list.map(cards, fn(card) {
    case card.appview == appview {
      True -> Card(..card, standing:)
      False -> card
    }
  })
}

pub opaque type Message {
  ServerReturnedProfile(attempt: Int, result: Result(ProfileRecord, Problem))
  AppviewReturnedProfile(
    attempt: Int,
    appview: Appview,
    result: Result(Response(String), rsvp.Error(String)),
  )
  UserClickedCheckAgain
  UserClickedTryAgain(appview: Appview)
  UserClickedReannounce
  ServerAnnouncedAccount(result: Result(Nil, Problem))
  BrowserWaitedAfterAnnouncement
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    ServerReturnedProfile(attempt:, ..)
      | AppviewReturnedProfile(attempt:, ..)
      if attempt != model.attempt
    -> #(model, effect.none())

    ServerReturnedProfile(result: Ok(record), ..) -> #(
      Model(..model, record: Loaded(Some(record))),
      effect.none(),
    )

    ServerReturnedProfile(
      result: Error(tranquil.Problem(
        reason: tranquil.Refused("RecordNotFound", _),
        ..,
      )),
      ..,
    ) -> #(Model(..model, record: Loaded(None)), effect.none())

    ServerReturnedProfile(result: Error(problem), ..) -> #(
      Model(..model, record: Failed(problem:)),
      effect.none(),
    )

    AppviewReturnedProfile(appview:, result:, ..) -> #(
      Model(
        ..model,
        cards: set_standing(
          model.cards,
          appview,
          read_profile(result, from: tranquil.server_name(appview.address)),
        ),
      ),
      effect.none(),
    )

    UserClickedCheckAgain | BrowserWaitedAfterAnnouncement -> ask(model)

    UserClickedTryAgain(appview:) -> #(
      Model(..model, cards: set_standing(model.cards, appview, Loading)),
      ask_appview(model, model.attempt, appview),
    )

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
      browser.after(
        announcement_wait_milliseconds,
        BrowserWaitedAfterAnnouncement,
      ),
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
      case json.parse(response.body, profile_decoder()) {
        Ok(profile) -> Loaded(value: Found(profile:))
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
        Ok(Refusal(error: "InvalidRequest", message: Some("Profile not found"))) ->
          Loaded(value: NotFound)
        Ok(Refusal(error:, message:)) ->
          Failed(tranquil.Problem(
            service: appview,
            reason: tranquil.Refused(error, option.unwrap(message, "")),
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

fn profile_decoder() -> Decoder(Profile) {
  use resolution <- decode.field("handle", resolution_decoder())
  use name <- non_empty_text("displayName")
  use description <- non_empty_text("description")
  use avatar <- non_empty_text("avatar")
  use banner <- non_empty_text("banner")

  decode.success(Profile(
    handle: resolution,
    name:,
    description:,
    avatar:,
    banner:,
  ))
}

fn resolution_decoder() -> Decoder(Resolution) {
  use name <- decode.then(decode.string)

  case name, handle.from_string(name) {
    "handle.invalid", _ -> decode.success(Unresolved)
    _, Ok(resolved) -> decode.success(Resolved(handle: resolved))
    _, Error(Nil) -> decode.failure(Unresolved, "Handle")
  }
}

fn non_empty_text(
  field: String,
  next: fn(Option(String)) -> Decoder(final),
) -> Decoder(final) {
  use value <- decode.optional_field(field, "", decode.string)

  next(case value {
    "" -> None
    value -> Some(value)
  })
}

type Refusal {
  Refusal(error: String, message: Option(String))
}

fn refusal_decoder() -> Decoder(Refusal) {
  use error <- decode.field("error", decode.string)
  use message <- non_empty_text("message")

  decode.success(Refusal(error:, message:))
}

pub fn stale_fields(
  record: Option(ProfileRecord),
  profile: Profile,
) -> List(Field) {
  let own = or_empty(record)

  list.filter([Name, Description, Avatar, Banner], fn(field) {
    case field {
      Name -> profile.name != own.name
      Description -> profile.description != own.description
      Avatar -> !is_same_image(record: own.avatar, shown: profile.avatar)
      Banner -> !is_same_image(record: own.banner, shown: profile.banner)
    }
  })
}

fn or_empty(record: Option(ProfileRecord)) -> ProfileRecord {
  option.unwrap(
    record,
    ProfileRecord(name: None, description: None, avatar: None, banner: None),
  )
}

fn is_same_image(
  record image: Option(String),
  shown address: Option(String),
) -> Bool {
  case image, address {
    None, None -> True
    Some(image), Some(address) -> string.contains(address, image)
    Some(_), None | None, Some(_) -> False
  }
}

fn describe_failure(problem: Problem) -> String {
  case problem.reason {
    tranquil.Unreachable -> "couldn't reach " <> problem.service
    tranquil.Refused(error:, ..) -> problem.service <> " answered " <> error
    tranquil.NotUnderstood -> "couldn't read " <> problem.service <> "'s answer"
  }
}

fn describe_failure_on_card(problem: Problem) -> String {
  case problem.reason {
    tranquil.Unreachable -> "no answer"
    tranquil.Refused(error:, ..) -> "answered " <> error
    tranquil.NotUnderstood -> "answer not understood"
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
    || list.any(model.cards, fn(card) { card.standing == Loading })

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
      list.map(model.cards, view_card(_, model.record, account)),
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

fn view_card(
  card: Card,
  record: Remote(Option(ProfileRecord)),
  account: Remote(Account),
) -> Element(Message) {
  let host = tranquil.server_name(card.appview.address)
  let prompt = option.unwrap(card.appview.name, host)
  let retry = case card.standing {
    Failed(_) -> [
      html.button(
        [
          attribute.class("action"),
          event.on_click(UserClickedTryAgain(card.appview)),
        ],
        [html.text("Try again")],
      ),
    ]
    Loading | Loaded(_) -> []
  }
  let address = case card.appview.name {
    Some(_) -> [layout.dim(host)]
    None -> []
  }
  let presence = judge_presence(card.standing, record, account, host)

  layout.section_with_state(
    prompt:,
    tone: tone(presence),
    state: view_verdict(presence),
    aside: list.append(retry, address),
    content: [
      layout.block([
        view_row("Handle", judge_handle(card.standing, account, host)),
        view_row("Profile", judge_profile(card.standing, record)),
      ]),
    ],
  )
}

fn judge_presence(
  standing: Remote(Standing),
  record: Remote(Option(ProfileRecord)),
  account: Remote(Account),
  host: String,
) -> Verdict {
  case standing {
    Loading -> Waiting
    Failed(problem:) ->
      Judged(mark: Silent, fact: describe_failure_on_card(problem), detail: [])
    Loaded(value: answer) ->
      case account {
        Loading -> Waiting
        Failed(problem:) ->
          Judged(mark: Silent, fact: describe_failure(problem), detail: [])
        Loaded(value: own) ->
          case answer, own.is_active {
            Found(_), True -> Judged(mark: Confirms, fact: "exists", detail: [])
            Found(_), False ->
              Judged(mark: Contradicts, fact: "still active", detail: [])
            NotFound, _ -> judge_absence(record, host)
            Deactivated, True ->
              Judged(mark: Contradicts, fact: "deactivated", detail: [
                host <> " answered AccountDeactivated.",
              ])
            Deactivated, False ->
              Judged(mark: Confirms, fact: "deactivated", detail: [
                host <> " answered AccountDeactivated.",
              ])
            TakenDown, _ ->
              Judged(mark: Contradicts, fact: "taken down", detail: [
                host <> " answered AccountTakedown.",
              ])
          }
      }
  }
}

fn judge_absence(
  record: Remote(Option(ProfileRecord)),
  host: String,
) -> Verdict {
  let detail = [host <> " answered \"Profile not found\"."]

  case record {
    Loading -> Waiting
    Loaded(value: Some(_)) ->
      Judged(mark: Contradicts, fact: "not found", detail:)
    Loaded(value: None) | Failed(_) ->
      Judged(mark: Silent, fact: "not found", detail:)
  }
}

fn judge_handle(
  standing: Remote(Standing),
  account: Remote(Account),
  host: String,
) -> Row {
  use profile <- when_found(standing)
  use own <- when_loaded(account)

  case profile.handle {
    Resolved(handle: shown) if shown == own.handle ->
      Row(
        verdict: Judged(mark: Confirms, fact: "up to date", detail: []),
        aside: None,
      )
    Resolved(handle: shown) ->
      Row(
        verdict: Judged(mark: Contradicts, fact: "out of date", detail: [
          host <> " has @" <> handle.to_string(shown) <> ".",
          "This server has @" <> handle.to_string(own.handle) <> ".",
        ]),
        aside: Some("@" <> handle.to_string(shown)),
      )
    Unresolved ->
      Row(
        verdict: Judged(mark: Contradicts, fact: "not resolved", detail: [
          host <> " answers handle.invalid when it can't resolve the handle.",
        ]),
        aside: Some("handle.invalid"),
      )
  }
}

fn judge_profile(
  standing: Remote(Standing),
  record: Remote(Option(ProfileRecord)),
) -> Row {
  use profile <- when_found(standing)
  use own <- when_loaded(record)

  case stale_fields(own, profile), own {
    [], None ->
      Row(
        verdict: Judged(mark: Silent, fact: "no profile record", detail: []),
        aside: None,
      )
    [], Some(_) ->
      Row(
        verdict: Judged(mark: Confirms, fact: "up to date", detail: []),
        aside: None,
      )
    [_, ..] as stale, _ ->
      Row(
        verdict: Judged(
          mark: Contradicts,
          fact: "out of date",
          detail: list.append(
            list.map(stale, describe_stale(_, or_empty(own), profile)),
            [
              "Re-announce doesn't send the profile. A change to the profile does.",
            ],
          ),
        ),
        aside: Some(stale |> list.map(field_name) |> string.join(", ")),
      )
  }
}

fn when_found(standing: Remote(Standing), judge: fn(Profile) -> Row) -> Row {
  case standing {
    Loading -> Row(verdict: Waiting, aside: None)
    Loaded(value: Found(profile:)) -> judge(profile)
    Loaded(value: NotFound)
    | Loaded(value: Deactivated)
    | Loaded(value: TakenDown)
    | Failed(_) ->
      Row(
        verdict: Judged(mark: Silent, fact: "not checked", detail: []),
        aside: None,
      )
  }
}

fn when_loaded(remote: Remote(value), judge: fn(value) -> Row) -> Row {
  case remote {
    Loading -> Row(verdict: Waiting, aside: None)
    Failed(problem:) ->
      Row(
        verdict: Judged(
          mark: Silent,
          fact: describe_failure(problem),
          detail: [],
        ),
        aside: None,
      )
    Loaded(value:) -> judge(value)
  }
}

fn field_name(field: Field) -> String {
  case field {
    Name -> "name"
    Description -> "description"
    Avatar -> "avatar"
    Banner -> "banner"
  }
}

fn describe_stale(
  field: Field,
  own: ProfileRecord,
  profile: Profile,
) -> String {
  field_name(field)
  <> ": "
  <> case field {
    Name -> describe_texts(shown: profile.name, own: own.name)
    Description ->
      describe_texts(shown: profile.description, own: own.description)
    Avatar -> describe_images(shown: profile.avatar, own: own.avatar)
    Banner -> describe_images(shown: profile.banner, own: own.banner)
  }
}

fn describe_texts(
  shown shown: Option(String),
  own own: Option(String),
) -> String {
  "has " <> quote(shown) <> ", this server has " <> quote(own)
}

fn quote(text: Option(String)) -> String {
  case text {
    Some(text) -> "\"" <> text <> "\""
    None -> "none"
  }
}

fn describe_images(
  shown shown: Option(String),
  own own: Option(String),
) -> String {
  case shown, own {
    None, Some(_) -> "has none, this server has one"
    Some(_), None -> "has one, this server has none"
    Some(_), Some(_) -> "has another image"
    None, None -> "has none, this server has none"
  }
}

fn view_row(name: String, row: Row) -> Element(Message) {
  layout.row_with_aside(
    tone: tone(row.verdict),
    name:,
    details: [view_verdict(row.verdict)],
    aside: row.aside,
  )
}

fn view_verdict(verdict: Verdict) -> Element(Message) {
  case verdict {
    Waiting -> layout.pending()
    Judged(mark:, fact:, detail:) -> layout.check(mark:, fact:, detail:)
  }
}

fn tone(verdict: Verdict) -> Tone {
  case verdict {
    Judged(mark: Contradicts, ..) -> Warning
    Judged(mark: Confirms, ..) | Judged(mark: Silent, ..) | Waiting -> Plain
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
