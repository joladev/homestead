import gleam/list
import gleam/string
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import homestead/browser
import homestead/confirmation
import homestead/date
import homestead/layout
import homestead/permission.{type Preset, FullAccess}
import homestead/remote.{type Remote, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{type AppPassword, type Problem}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub opaque type Model {
  Model(
    session: Session,
    local_offset: Duration,
    passwords: Remote(List(AppPassword)),
    revoking: Revoking,
    name: String,
    preset: Preset,
    creation: Creation,
  )
}

type Revoking {
  NotRevoking
  ConfirmingRevoke(password: AppPassword)
  Revoking
  RevokeRefused(problem: Problem)
}

type Creation {
  NotCreating
  Composing
  Creating
  CreationRefused(problem: Problem)
  Created(name: String, password: String, copying: Copying)
}

type Copying {
  NotCopied
  Copied
  CopyFailed
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  #(
    Model(
      session:,
      local_offset: calendar.local_offset(),
      passwords: Loading,
      revoking: NotRevoking,
      name: "",
      preset: FullAccess,
      creation: NotCreating,
    ),
    load(session),
  )
}

pub opaque type Message {
  ServerReturnedPasswords(result: Result(List(AppPassword), Problem))
  UserClickedNew
  UserCancelledNew
  UserTypedName(name: String)
  UserPickedPreset(preset: Preset)
  UserSubmittedForm
  ServerCreatedPassword(name: String, result: Result(String, Problem))
  UserClickedCopy(password: String)
  BrowserCopiedText(result: Result(Nil, Nil))
  UserClickedDone
  UserClickedRevoke(password: AppPassword)
  UserCancelledRevoke(password: AppPassword)
  UserConfirmedRevoke(password: AppPassword)
  ServerRevokedPassword(result: Result(Nil, Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    ServerReturnedPasswords(result:) -> #(
      Model(
        ..model,
        passwords: remote.from_result(result),
        revoking: case model.revoking {
          Revoking -> NotRevoking
          NotRevoking | ConfirmingRevoke(_) | RevokeRefused(_) -> model.revoking
        },
      ),
      effect.none(),
    )

    UserClickedNew -> #(
      Model(..model, creation: Composing),
      browser.focus(name_id),
    )

    UserCancelledNew -> #(
      Model(..model, name: "", preset: FullAccess, creation: NotCreating),
      browser.focus(new_button_id),
    )

    UserTypedName(name:) -> #(
      Model(..model, name:, creation: Composing),
      effect.none(),
    )

    UserPickedPreset(preset:) -> #(Model(..model, preset:), effect.none())

    UserSubmittedForm -> {
      let name = string.trim(model.name)

      #(
        Model(..model, creation: Creating),
        tranquil.perform(
          model.session,
          tranquil.create_app_password(name, permission.scopes(model.preset)),
          ServerCreatedPassword(name, _),
        ),
      )
    }

    ServerCreatedPassword(name:, result: Ok(password)) -> #(
      Model(
        ..model,
        name: "",
        preset: FullAccess,
        creation: Created(name:, password:, copying: NotCopied),
      ),
      load(model.session),
    )

    ServerCreatedPassword(result: Error(problem), ..) -> #(
      Model(..model, creation: CreationRefused(problem:)),
      effect.none(),
    )

    UserClickedCopy(password:) -> #(
      model,
      browser.copy(password, BrowserCopiedText),
    )

    BrowserCopiedText(result:) ->
      case model.creation {
        Created(name:, password:, ..) -> #(
          Model(
            ..model,
            creation: Created(name:, password:, copying: case result {
              Ok(Nil) -> Copied
              Error(Nil) -> CopyFailed
            }),
          ),
          effect.none(),
        )
        NotCreating | Composing | Creating | CreationRefused(_) -> #(
          model,
          effect.none(),
        )
      }

    UserClickedDone -> #(
      Model(..model, creation: NotCreating),
      browser.focus(new_button_id),
    )

    UserClickedRevoke(password:) -> #(
      Model(..model, revoking: ConfirmingRevoke(password:)),
      confirmation.focus_cancel(),
    )

    UserCancelledRevoke(password:) -> #(
      Model(..model, revoking: NotRevoking),
      browser.focus(revoke_button_id(password)),
    )

    UserConfirmedRevoke(password:) -> #(
      Model(..model, revoking: Revoking),
      tranquil.perform(
        model.session,
        tranquil.revoke_app_password(password.name),
        ServerRevokedPassword,
      ),
    )

    ServerRevokedPassword(result: Ok(Nil)) -> #(model, load(model.session))

    ServerRevokedPassword(result: Error(problem)) -> #(
      Model(..model, revoking: RevokeRefused(problem:)),
      effect.none(),
    )
  }
}

fn load(session: Session) -> Effect(Message) {
  tranquil.load(session, tranquil.app_passwords(), ServerReturnedPasswords)
}

const new_button_id = "new-app-password"

const name_id = "app-password-name"

fn revoke_button_id(password: AppPassword) -> String {
  "revoke-" <> password.name
}

pub fn view(model: Model) -> Element(Message) {
  layout.page([
    layout.title_section_with_actions(
      "app-passwords",
      case model.creation {
        NotCreating -> [
          html.button(
            [
              attribute.id(new_button_id),
              attribute.class("action"),
              event.on_click(UserClickedNew),
            ],
            [html.text("New app password")],
          ),
        ]
        Composing | Creating | CreationRefused(_) | Created(..) -> []
      },
      [
        layout.block(
          list.flatten([
            {
              use passwords <- layout.rows(model.passwords, placeholders: 3)

              layout.listing(
                empty: "No app passwords",
                rows: list.map(passwords, fn(item) {
                  #(item.name, view_password(item, model))
                }),
                actions: [],
              )
            },
            case model.revoking {
              RevokeRefused(_) -> [
                layout.problem("The server didn't revoke that"),
              ]
              NotRevoking | ConfirmingRevoke(_) | Revoking -> []
            },
            case model.creation {
              NotCreating -> []
              Created(name:, password:, copying:) -> [
                view_created(name, password, copying),
              ]
              Composing | Creating | CreationRefused(_) -> [view_form(model)]
            },
          ]),
        ),
      ],
    ),
  ])
}

fn view_password(password: AppPassword, model: Model) -> Element(Message) {
  case model.revoking == ConfirmingRevoke(password:) {
    True ->
      confirmation.view(
        question: "Revoke?",
        consequence: "Anything signed in with "
          <> password.name
          <> " is signed out.",
        accept: "Revoke",
        on_cancel: UserCancelledRevoke(password),
        on_accept: UserConfirmedRevoke(password),
      )

    False ->
      layout.row(
        tone: layout.Plain,
        name: password.name,
        details: [
          html.text(permission.describe(password.scopes) <> " "),
          layout.dim(
            "\u{00B7} since "
            <> date.describe(password.created, model.local_offset),
          ),
        ],
        actions: [
          html.button(
            [
              attribute.id(revoke_button_id(password)),
              attribute.class("action"),
              attribute.disabled(model.revoking == Revoking),
              event.on_click(UserClickedRevoke(password)),
            ],
            [html.text("Revoke")],
          ),
        ],
      )
  }
}

fn view_form(model: Model) -> Element(Message) {
  let is_creating = model.creation == Creating

  html.form([event.on_submit(fn(_) { UserSubmittedForm })], [
    layout.field(
      html.label([attribute.for(name_id)], [html.text("Name")]),
      html.input([
        attribute.id(name_id),
        attribute.type_("text"),
        attribute.value(model.name),
        attribute.autocomplete("off"),
        attribute.disabled(is_creating),
        event.on_input(UserTypedName),
      ]),
    ),
    layout.field(
      html.span([attribute.id("permissions-label"), attribute.class("label")], [
        html.text("Permissions"),
      ]),
      html.div(
        [
          attribute.class("choices"),
          attribute.role("radiogroup"),
          attribute.aria_labelledby("permissions-label"),
        ],
        list.map(permission.presets, fn(preset) {
          html.label([], [
            html.input([
              attribute.type_("radio"),
              attribute.name("permissions"),
              attribute.checked(preset == model.preset),
              attribute.disabled(is_creating),
              event.on_click(UserPickedPreset(preset)),
            ]),
            html.span([], [html.text(permission.label(preset))]),
          ])
        }),
      ),
    ),
    case model.creation {
      CreationRefused(problem:) -> layout.problem(describe_refusal(problem))
      NotCreating | Composing | Creating | Created(..) -> element.none()
    },
    layout.details_row([
      html.div([attribute.class("inline")], [
        html.button(
          [
            attribute.class("action primary"),
            attribute.disabled(is_creating || string.trim(model.name) == ""),
          ],
          [html.text("Create")],
        ),
        html.button(
          [
            attribute.class("action"),
            attribute.type_("button"),
            attribute.disabled(is_creating),
            event.on_click(UserCancelledNew),
          ],
          [html.text("Cancel")],
        ),
      ]),
    ]),
  ])
}

fn describe_refusal(problem: Problem) -> String {
  case problem {
    tranquil.Refused("DuplicateAppPassword", _) -> "That name is already in use"
    tranquil.Refused(_, _) | tranquil.Unreachable | tranquil.NotUnderstood ->
      tranquil.describe(problem)
  }
}

fn view_created(
  name: String,
  password: String,
  copying: Copying,
) -> Element(Message) {
  layout.row(
    tone: layout.Plain,
    name:,
    details: [
      html.code([], [html.text(password)]),
      layout.dim(" \u{00B7} shown once"),
    ],
    actions: [
      html.button(
        [attribute.class("action"), event.on_click(UserClickedCopy(password))],
        [
          html.text(case copying {
            NotCopied -> "Copy"
            Copied -> "Copied"
            CopyFailed -> "Couldn't copy"
          }),
        ],
      ),
      html.button([attribute.class("action"), event.on_click(UserClickedDone)], [
        html.text("Done"),
      ]),
    ],
  )
}
