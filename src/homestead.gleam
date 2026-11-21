import gleam/list
import gleam/uri.{type Uri}
import homestead/route.{
  type Route, Access, Account, Advanced, AppPasswords, ConnectedApps, Data,
  Delegation, Export, IdentityDocument, NotFound, Notifications, Overview,
  Profile, Repository, Sessions, SignInMethods,
}
import lustre
import lustre/attribute.{type Attribute}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import modem

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}

type Model {
  Model(route: Route)
}

fn init(_arguments: Nil) -> #(Model, Effect(Message)) {
  let assert Ok(uri) = modem.initial_uri()

  #(Model(route: route.from_uri(uri)), modem.init(on_url_change))
}

fn on_url_change(uri: Uri) -> Message {
  UserNavigatedTo(route: route.from_uri(uri))
}

type Message {
  UserNavigatedTo(route: Route)
}

fn update(_model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    UserNavigatedTo(route:) -> #(Model(route:), effect.none())
  }
}

type Section {
  Section(label: String, first: Route, rest: List(Route))
}

const sections = [
  Section(label: "Overview", first: Overview, rest: []),
  Section(
    label: "Account",
    first: Account(Profile),
    rest: [
      Account(Notifications),
    ],
  ),
  Section(
    label: "Access",
    first: Access(SignInMethods),
    rest: [
      Access(Sessions),
      Access(ConnectedApps),
      Access(AppPasswords),
    ],
  ),
  Section(label: "Data", first: Data(Export), rest: [Data(Repository)]),
  Section(
    label: "Advanced",
    first: Advanced(Delegation),
    rest: [
      Advanced(IdentityDocument),
    ],
  ),
]

fn section_pages(section: Section) -> List(Route) {
  [section.first, ..section.rest]
}

fn page_label(route: Route) -> String {
  case route {
    Overview -> "Overview"
    Account(Profile) -> "Profile and contact"
    Account(Notifications) -> "Notifications"
    Access(SignInMethods) -> "Sign-in methods"
    Access(Sessions) -> "Sessions"
    Access(ConnectedApps) -> "Connected apps"
    Access(AppPasswords) -> "App passwords"
    Data(Export) -> "Export and move"
    Data(Repository) -> "Repository"
    Advanced(Delegation) -> "Delegation"
    Advanced(IdentityDocument) -> "Identity document"
    NotFound(_) -> "Page not found"
  }
}

fn view(model: Model) -> Element(Message) {
  let current_section =
    list.find(sections, fn(section) {
      list.contains(section_pages(section), model.route)
    })

  element.fragment([
    view_top_bar(current_section),
    view_page_links(current_section, model.route),
    html.main([attribute.class("page")], view_page(model.route)),
  ])
}

fn view_top_bar(current: Result(Section, Nil)) -> Element(message) {
  html.header([attribute.class("top-bar")], [
    html.a([attribute.class("brand"), route.href(Overview)], [
      html.text("Homestead"),
    ]),
    html.nav(
      [attribute.aria_label("Sections")],
      list.map(sections, fn(section) {
        html.a(
          [
            route.href(section.first),
            aria_current("true", current == Ok(section)),
          ],
          [html.text(section.label)],
        )
      }),
    ),
  ])
}

fn view_page_links(
  current: Result(Section, Nil),
  current_route: Route,
) -> Element(message) {
  case current {
    Ok(Section(label:, rest: [_, ..], ..) as section) ->
      html.nav(
        [attribute.class("page-links"), attribute.aria_label(label <> " pages")],
        list.map(section_pages(section), fn(page) {
          html.a(
            [route.href(page), aria_current("page", page == current_route)],
            [html.text(page_label(page))],
          )
        }),
      )

    Ok(Section(rest: [], ..)) | Error(Nil) -> element.none()
  }
}

fn view_page(route: Route) -> List(Element(message)) {
  case route {
    NotFound(uri:) -> [
      html.h1([], [html.text(page_label(route))]),
      html.p([], [
        html.text("There is nothing at "),
        html.code([], [html.text(uri.path)]),
        html.text(". "),
        html.a([route.href(Overview)], [html.text("Back to the overview")]),
      ]),
    ]

    Overview | Account(_) | Access(_) | Data(_) | Advanced(_) -> [
      html.h1([], [html.text(page_label(route))]),
    ]
  }
}

fn aria_current(value: String, is_current: Bool) -> Attribute(message) {
  case is_current {
    True -> attribute.aria_current(value)
    False -> attribute.none()
  }
}
