import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import homestead/browser.{type File}
import homestead/layout
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{type Problem, type ServerPage, ServerPage}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub opaque type Model {
  Model(session: Session, form: Remote(Form), submission: Submission)
}

type Form {
  Form(page: ServerPage, logo: Logo)
}

type Logo {
  Unchanged
  Chosen(file: File)
  Removed
}

type Colour {
  Primary
  PrimaryDark
  Secondary
  SecondaryDark
}

type Submission {
  Idle
  Sending
  Saved
  Refused(problem: Problem)
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  #(Model(session:, form: Loading, submission: Idle), load(session))
}

pub opaque type Message {
  ServerReturnedPage(result: Result(ServerPage, Problem))
  UserTypedName(name: String)
  UserTypedColour(colour: Colour, value: String)
  UserChoseLogo(file: File)
  UserRemovedLogo
  UserSubmittedForm
  ServerStoredLogo(result: Result(String, Problem))
  ServerSavedPage(result: Result(Nil, Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  let session = model.session
  let edit = fn(with: fn(Form) -> Form) {
    #(
      Model(..model, form: remote.map(model.form, with), submission: Idle),
      effect.none(),
    )
  }

  case message {
    ServerReturnedPage(result:) -> #(
      Model(
        ..model,
        form: remote.from_result(result)
          |> remote.map(fn(page) { Form(page:, logo: Unchanged) }),
      ),
      effect.none(),
    )

    UserTypedName(name:) ->
      edit(fn(form) { Form(..form, page: ServerPage(..form.page, name:)) })

    UserTypedColour(colour:, value:) ->
      edit(fn(form) {
        Form(..form, page: case colour {
          Primary -> ServerPage(..form.page, primary: value)
          PrimaryDark -> ServerPage(..form.page, primary_dark: value)
          Secondary -> ServerPage(..form.page, secondary: value)
          SecondaryDark -> ServerPage(..form.page, secondary_dark: value)
        })
      })

    UserChoseLogo(file:) -> edit(fn(form) { Form(..form, logo: Chosen(file:)) })

    UserRemovedLogo -> edit(fn(form) { Form(..form, logo: Removed) })

    UserSubmittedForm ->
      case model.form {
        Loaded(value: Form(page:, logo:)) -> #(
          Model(..model, submission: Sending),
          case logo {
            Chosen(file:) ->
              tranquil.upload_media(session, file, ServerStoredLogo)
            Unchanged -> save(session, page)
            Removed -> save(session, ServerPage(..page, logo: None))
          },
        )
        Loading | Failed(_) -> #(model, effect.none())
      }

    ServerStoredLogo(result: Ok(logo)) ->
      case model.form {
        Loaded(value: Form(page:, ..)) -> #(
          model,
          save(session, ServerPage(..page, logo: Some(logo))),
        )
        Loading | Failed(_) -> #(model, effect.none())
      }

    ServerStoredLogo(result: Error(problem))
    | ServerSavedPage(result: Error(problem)) -> #(
      Model(..model, submission: Refused(problem:)),
      effect.none(),
    )

    ServerSavedPage(result: Ok(Nil)) -> #(
      Model(..model, submission: Saved),
      load(session),
    )
  }
}

fn load(session: Session) -> Effect(Message) {
  tranquil.load(session, tranquil.server_page(), ServerReturnedPage)
}

fn save(session: Session, page: ServerPage) -> Effect(Message) {
  tranquil.perform(
    session,
    tranquil.save_server_page(ServerPage(
      name: string.trim(page.name),
      primary: string.trim(page.primary),
      primary_dark: string.trim(page.primary_dark),
      secondary: string.trim(page.secondary),
      secondary_dark: string.trim(page.secondary_dark),
      logo: page.logo,
    )),
    ServerSavedPage,
  )
}

pub fn describe_refusal(problem: Problem) -> String {
  case problem {
    tranquil.Refused(_, message) if message != "" -> message
    tranquil.Refused(_, _) | tranquil.Unreachable | tranquil.NotUnderstood ->
      tranquil.describe(problem)
  }
}

pub fn view(model: Model) -> List(Element(Message)) {
  [
    layout.block({
      use form <- layout.rows(model.form, placeholders: 3)
      [view_form(form, model.submission)]
    }),
  ]
}

fn view_form(form: Form, submission: Submission) -> Element(Message) {
  let is_sending = submission == Sending
  let page = form.page
  let colours = [
    #(Primary, "primary", page.primary),
    #(PrimaryDark, "primary, dark", page.primary_dark),
    #(Secondary, "secondary", page.secondary),
    #(SecondaryDark, "secondary, dark", page.secondary_dark),
  ]

  let choose_logo =
    html.label([attribute.class("action file")], [
      html.text("Choose file"),
      html.input([
        attribute.type_("file"),
        attribute.accept(["image/*"]),
        attribute.disabled(is_sending),
        event.on("change", decode.map(browser.file_decoder(), UserChoseLogo)),
      ]),
    ])
  let remove_logo =
    html.button(
      [
        attribute.class("action"),
        attribute.type_("button"),
        attribute.disabled(is_sending),
        event.on_click(UserRemovedLogo),
      ],
      [html.text("Remove")],
    )
  let #(logo, actions) = case form.logo, page.logo {
    Chosen(file:), _ -> #([html.text(browser.file_name(file))], [
      choose_logo,
      remove_logo,
    ])
    Unchanged, Some(_) -> #([html.text("set")], [choose_logo, remove_logo])
    Removed, _ | Unchanged, None -> #([choose_logo], [])
  }

  html.form([event.on_submit(fn(_) { UserSubmittedForm })], [
    layout.field(
      html.label([attribute.for("server-name")], [html.text("Name")]),
      html.input([
        attribute.id("server-name"),
        attribute.type_("text"),
        attribute.value(page.name),
        attribute.autocomplete("off"),
        attribute.disabled(is_sending),
        event.on_input(UserTypedName),
      ]),
    ),
    layout.field(
      html.span([attribute.class("label")], [html.text("Colours")]),
      html.div([attribute.class("inline colours")], [
        element.fragment(
          list.map(colours, fn(colour) {
            let #(which, name, value) = colour

            html.input([
              attribute.type_("text"),
              attribute.aria_label("Colour, " <> name),
              attribute.placeholder(name),
              attribute.value(value),
              attribute.autocomplete("off"),
              attribute.spellcheck(False),
              attribute.disabled(is_sending),
              event.on_input(UserTypedColour(which, _)),
            ])
          }),
        ),
        layout.dim("#RRGGBB \u{00B7} empty for the default"),
      ]),
    ),
    layout.row(tone: layout.Plain, name: "Logo", details: logo, actions:),
    case submission {
      Refused(problem:) -> layout.problem(describe_refusal(problem))
      Idle | Sending | Saved -> element.none()
    },
    layout.details_row([
      html.div([attribute.class("inline")], [
        html.button(
          [attribute.class("action primary"), attribute.disabled(is_sending)],
          [html.text("Save")],
        ),
        case submission {
          Saved -> layout.dim("saved")
          Idle | Sending | Refused(_) -> element.none()
        },
      ]),
    ]),
  ])
}
