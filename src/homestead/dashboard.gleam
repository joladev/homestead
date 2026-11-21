import gleam/bool
import gleam/dynamic/decode
import gleam/javascript/promise
import gleam/list
import gleam/option.{type Option, None, Some}
import homestead/app_passwords
import homestead/browser
import homestead/connected_apps
import homestead/overview
import homestead/profile
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/route.{
  type Route, type Section, Access, Account, Admin, Advanced, AppPasswords,
  ConnectedApps, Data, NotFound, Overview, Section, Sessions, SignInMethods,
}
import homestead/session.{type Departure, type Session}
import homestead/sessions
import homestead/tranquil.{type Problem}
import lustre/attribute.{type Attribute}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event

pub opaque type Model {
  Model(
    session: Session,
    route: Route,
    page: Page,
    account: Remote(tranquil.Account),
    is_account_menu_open: Bool,
    is_menu_open: Bool,
    has_signed_out: Bool,
  )
}

type Page {
  OverviewPage(overview.Model)
  SessionsPage(sessions.Model)
  ConnectedAppsPage(connected_apps.Model)
  AppPasswordsPage(app_passwords.Model)
  ProfilePage(profile.Model)
  PlaceholderPage
}

pub fn init(session: Session, route: Route) -> #(Model, Effect(Message)) {
  let #(page, effect) = open(session, route)

  #(
    Model(
      session:,
      route:,
      page:,
      account: Loading,
      is_account_menu_open: False,
      is_menu_open: False,
      has_signed_out: False,
    ),
    effect.batch([
      tranquil.load(session, tranquil.account(), ServerReturnedAccount),
      effect,
    ]),
  )
}

pub fn show(model: Model, route: Route) -> #(Model, Effect(Message)) {
  use <- bool.guard(route == model.route, #(
    Model(..model, is_menu_open: False),
    effect.none(),
  ))
  let #(page, effect) = open(model.session, route)

  #(Model(..model, route:, page:, is_menu_open: False), effect)
}

fn open(session: Session, route: Route) -> #(Page, Effect(Message)) {
  case route {
    Overview -> {
      let #(page, effect) = overview.init(session)

      #(OverviewPage(page), effect.map(effect, OverviewProducedMessage))
    }

    Access(Sessions) -> {
      let #(page, effect) = sessions.init(session, sessions.Everything)

      #(SessionsPage(page), effect.map(effect, SessionsProducedMessage))
    }

    Access(ConnectedApps) -> {
      let #(page, effect) = connected_apps.init(session)

      #(
        ConnectedAppsPage(page),
        effect.map(effect, ConnectedAppsProducedMessage),
      )
    }

    Access(AppPasswords) -> {
      let #(page, effect) = app_passwords.init(session)

      #(AppPasswordsPage(page), effect.map(effect, AppPasswordsProducedMessage))
    }

    Account(route.Profile) -> {
      let #(page, effect) = profile.init(session)

      #(ProfilePage(page), effect.map(effect, ProfileProducedMessage))
    }

    Account(route.Notifications)
    | Access(SignInMethods)
    | Data(_)
    | Advanced(_)
    | Admin
    | NotFound(_) -> #(PlaceholderPage, effect.none())
  }
}

pub fn departure(model: Model) -> Option(Departure) {
  let page = case model.page {
    OverviewPage(page) -> overview.departure(page)
    SessionsPage(page) -> sessions.departure(page)
    ConnectedAppsPage(page) -> connected_apps.departure(page)
    AppPasswordsPage(page) -> app_passwords.departure(page)
    ProfilePage(page) -> profile.departure(page)
    PlaceholderPage -> None
  }

  case model.has_signed_out, remote.has_ended_session(model.account), page {
    True, _, _ -> Some(session.SignedOut)
    False, True, _ -> Some(session.Ended)
    False, False, departure -> departure
  }
}

pub opaque type Message {
  ServerReturnedAccount(result: Result(tranquil.Account, Problem))
  OverviewProducedMessage(overview.Message)
  SessionsProducedMessage(sessions.Message)
  ConnectedAppsProducedMessage(connected_apps.Message)
  AppPasswordsProducedMessage(app_passwords.Message)
  ProfileProducedMessage(profile.Message)
  UserToggledMenu
  UserDismissedMenu
  UserToggledAccountMenu
  UserOpenedAccountMenu
  UserDismissedAccountMenu
  UserLeftAccountMenu
  UserClickedSignOut
  ServerEndedSession
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message, model.page {
    ServerReturnedAccount(result:), _ -> #(
      Model(..model, account: remote.from_result(result)),
      effect.none(),
    )

    OverviewProducedMessage(message), OverviewPage(page) -> {
      let #(page, effect) = overview.update(page, message)

      #(
        Model(..model, page: OverviewPage(page)),
        effect.map(effect, OverviewProducedMessage),
      )
    }

    SessionsProducedMessage(message), SessionsPage(page) -> {
      let #(page, effect) = sessions.update(page, message)

      #(
        Model(..model, page: SessionsPage(page)),
        effect.map(effect, SessionsProducedMessage),
      )
    }

    ConnectedAppsProducedMessage(message), ConnectedAppsPage(page) -> {
      let #(page, effect) = connected_apps.update(page, message)

      #(
        Model(..model, page: ConnectedAppsPage(page)),
        effect.map(effect, ConnectedAppsProducedMessage),
      )
    }

    AppPasswordsProducedMessage(message), AppPasswordsPage(page) -> {
      let #(page, effect) = app_passwords.update(page, message)

      #(
        Model(..model, page: AppPasswordsPage(page)),
        effect.map(effect, AppPasswordsProducedMessage),
      )
    }

    ProfileProducedMessage(message), ProfilePage(page) -> {
      let #(page, effect) = profile.update(page, message)
      let account = case profile.account(page) {
        Loaded(_) as account -> account
        Loading | Failed(_) -> model.account
      }

      #(
        Model(..model, page: ProfilePage(page), account:),
        effect.map(effect, ProfileProducedMessage),
      )
    }

    OverviewProducedMessage(_), _
    | ProfileProducedMessage(_), _
    | SessionsProducedMessage(_), _
    | ConnectedAppsProducedMessage(_), _
    | AppPasswordsProducedMessage(_), _
    -> #(model, effect.none())

    UserToggledMenu, _ ->
      case model.is_menu_open {
        True -> #(
          Model(..model, is_menu_open: False),
          browser.focus(menu_button),
        )
        False -> #(
          Model(..model, is_menu_open: True),
          browser.focus(first_menu_link),
        )
      }

    UserDismissedMenu, _ -> #(
      Model(..model, is_menu_open: False),
      browser.focus(menu_button),
    )

    UserToggledAccountMenu, _ ->
      case model.is_account_menu_open {
        True -> #(
          Model(..model, is_account_menu_open: False),
          browser.focus(account_menu_button),
        )
        False -> #(
          Model(..model, is_account_menu_open: True),
          browser.focus(sign_out_item),
        )
      }

    UserOpenedAccountMenu, _ -> #(
      Model(..model, is_account_menu_open: True),
      browser.focus(sign_out_item),
    )

    UserDismissedAccountMenu, _ -> #(
      Model(..model, is_account_menu_open: False),
      browser.focus(account_menu_button),
    )

    UserLeftAccountMenu, _ -> #(
      Model(..model, is_account_menu_open: False),
      effect.none(),
    )

    UserClickedSignOut, _ -> #(
      Model(..model, is_account_menu_open: False),
      end_session(model.session),
    )

    ServerEndedSession, _ -> #(
      Model(..model, has_signed_out: True),
      effect.none(),
    )
  }
}

fn end_session(session: Session) -> Effect(Message) {
  use dispatch <- effect.from

  session.end(session)
  |> promise.tap(fn(_) { dispatch(ServerEndedSession) })

  Nil
}

const menu_button = "menu-button"

const first_menu_link = "menu-first-link"

const account_menu_button = "account-menu-button"

const sign_out_item = "account-menu-sign-out"

pub fn view(model: Model) -> Element(Message) {
  let current_section =
    list.find(route.sections, fn(section) {
      list.contains(route.section_pages(section), model.route)
    })

  element.fragment([
    view_top_bar(current_section, model),
    view_page_links(current_section, model.route),
    case model.page {
      OverviewPage(page) ->
        overview.view(page, model.session, model.account)
        |> element.map(OverviewProducedMessage)

      SessionsPage(page) ->
        sessions.view(page) |> element.map(SessionsProducedMessage)

      ConnectedAppsPage(page) ->
        connected_apps.view(page) |> element.map(ConnectedAppsProducedMessage)

      AppPasswordsPage(page) ->
        app_passwords.view(page) |> element.map(AppPasswordsProducedMessage)

      ProfilePage(page) ->
        profile.view(page) |> element.map(ProfileProducedMessage)

      PlaceholderPage ->
        html.main([attribute.class("page")], view_placeholder(model.route))
    },
  ])
}

fn view_top_bar(
  current: Result(Section, Nil),
  model: Model,
) -> Element(Message) {
  let section_links =
    list.map(route.sections, fn(section) {
      html.a(
        [
          route.href(section.first),
          attribute.data("label", section.label),
          aria_current("true", current == Ok(section)),
        ],
        [html.text(section.label)],
      )
    })
  let admin_link = case model.account {
    Loaded(tranquil.Account(is_admin: True, ..)) ->
      html.a(
        [
          route.href(Admin),
          attribute.data("label", route.label(Admin)),
          aria_current("true", model.route == Admin),
        ],
        [html.text(route.label(Admin))],
      )
    Loaded(tranquil.Account(is_admin: False, ..)) | Loading | Failed(_) ->
      element.none()
  }

  let account_name = case model.account {
    Loaded(value: account) -> Ok("@" <> account.handle)
    Failed(_) -> Ok(session.account(model.session))
    Loading -> Error(Nil)
  }

  html.header([attribute.class("top-bar")], [
    html.a([attribute.class("brand"), route.href(Overview)], [
      html.text("Homestead"),
    ]),
    html.nav(
      [attribute.aria_label("Sections")],
      list.append(section_links, [admin_link]),
    ),
    case account_name {
      Ok(name) -> view_account_menu(name, model.is_account_menu_open)
      Error(Nil) -> element.none()
    },
    html.button(
      [
        attribute.id(menu_button),
        attribute.class("menu-button"),
        attribute.aria_expanded(model.is_menu_open),
        attribute.aria_controls("menu"),
        event.on_click(UserToggledMenu),
      ],
      case model.is_menu_open {
        True -> [html.text("Close"), view_icon("M5 5l10 10M15 5L5 15")]
        False -> [html.text("Menu"), view_icon("M3 5.5h14M3 10h14M3 14.5h14")]
      },
    ),
    case model.is_menu_open {
      True -> view_menu(model, account_name)
      False -> element.none()
    },
  ])
}

fn view_icon(path: String) -> Element(Message) {
  html.svg(
    [
      attribute.attribute("viewBox", "0 0 20 20"),
      attribute.attribute("width", "20"),
      attribute.attribute("height", "20"),
      attribute.attribute("fill", "none"),
      attribute.attribute("stroke", "currentColor"),
      attribute.attribute("stroke-width", "1.5"),
      attribute.aria_hidden(True),
    ],
    [svg.path([attribute.attribute("d", path)])],
  )
}

fn view_menu(
  model: Model,
  account_name: Result(String, Nil),
) -> Element(Message) {
  let link = fn(page: Route, attributes: List(Attribute(Message))) {
    html.a(
      [
        route.href(page),
        aria_current("page", page == model.route),
        ..attributes
      ],
      [html.text(route.label(page))],
    )
  }
  let groups =
    list.map(route.sections, fn(section) {
      case section {
        Section(rest: [], first:, ..) ->
          link(first, [attribute.id(first_menu_link)])
        Section(label:, rest: [_, ..], ..) ->
          html.div([], [
            html.span([], [html.text(label)]),
            ..list.map(route.section_pages(section), link(_, []))
          ])
      }
    })
  let admin = case model.account {
    Loaded(tranquil.Account(is_admin: True, ..)) -> link(Admin, [])
    Loaded(tranquil.Account(is_admin: False, ..)) | Loading | Failed(_) ->
      element.none()
  }

  html.nav(
    [
      attribute.id("menu"),
      attribute.class("menu"),
      attribute.aria_label("All pages"),
      on_key(fn(key) {
        case key {
          "Escape" -> Ok(UserDismissedMenu)
          _ -> Error(Nil)
        }
      }),
    ],
    list.flatten([
      groups,
      [
        admin,
        html.footer([], [
          case account_name {
            Ok(name) -> html.code([], [html.text(name)])
            Error(Nil) -> element.none()
          },
          html.button(
            [attribute.class("action"), event.on_click(UserClickedSignOut)],
            [html.text("Sign out")],
          ),
        ]),
      ],
    ]),
  )
}

fn view_account_menu(name: String, is_open: Bool) -> Element(Message) {
  let part = attribute.data("account-menu", "part")

  html.div(
    [
      attribute.class("account-menu"),
      on_key(fn(key) {
        case key, is_open {
          "Escape", True -> Ok(UserDismissedAccountMenu)
          _, _ -> Error(Nil)
        }
      }),
      event.on("focusout", {
        let next_part =
          decode.at(["relatedTarget", "dataset", "accountMenu"], decode.string)
        use next_part <- decode.then(
          decode.one_of(decode.map(next_part, Some), [decode.success(None)]),
        )

        case next_part {
          None -> decode.success(UserLeftAccountMenu)
          Some(_) ->
            decode.failure(UserLeftAccountMenu, "focus outside the menu")
        }
      }),
    ],
    [
      html.button(
        [
          attribute.id(account_menu_button),
          part,
          attribute.aria_haspopup("menu"),
          attribute.aria_expanded(is_open),
          attribute.aria_controls("account-menu"),
          event.on_mouse_down(UserToggledAccountMenu) |> event.prevent_default,
          on_key(fn(key) {
            case key {
              "Enter" | " " -> Ok(UserToggledAccountMenu)
              "ArrowDown" -> Ok(UserOpenedAccountMenu)
              _ -> Error(Nil)
            }
          }),
        ],
        [
          html.text(name),
          html.svg(
            [
              attribute.attribute("viewBox", "0 0 16 16"),
              attribute.attribute("width", "16"),
              attribute.attribute("height", "16"),
              attribute.attribute("fill", "none"),
              attribute.attribute("stroke", "currentColor"),
              attribute.attribute("stroke-width", "1.5"),
              attribute.aria_hidden(True),
            ],
            [svg.path([attribute.attribute("d", "M4 6l4 4 4-4")])],
          ),
        ],
      ),
      case is_open {
        True ->
          html.div([attribute.id("account-menu"), attribute.role("menu")], [
            html.button(
              [
                attribute.id(sign_out_item),
                part,
                attribute.role("menuitem"),
                event.on_click(UserClickedSignOut),
              ],
              [html.text("Sign out")],
            ),
          ])
        False -> element.none()
      },
    ],
  )
}

fn on_key(
  to_message: fn(String) -> Result(Message, Nil),
) -> Attribute(Message) {
  event.advanced("keydown", {
    use key <- decode.field("key", decode.string)

    case to_message(key) {
      Ok(message) ->
        decode.success(event.handler(
          dispatch: message,
          prevent_default: True,
          stop_propagation: True,
        ))
      Error(Nil) ->
        decode.failure(
          event.handler(
            dispatch: UserLeftAccountMenu,
            prevent_default: False,
            stop_propagation: False,
          ),
          "a key the account menu responds to",
        )
    }
  })
}

fn view_page_links(
  current: Result(Section, Nil),
  current_route: Route,
) -> Element(Message) {
  case current {
    Ok(Section(label:, rest: [_, ..], ..) as section) ->
      html.nav(
        [attribute.class("page-links"), attribute.aria_label(label <> " pages")],
        list.map(route.section_pages(section), fn(page) {
          html.a(
            [route.href(page), aria_current("page", page == current_route)],
            [html.text(route.label(page))],
          )
        }),
      )

    Ok(Section(rest: [], ..)) | Error(Nil) -> element.none()
  }
}

fn view_placeholder(route: Route) -> List(Element(Message)) {
  let heading = html.h1([], [html.text(route.label(route))])

  case route {
    NotFound(uri:) -> [
      heading,
      html.p([], [
        html.text("There is nothing at "),
        html.code([], [html.text(uri.path)]),
        html.text(". "),
        html.a([route.href(Overview)], [html.text("Back to the overview")]),
      ]),
    ]

    Overview | Account(_) | Access(_) | Data(_) | Advanced(_) | Admin -> [
      heading,
    ]
  }
}

fn aria_current(value: String, is_current: Bool) -> Attribute(message) {
  case is_current {
    True -> attribute.aria_current(value)
    False -> attribute.none()
  }
}
