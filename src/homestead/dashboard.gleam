import at/did.{type Did}
import at/handle
import gleam/bool
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import homestead/admin
import homestead/app_password
import homestead/backlink
import homestead/browser
import homestead/connected_app
import homestead/delegation
import homestead/delete_account
import homestead/export
import homestead/identity_document
import homestead/label
import homestead/notification
import homestead/overview
import homestead/profile
import homestead/relay
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/repository
import homestead/route.{
  type Route, type Section, Access, Account, Admin, Advanced, AppPasswords,
  ConnectedApps, Data, NotFound, Overview, Section, Sessions, SignInMethods,
}
import homestead/session.{type Departure, type Session, type StoredAccount}
import homestead/sessions
import homestead/setting.{type Settings}
import homestead/sign_in
import homestead/sign_in_method
import homestead/tranquil.{type Problem}
import lustre/attribute.{type Attribute}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
import modem

pub opaque type Model {
  Model(
    session: Session,
    settings: Settings,
    route: Route,
    page: Page,
    account: Remote(tranquil.Account),
    other_accounts: List(StoredAccount),
    is_account_menu_open: Bool,
    is_menu_open: Bool,
    departure: Option(Departure),
  )
}

type Page {
  OverviewPage(overview.Model)
  SessionsPage(sessions.Model)
  ConnectedAppsPage(connected_app.Model)
  AppPasswordsPage(app_password.Model)
  ProfilePage(profile.Model)
  NotificationsPage(notification.Model)
  SignInMethodsPage(sign_in_method.Model)
  ExportPage(export.Model)
  LabelsPage(label.Model)
  RelaysPage(relay.Model)
  BacklinkPage(backlink.Model)
  DeleteAccountPage(delete_account.Model)
  RepositoryPage(repository.Model)
  DelegationPage(delegation.Model)
  IdentityDocumentPage(identity_document.Model)
  AdminPage(admin.Model)
  PlaceholderPage
}

pub fn init(
  session: Session,
  settings: Settings,
  route: Route,
) -> #(Model, Effect(Message)) {
  let #(page, effect) = open(session, settings, route)

  #(
    Model(
      session:,
      settings:,
      route:,
      page:,
      account: Loading,
      other_accounts: list.filter(session.stored_accounts(), fn(account) {
        account.account != session.account(session)
      }),
      is_account_menu_open: False,
      is_menu_open: False,
      departure: None,
    ),
    effect.batch([
      tranquil.load(session, tranquil.account(), ServerReturnedAccount),
      effect,
    ]),
  )
}

pub fn show(model: Model, route: Route) -> #(Model, Effect(Message)) {
  use <- bool.guard(is_closed(route, model.account), #(model, show_overview()))
  let #(page, effect) = open(model.session, model.settings, route)

  #(Model(..model, route:, page:, is_menu_open: False), effect)
}

fn is_closed(route: Route, account: Remote(tranquil.Account)) -> Bool {
  case account, route {
    Loaded(tranquil.Account(is_admin: False, ..)), Admin(_) -> True
    Loaded(_), _ | Loading, _ | Failed(_), _ -> False
  }
}

fn sections(account: Remote(tranquil.Account)) -> List(Section) {
  case account {
    Loaded(tranquil.Account(is_admin: True, ..)) ->
      list.append(route.sections, [route.admin_section])
    Loaded(tranquil.Account(is_admin: False, ..)) | Loading | Failed(_) ->
      route.sections
  }
}

fn show_overview() -> Effect(Message) {
  modem.replace(route.to_path(Overview), None, None)
}

fn open(
  session: Session,
  settings: Settings,
  route: Route,
) -> #(Page, Effect(Message)) {
  case route {
    Overview -> {
      let #(page, effect) = overview.init(session, settings)

      #(OverviewPage(page), effect.map(effect, OverviewProducedMessage))
    }

    Access(Sessions) -> {
      let #(page, effect) = sessions.init(session, sessions.Everything)

      #(SessionsPage(page), effect.map(effect, SessionsProducedMessage))
    }

    Access(ConnectedApps) -> {
      let #(page, effect) = connected_app.init(session)

      #(
        ConnectedAppsPage(page),
        effect.map(effect, ConnectedAppsProducedMessage),
      )
    }

    Access(AppPasswords) -> {
      let #(page, effect) = app_password.init(session)

      #(AppPasswordsPage(page), effect.map(effect, AppPasswordsProducedMessage))
    }

    Account(route.Profile) -> {
      let #(page, effect) = profile.init(session, settings)

      #(ProfilePage(page), effect.map(effect, ProfileProducedMessage))
    }

    Account(route.Notifications) -> {
      let #(page, effect) = notification.init(session)

      #(
        NotificationsPage(page),
        effect.map(effect, NotificationsProducedMessage),
      )
    }

    Access(SignInMethods) -> {
      let #(page, effect) = sign_in_method.init(session)

      #(
        SignInMethodsPage(page),
        effect.map(effect, SignInMethodsProducedMessage),
      )
    }

    Account(route.DeleteAccount) -> {
      let #(page, effect) = delete_account.init(session)

      #(
        DeleteAccountPage(page),
        effect.map(effect, DeleteAccountProducedMessage),
      )
    }

    Data(route.Export) -> {
      let #(page, effect) = export.init(session)

      #(ExportPage(page), effect.map(effect, ExportProducedMessage))
    }

    Data(route.Labels) -> {
      let #(page, effect) = label.init(session, settings)

      #(LabelsPage(page), effect.map(effect, LabelsProducedMessage))
    }

    Data(route.Relays) -> {
      let #(page, effect) = relay.init(session, settings)

      #(RelaysPage(page), effect.map(effect, RelaysProducedMessage))
    }

    Data(route.Backlinks(location:)) -> {
      let #(page, effect) = backlink.init(session, settings, location)

      #(BacklinkPage(page), effect.map(effect, BacklinkProducedMessage))
    }

    Data(route.Repository(location:)) -> {
      let #(page, effect) = repository.init(session, settings, location)

      #(RepositoryPage(page), effect.map(effect, RepositoryProducedMessage))
    }

    Advanced(route.Delegation) -> {
      let #(page, effect) = delegation.init(session)

      #(DelegationPage(page), effect.map(effect, DelegationProducedMessage))
    }

    Advanced(route.IdentityDocument) -> {
      let #(page, effect) = identity_document.init(session, settings)

      #(
        IdentityDocumentPage(page),
        effect.map(effect, IdentityDocumentProducedMessage),
      )
    }

    Admin(page) -> {
      let #(page, effect) = admin.init(session, settings, page)

      #(AdminPage(page), effect.map(effect, AdminProducedMessage))
    }

    NotFound(_) -> #(PlaceholderPage, effect.none())
  }
}

pub fn account(model: Model) -> Did {
  session.account(model.session)
}

pub fn route(model: Model) -> Route {
  model.route
}

pub fn departure(model: Model) -> Option(Departure) {
  case model.departure, model.page {
    Some(departure), _ -> Some(departure)
    None, SessionsPage(page) -> sessions.departure(page)
    None, ConnectedAppsPage(page) -> connected_app.departure(page)
    None, DeleteAccountPage(page) -> delete_account.departure(page)
    None, OverviewPage(_)
    | None, AppPasswordsPage(_)
    | None, ProfilePage(_)
    | None, NotificationsPage(_)
    | None, SignInMethodsPage(_)
    | None, ExportPage(_)
    | None, LabelsPage(_)
    | None, RelaysPage(_)
    | None, BacklinkPage(_)
    | None, RepositoryPage(_)
    | None, DelegationPage(_)
    | None, IdentityDocumentPage(_)
    | None, AdminPage(_)
    | None, PlaceholderPage
    -> None
  }
}

pub opaque type Message {
  ServerReturnedAccount(result: Result(tranquil.Account, Problem))
  OverviewProducedMessage(overview.Message)
  SessionsProducedMessage(sessions.Message)
  ConnectedAppsProducedMessage(connected_app.Message)
  AppPasswordsProducedMessage(app_password.Message)
  ProfileProducedMessage(profile.Message)
  NotificationsProducedMessage(notification.Message)
  SignInMethodsProducedMessage(sign_in_method.Message)
  ExportProducedMessage(export.Message)
  LabelsProducedMessage(label.Message)
  RelaysProducedMessage(relay.Message)
  BacklinkProducedMessage(backlink.Message)
  DeleteAccountProducedMessage(delete_account.Message)
  RepositoryProducedMessage(repository.Message)
  DelegationProducedMessage(delegation.Message)
  IdentityDocumentProducedMessage(identity_document.Message)
  AdminProducedMessage(admin.Message)
  UserToggledMenu
  UserDismissedMenu
  UserToggledAccountMenu
  UserOpenedAccountMenu
  UserDismissedAccountMenu
  UserLeftAccountMenu
  UserMovedInAccountMenu(to: Int)
  UserPickedAccount(did: Did)
  UserClickedSignOut
  ServerEndedSession
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message, model.page {
    ServerReturnedAccount(result:), _ -> {
      let account = remote.from_result(result)

      #(
        Model(..model, account:),
        effect.batch([
          remember_handle(model.session, account),
          case is_closed(model.route, account) {
            True -> show_overview()
            False -> effect.none()
          },
        ]),
      )
    }

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
      let #(page, effect) = connected_app.update(page, message)

      #(
        Model(..model, page: ConnectedAppsPage(page)),
        effect.map(effect, ConnectedAppsProducedMessage),
      )
    }

    AppPasswordsProducedMessage(message), AppPasswordsPage(page) -> {
      let #(page, effect) = app_password.update(page, message)

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
        effect.batch([
          effect.map(effect, ProfileProducedMessage),
          case account == model.account {
            True -> effect.none()
            False -> remember_handle(model.session, account)
          },
        ]),
      )
    }

    NotificationsProducedMessage(message), NotificationsPage(page) -> {
      let #(page, effect) = notification.update(page, message)

      #(
        Model(..model, page: NotificationsPage(page)),
        effect.map(effect, NotificationsProducedMessage),
      )
    }

    SignInMethodsProducedMessage(message), SignInMethodsPage(page) -> {
      let #(page, effect) = sign_in_method.update(page, message)

      #(
        Model(..model, page: SignInMethodsPage(page)),
        effect.map(effect, SignInMethodsProducedMessage),
      )
    }

    ExportProducedMessage(message), ExportPage(page) -> {
      let #(page, effect) = export.update(page, message)

      #(
        Model(..model, page: ExportPage(page)),
        effect.map(effect, ExportProducedMessage),
      )
    }

    BacklinkProducedMessage(message), BacklinkPage(page) -> {
      let #(page, effect) = backlink.update(page, message)

      #(
        Model(..model, page: BacklinkPage(page)),
        effect.map(effect, BacklinkProducedMessage),
      )
    }

    RelaysProducedMessage(message), RelaysPage(page) -> {
      let #(page, effect) = relay.update(page, message)

      #(
        Model(..model, page: RelaysPage(page)),
        effect.map(effect, RelaysProducedMessage),
      )
    }

    LabelsProducedMessage(message), LabelsPage(page) -> {
      let #(page, effect) = label.update(page, message)

      #(
        Model(..model, page: LabelsPage(page)),
        effect.map(effect, LabelsProducedMessage),
      )
    }

    DeleteAccountProducedMessage(message), DeleteAccountPage(page) -> {
      let #(page, effect) = delete_account.update(page, message)

      #(
        Model(..model, page: DeleteAccountPage(page)),
        effect.map(effect, DeleteAccountProducedMessage),
      )
    }

    RepositoryProducedMessage(message), RepositoryPage(page) -> {
      let #(page, effect) = repository.update(page, message)

      #(
        Model(..model, page: RepositoryPage(page)),
        effect.map(effect, RepositoryProducedMessage),
      )
    }

    DelegationProducedMessage(message), DelegationPage(page) -> {
      let #(page, effect) = delegation.update(page, message)

      #(
        Model(..model, page: DelegationPage(page)),
        effect.map(effect, DelegationProducedMessage),
      )
    }

    IdentityDocumentProducedMessage(message), IdentityDocumentPage(page) -> {
      let #(page, effect) = identity_document.update(page, message)

      #(
        Model(..model, page: IdentityDocumentPage(page)),
        effect.map(effect, IdentityDocumentProducedMessage),
      )
    }

    AdminProducedMessage(message), AdminPage(page) -> {
      let #(page, effect) = admin.update(page, message)

      #(
        Model(..model, page: AdminPage(page)),
        effect.map(effect, AdminProducedMessage),
      )
    }

    OverviewProducedMessage(_), _
    | ProfileProducedMessage(_), _
    | AdminProducedMessage(_), _
    | IdentityDocumentProducedMessage(_), _
    | DelegationProducedMessage(_), _
    | RepositoryProducedMessage(_), _
    | DeleteAccountProducedMessage(_), _
    | ExportProducedMessage(_), _
    | LabelsProducedMessage(_), _
    | RelaysProducedMessage(_), _
    | BacklinkProducedMessage(_), _
    | SignInMethodsProducedMessage(_), _
    | NotificationsProducedMessage(_), _
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
          browser.focus(account_menu_item(0)),
        )
      }

    UserOpenedAccountMenu, _ -> #(
      Model(..model, is_account_menu_open: True),
      browser.focus(account_menu_item(0)),
    )

    UserMovedInAccountMenu(to:), _ -> #(
      model,
      browser.focus(account_menu_item(to)),
    )

    UserPickedAccount(did:), _ -> #(
      Model(..model, departure: Some(session.SwitchedAccount(account: did))),
      effect.none(),
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
      Model(..model, departure: Some(session.SignedOut)),
      effect.none(),
    )
  }
}

fn remember_handle(
  session: Session,
  account: Remote(tranquil.Account),
) -> Effect(Message) {
  use _ <- effect.from

  case account {
    Loaded(value: account) -> session.remember_handle(session, account.handle)
    Loading | Failed(_) -> Nil
  }
}

fn end_session(session: Session) -> Effect(Message) {
  browser.await(fn() { session.end(session) }, fn(_) { ServerEndedSession })
}

const menu_button = "menu-button"

const first_menu_link = "menu-first-link"

const account_menu_button = "account-menu-button"

fn account_menu_item(index: Int) -> String {
  "account-menu-item-" <> int.to_string(index)
}

pub fn view(model: Model) -> Element(Message) {
  let current_section =
    list.find(sections(model.account), fn(section) {
      list.contains(route.section_pages(section), route.page(model.route))
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
        connected_app.view(page) |> element.map(ConnectedAppsProducedMessage)

      AppPasswordsPage(page) ->
        app_password.view(page) |> element.map(AppPasswordsProducedMessage)

      ProfilePage(page) ->
        profile.view(page) |> element.map(ProfileProducedMessage)

      NotificationsPage(page) ->
        notification.view(page) |> element.map(NotificationsProducedMessage)

      SignInMethodsPage(page) ->
        sign_in_method.view(page)
        |> element.map(SignInMethodsProducedMessage)

      ExportPage(page) ->
        export.view(page) |> element.map(ExportProducedMessage)

      LabelsPage(page) -> label.view(page) |> element.map(LabelsProducedMessage)

      RelaysPage(page) -> relay.view(page) |> element.map(RelaysProducedMessage)

      BacklinkPage(page) ->
        backlink.view(page) |> element.map(BacklinkProducedMessage)

      DeleteAccountPage(page) ->
        delete_account.view(page) |> element.map(DeleteAccountProducedMessage)

      RepositoryPage(page) ->
        repository.view(page) |> element.map(RepositoryProducedMessage)

      DelegationPage(page) ->
        delegation.view(page) |> element.map(DelegationProducedMessage)

      IdentityDocumentPage(page) ->
        identity_document.view(page)
        |> element.map(IdentityDocumentProducedMessage)

      AdminPage(page) -> admin.view(page) |> element.map(AdminProducedMessage)

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
    list.map(sections(model.account), fn(section) {
      html.a(
        [
          route.href(section.first),
          attribute.data("label", section.label),
          aria_current(value: "true", is_current: current == Ok(section)),
        ],
        [html.text(section.label)],
      )
    })
  let account_name = case model.account {
    Loaded(value: account) -> Ok("@" <> handle.to_string(account.handle))
    Failed(_) -> Ok(did.to_string(session.account(model.session)))
    Loading -> Error(Nil)
  }

  html.header([attribute.class("top-bar")], [
    html.a([attribute.class("brand"), route.href(Overview)], [
      html.text("Homestead"),
    ]),
    html.nav([attribute.aria_label("Sections")], section_links),
    case account_name {
      Ok(name) ->
        view_account_menu(
          name,
          model.other_accounts,
          model.is_account_menu_open,
        )
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
        aria_current(value: "page", is_current: page == route.page(model.route)),
        ..attributes
      ],
      [html.text(route.label(page))],
    )
  }
  let groups =
    list.map(sections(model.account), fn(section) {
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
        case model.other_accounts {
          [] -> element.none()
          [_, ..] as others ->
            html.div([], [
              html.span([], [html.text("Switch account")]),
              ..list.map(others, fn(account) {
                html.button(
                  [event.on_click(UserPickedAccount(account.account))],
                  [
                    html.text(session.account_name(account)),
                  ],
                )
              })
            ])
        },
        html.a([attribute.href(sign_in.path)], [
          html.text("Add another account"),
        ]),
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

fn view_account_menu(
  name: String,
  others: List(StoredAccount),
  is_open: Bool,
) -> Element(Message) {
  let part = attribute.data("account-menu", "part")
  let items =
    list.flatten([
      list.map(others, fn(account) {
        fn(attributes) {
          html.button(
            [
              attribute.class("handle"),
              event.on_click(UserPickedAccount(account.account)),
              ..attributes
            ],
            [html.text(session.account_name(account))],
          )
        }
      }),
      [
        fn(attributes) {
          html.a([attribute.href(sign_in.path), ..attributes], [
            html.text("Add another account"),
          ])
        },
        fn(attributes) {
          html.button([event.on_click(UserClickedSignOut), ..attributes], [
            html.text("Sign out"),
          ])
        },
      ],
    ])
  let count = list.length(items)

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
          html.div(
            [attribute.id("account-menu"), attribute.role("menu")],
            list.index_map(items, fn(item, index) {
              item([
                attribute.id(account_menu_item(index)),
                part,
                attribute.role("menuitem"),
                on_key(fn(key) {
                  case key {
                    "ArrowDown" ->
                      Ok(UserMovedInAccountMenu(to: { index + 1 } % count))
                    "ArrowUp" ->
                      Ok(UserMovedInAccountMenu(
                        to: { index + count - 1 } % count,
                      ))
                    _ -> Error(Nil)
                  }
                }),
              ])
            }),
          )
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
            [
              route.href(page),
              aria_current(
                value: "page",
                is_current: page == route.page(current_route),
              ),
            ],
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

    Overview | Account(_) | Access(_) | Data(_) | Advanced(_) | Admin(_) -> [
      heading,
    ]
  }
}

fn aria_current(
  value value: String,
  is_current is_current: Bool,
) -> Attribute(message) {
  case is_current {
    True -> attribute.aria_current(value)
    False -> attribute.none()
  }
}
