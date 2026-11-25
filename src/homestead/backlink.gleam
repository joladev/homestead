import at/did.{type Did}
import at/handle.{type Handle}
import at/tid
import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/http/request.{type Request}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/duration.{type Duration}
import homestead/constellation.{type Link, type Linking}
import homestead/date
import homestead/layout
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/route.{type BacklinkLocation, Backlinks, Data, Source, Sources}
import homestead/session.{type Session}
import homestead/setting.{type Settings}
import homestead/tranquil
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp

pub opaque type Model {
  Model(account: Did, settings: Settings, local_offset: Duration, place: Place)
}

type Place {
  AtSources(links: Remote(List(Link)))
  AtSource(
    collection: String,
    path: String,
    records: Remote(List(Linking)),
    next: Option(String),
    more: More,
    profiles: Dict(Did, Profile),
  )
}

type More {
  NotLoadingMore
  LoadingMore
  MoreFailed
}

pub type Profile {
  Profile(account: Did, handle: Handle, image: Option(String))
}

pub fn init(
  session: Session,
  settings: Settings,
  local_offset: Duration,
  location: BacklinkLocation,
) -> #(Model, Effect(Message)) {
  let account = session.account(session)

  case location {
    Sources -> #(
      Model(
        account:,
        settings:,
        local_offset:,
        place: AtSources(links: Loading),
      ),
      rsvp.send(
        constellation.links_request(
          settings.constellation,
          did.to_string(account),
        ),
        rsvp.expect_json(
          constellation.links_decoder(),
          ConstellationReturnedLinks,
        ),
      ),
    )

    Source(collection:, path:) -> #(
      Model(
        account:,
        settings:,
        local_offset:,
        place: AtSource(
          collection:,
          path:,
          records: Loading,
          next: None,
          more: NotLoadingMore,
          profiles: dict.new(),
        ),
      ),
      ask(settings.constellation, account, collection, path, None),
    )
  }
}

pub opaque type Message {
  ConstellationReturnedLinks(result: Result(List(Link), rsvp.Error(String)))
  ConstellationReturnedRecords(
    result: Result(constellation.Page, rsvp.Error(String)),
  )
  UserClickedMore(after: String)
  AppViewReturnedProfiles(result: Result(List(Profile), rsvp.Error(String)))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case model.place, message {
    AtSources(_), ConstellationReturnedLinks(result: returned) -> #(
      Model(
        ..model,
        place: AtSources(
          links: result.map_error(returned, tranquil.error_to_problem(
            _,
            from: "Constellation",
          ))
          |> remote.from_result,
        ),
      ),
      effect.none(),
    )

    AtSource(collection:, path:, ..),
      ConstellationReturnedRecords(result: Ok(constellation.Page(
        records: [],
        next: Some(after),
      )))
    -> #(
      model,
      ask(
        model.settings.constellation,
        model.account,
        collection,
        path,
        Some(after),
      ),
    )

    AtSource(records:, profiles:, ..) as place,
      ConstellationReturnedRecords(result: Ok(page))
    -> {
      let unknown =
        list.map(page.records, fn(record) { record.account })
        |> list.unique
        |> list.filter(fn(account) { !dict.has_key(profiles, account) })

      #(
        Model(
          ..model,
          place: AtSource(
            ..place,
            records: Loaded(case records {
              Loaded(value: earlier) -> list.append(earlier, page.records)
              Loading | Failed(_) -> page.records
            }),
            next: page.next,
            more: NotLoadingMore,
          ),
        ),
        case unknown {
          [] -> effect.none()
          [_, ..] ->
            rsvp.send(
              profiles_request(model.settings.appview, unknown),
              rsvp.expect_json(profiles_decoder(), AppViewReturnedProfiles),
            )
        },
      )
    }

    AtSource(records: Loading, ..) as place,
      ConstellationReturnedRecords(result: Error(error))
    -> #(
      Model(
        ..model,
        place: AtSource(
          ..place,
          records: Failed(tranquil.error_to_problem(
            error,
            from: "Constellation",
          )),
        ),
      ),
      effect.none(),
    )

    AtSource(..) as place, ConstellationReturnedRecords(result: Error(_)) -> #(
      Model(..model, place: AtSource(..place, more: MoreFailed)),
      effect.none(),
    )

    AtSource(collection:, path:, ..) as place, UserClickedMore(after:) -> #(
      Model(..model, place: AtSource(..place, more: LoadingMore)),
      ask(
        model.settings.constellation,
        model.account,
        collection,
        path,
        Some(after),
      ),
    )

    AtSource(profiles:, ..) as place, AppViewReturnedProfiles(result: Ok(found))
    -> #(
      Model(
        ..model,
        place: AtSource(
          ..place,
          profiles: list.fold(found, profiles, fn(profiles, profile) {
            dict.insert(profiles, profile.account, profile)
          }),
        ),
      ),
      effect.none(),
    )

    AtSource(..), AppViewReturnedProfiles(result: Error(_))
    | AtSource(..), ConstellationReturnedLinks(_)
    | AtSources(_), ConstellationReturnedRecords(_)
    | AtSources(_), UserClickedMore(_)
    | AtSources(_), AppViewReturnedProfiles(_)
    -> #(model, effect.none())
  }
}

fn ask(
  constellation: Request(String),
  account: Did,
  collection: String,
  path: String,
  after: Option(String),
) -> Effect(Message) {
  rsvp.send(
    constellation.linking_request(
      constellation,
      did.to_string(account),
      collection,
      path,
      after,
    ),
    rsvp.expect_json(
      constellation.linking_decoder(),
      ConstellationReturnedRecords,
    ),
  )
}

pub fn profiles_request(
  appview: Request(String),
  accounts: List(Did),
) -> Request(String) {
  appview
  |> request.set_path("/xrpc/app.bsky.actor.getProfiles")
  |> request.set_query(
    list.map(accounts, fn(account) { #("actors", did.to_string(account)) }),
  )
}

pub fn profiles_decoder() -> Decoder(List(Profile)) {
  let profile = {
    use account <- decode.field("did", did.decoder())
    use handle <- decode.field("handle", handle.decoder())
    use image <- decode.optional_field(
      "avatar",
      None,
      decode.optional(decode.string),
    )

    decode.success(Profile(account:, handle:, image:))
  }

  decode.at(["profiles"], decode.list(profile))
}

pub fn view(model: Model) -> Element(Message) {
  layout.page([
    case model.place {
      AtSources(links:) ->
        layout.path_section([html.text("backlinks")], [
          layout.block({
            use links <- layout.rows(links, placeholders: 3)

            layout.listing(
              empty: "Nothing links to this account",
              rows: list.map(links, fn(link) {
                #(link.collection <> link.path, view_source(link, links))
              }),
              actions: [],
            )
          }),
        ])

      AtSource(collection:, path:, records:, next:, more:, profiles:) ->
        layout.path_section(
          [
            html.a([route.href(Data(Backlinks(Sources)))], [
              html.text("backlinks"),
            ]),
            html.text(collection),
          ],
          [
            layout.block(
              list.flatten([
                [
                  layout.row(
                    tone: layout.Plain,
                    name: "Path",
                    details: [
                      html.code([attribute.class("long")], [html.text(path)]),
                    ],
                    actions: [],
                  ),
                ],
                {
                  use records <- layout.rows(records, placeholders: 3)

                  layout.listing(
                    empty: "No records",
                    rows: list.map(records, fn(record) {
                      #(
                        did.to_string(record.account) <> record.key,
                        view_linking(record, profiles, model.local_offset),
                      )
                    }),
                    actions: case next {
                      Some(after) -> [
                        html.button(
                          [
                            attribute.class("action"),
                            attribute.disabled(more == LoadingMore),
                            event.on_click(UserClickedMore(after)),
                          ],
                          [html.text("More")],
                        ),
                      ]
                      None -> []
                    },
                  )
                },
                case more {
                  MoreFailed -> [layout.problem("Couldn't load more")]
                  NotLoadingMore | LoadingMore -> []
                },
              ]),
            ),
          ],
        )
    },
  ])
}

fn view_source(link: Link, links: List(Link)) -> Element(message) {
  let shares_collection =
    list.count(links, fn(other) { other.collection == link.collection }) > 1

  html.a(
    [
      attribute.class("row entry-row"),
      route.href(
        Data(Backlinks(Source(collection: link.collection, path: link.path))),
      ),
    ],
    [
      html.div([attribute.class("what")], [
        html.span([attribute.class("title")], [
          html.strong([], [html.text(link.collection)]),
        ]),
        case shares_collection {
          True -> html.span([attribute.class("source")], [html.text(link.path)])
          False -> element.none()
        },
      ]),
      html.div([attribute.class("when")], [
        html.span([], [html.text(count(link.records, "record", "records"))]),
        html.span([], [html.text(count(link.accounts, "account", "accounts"))]),
      ]),
    ],
  )
}

fn view_linking(
  record: Linking,
  profiles: Dict(Did, Profile),
  local_offset: Duration,
) -> Element(message) {
  let profile = dict.get(profiles, record.account)

  html.div([attribute.class("row entry-row")], [
    html.div([attribute.class("what")], [
      html.span([attribute.class("title")], [
        case profile {
          Ok(Profile(image: Some(url), ..)) ->
            html.img([
              attribute.src(url),
              attribute.alt(""),
              attribute.width(20),
              attribute.height(20),
              attribute.loading("lazy"),
            ])
          Ok(Profile(image: None, ..)) | Error(Nil) ->
            html.span([attribute.class("no-avatar")], [])
        },
        html.strong([], [
          html.text(case profile {
            Ok(profile) -> "@" <> handle.to_string(profile.handle)
            Error(Nil) -> did.to_string(record.account)
          }),
        ]),
      ]),
    ]),
    html.div([attribute.class("when")], [
      case tid.from_string(record.key) {
        Ok(written) ->
          html.span([], [
            html.text(date.describe_day(tid.to_timestamp(written), local_offset)),
          ])
        Error(Nil) -> element.none()
      },
    ]),
  ])
}

fn count(number: Int, singular: String, plural: String) -> String {
  case number {
    1 -> "1 " <> singular
    _ -> int.to_string(number) <> " " <> plural
  }
}
