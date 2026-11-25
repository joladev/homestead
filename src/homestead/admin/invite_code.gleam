import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp
import gleam/uri
import homestead/browser
import homestead/confirmation
import homestead/date
import homestead/layout
import homestead/remote.{type Remote, Loaded, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{type InviteCode, type Problem}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

const new_button_id = "new-invite-code"

const uses_id = "new-invite-code-uses"

const copy_new_id = "copy-new-invite-code"

pub opaque type Model {
  Model(
    session: Session,
    origin: String,
    local_offset: Duration,
    is_required: Remote(Bool),
    codes: Remote(List(InviteCode)),
    created: Option(String),
    action: Action,
    copied: Copied,
  )
}

type Action {
  Resting
  Composing(uses: String)
  Creating
  ConfirmingDisable(code: InviteCode)
  Disabling
  Refused(problem: Problem)
}

type Copied {
  NothingCopied
  Copied(text: String)
  CopyFailed(text: String)
}

pub fn init(
  session: Session,
  origin: String,
  local_offset: Duration,
) -> #(Model, Effect(Message)) {
  #(
    Model(
      session:,
      origin:,
      local_offset:,
      is_required: Loading,
      codes: Loading,
      created: None,
      action: Resting,
      copied: NothingCopied,
    ),
    effect.batch([
      tranquil.load(
        session,
        tranquil.invite_codes_required(),
        ServerReturnedRequirement,
      ),
      load(session),
    ]),
  )
}

pub fn is_offered(model: Model) -> Bool {
  model.is_required == Loaded(True)
}

pub opaque type Message {
  ServerReturnedRequirement(result: Result(Bool, Problem))
  ServerReturnedCodes(result: Result(List(InviteCode), Problem))
  UserClickedNew
  UserTypedUses(uses: String)
  UserCancelledNew
  UserSubmittedNew
  ServerCreatedCode(result: Result(String, Problem))
  UserClickedDone
  UserClickedCopy(text: String)
  BrowserCopiedText(text: String, result: Result(Nil, Nil))
  UserClickedDisable(code: InviteCode)
  UserCancelledDisable(code: InviteCode)
  UserConfirmedDisable(code: InviteCode)
  ServerDisabledCode(result: Result(Nil, Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  let session = model.session

  case message {
    ServerReturnedRequirement(result:) -> #(
      Model(..model, is_required: remote.from_result(result)),
      effect.none(),
    )

    ServerReturnedCodes(result:) -> #(
      Model(
        ..model,
        codes: remote.from_result(result)
          |> remote.map(
            list.sort(_, fn(one, other) {
              timestamp.compare(other.created, one.created)
            }),
          ),
      ),
      effect.none(),
    )

    UserClickedNew -> #(
      Model(..model, action: Composing(uses: "1")),
      browser.focus(uses_id),
    )

    UserTypedUses(uses:) -> #(
      Model(..model, action: Composing(uses:)),
      effect.none(),
    )

    UserCancelledNew -> #(
      Model(..model, action: Resting),
      browser.focus(new_button_id),
    )

    UserSubmittedNew ->
      case model.action {
        Composing(uses:) ->
          case read_uses(uses) {
            Ok(uses) -> #(
              Model(..model, action: Creating),
              tranquil.perform(
                session,
                tranquil.create_invite_code(uses),
                ServerCreatedCode,
              ),
            )
            Error(Nil) -> #(model, effect.none())
          }
        Resting | Creating | ConfirmingDisable(_) | Disabling | Refused(_) -> #(
          model,
          effect.none(),
        )
      }

    ServerCreatedCode(result: Ok(code)) -> #(
      Model(
        ..model,
        created: Some(code),
        action: Resting,
        copied: NothingCopied,
      ),
      effect.batch([load(session), browser.focus(copy_new_id)]),
    )

    UserClickedDone -> #(
      Model(..model, created: None, copied: NothingCopied),
      browser.focus(new_button_id),
    )

    ServerDisabledCode(result: Ok(Nil)) -> #(
      Model(..model, action: Resting),
      load(session),
    )

    ServerCreatedCode(result: Error(problem))
    | ServerDisabledCode(result: Error(problem)) -> #(
      Model(..model, action: Refused(problem:)),
      effect.none(),
    )

    UserClickedCopy(text:) -> #(
      model,
      browser.copy(text, BrowserCopiedText(text, _)),
    )

    BrowserCopiedText(text:, result:) -> #(
      Model(..model, copied: case result {
        Ok(Nil) -> Copied(text:)
        Error(Nil) -> CopyFailed(text:)
      }),
      effect.none(),
    )

    UserClickedDisable(code:) -> #(
      Model(..model, action: ConfirmingDisable(code:)),
      confirmation.focus_cancel(),
    )

    UserCancelledDisable(code:) -> #(
      Model(..model, action: Resting),
      browser.focus(disable_button_id(code)),
    )

    UserConfirmedDisable(code:) -> #(
      Model(..model, action: Disabling),
      tranquil.perform(
        session,
        tranquil.disable_invite_code(code.code),
        ServerDisabledCode,
      ),
    )
  }
}

fn load(session: Session) -> Effect(Message) {
  tranquil.load(session, tranquil.invite_codes(), ServerReturnedCodes)
}

fn read_uses(typed: String) -> Result(Int, Nil) {
  case int.parse(string.trim(typed)) {
    Ok(uses) if uses >= 1 -> Ok(uses)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

fn disable_button_id(code: InviteCode) -> String {
  "disable-" <> code.code
}

pub fn sign_up_link(origin: String, server: String, code: String) -> String {
  origin
  <> "/sign-up?"
  <> uri.query_to_string([#("server", server), #("invite", code)])
}

fn link(model: Model, code: String) -> String {
  sign_up_link(
    model.origin,
    tranquil.server_name(session.server_address(model.session)),
    code,
  )
}

pub fn describe_state(code: InviteCode) -> String {
  case code.is_disabled, code.used_by, code.available {
    True, _, _ -> "disabled"
    False, [_, ..] as used_by, _ -> "used by " <> string.join(used_by, ", ")
    False, [], 0 -> "spent"
    False, [], _ -> "unused"
  }
}

fn can_be_used(code: InviteCode) -> Bool {
  !code.is_disabled && code.available > 0
}

pub fn view_actions(model: Model) -> List(Element(Message)) {
  [
    html.button(
      [
        attribute.id(new_button_id),
        attribute.class("action"),
        attribute.disabled(case model.action {
          Composing(_) | Creating -> True
          Resting | ConfirmingDisable(_) | Disabling | Refused(_) -> False
        }),
        event.on_click(UserClickedNew),
      ],
      [html.text("New code")],
    ),
  ]
}

pub fn view(model: Model) -> List(Element(Message)) {
  [
    layout.block(
      list.flatten([
        case model.action {
          Composing(uses:) -> [view_composing(uses)]
          Resting | Creating | ConfirmingDisable(_) | Disabling | Refused(_) -> []
        },
        case model.created {
          Some(code) -> [view_created(model, code)]
          None -> []
        },
        {
          use codes <- layout.rows(model.codes, placeholders: 3)
          layout.listing(
            empty: "No invite codes",
            rows: list.map(codes, fn(item) {
              #(item.code, view_code(item, model))
            }),
            actions: [],
          )
        },
        case model.action {
          Refused(_) -> [layout.problem("The server didn't accept that")]
          Resting
          | Composing(_)
          | Creating
          | ConfirmingDisable(_)
          | Disabling -> []
        },
      ]),
    ),
  ]
}

fn view_composing(uses: String) -> Element(Message) {
  html.form([event.on_submit(fn(_) { UserSubmittedNew })], [
    layout.field(
      html.label([attribute.for(uses_id)], [html.text("Uses")]),
      html.div([attribute.class("inline")], [
        html.input([
          attribute.id(uses_id),
          attribute.type_("number"),
          attribute.min("1"),
          attribute.value(uses),
          event.on_input(UserTypedUses),
        ]),
        html.button(
          [
            attribute.class("action"),
            attribute.disabled(read_uses(uses) == Error(Nil)),
          ],
          [html.text("Create")],
        ),
        html.button(
          [
            attribute.class("action"),
            attribute.type_("button"),
            event.on_click(UserCancelledNew),
          ],
          [html.text("Cancel")],
        ),
      ]),
    ),
  ])
}

fn view_created(model: Model, code: String) -> Element(Message) {
  layout.row(
    tone: layout.Plain,
    name: "New code",
    details: [
      html.code([], [html.text(code)]),
      layout.dim(copy_note(model, code)),
    ],
    actions: [
      html.button(
        [
          attribute.id(copy_new_id),
          attribute.class("action"),
          event.on_click(UserClickedCopy(code)),
        ],
        [html.text("Copy")],
      ),
      html.button(
        [
          attribute.class("action"),
          event.on_click(UserClickedCopy(link(model, code))),
        ],
        [html.text("Copy sign-up link")],
      ),
      html.button([attribute.class("action"), event.on_click(UserClickedDone)], [
        html.text("Done"),
      ]),
    ],
  )
}

fn copy_note(model: Model, code: String) -> String {
  let code_link = link(model, code)

  case model.copied {
    Copied(text:) if text == code -> " \u{00B7} copied"
    Copied(text:) if text == code_link -> " \u{00B7} link copied"
    CopyFailed(text:) if text == code || text == code_link ->
      " \u{00B7} couldn't copy"
    NothingCopied | Copied(_) | CopyFailed(_) -> ""
  }
}

fn view_code(code: InviteCode, model: Model) -> Element(Message) {
  case model.action == ConfirmingDisable(code:) {
    True ->
      confirmation.view(
        question: "Disable?",
        consequence: code.code <> " can no longer be used.",
        accept: "Disable code",
        on_cancel: UserCancelledDisable(code),
        on_accept: UserConfirmedDisable(code),
      )

    False ->
      layout.row(
        tone: layout.Plain,
        name: code.code,
        details: [
          html.text(describe_state(code) <> " "),
          layout.dim(
            "\u{00B7} since "
            <> date.describe(code.created, model.local_offset)
            <> case model.created == Some(code.code) {
              True -> ""
              False -> copy_note(model, code.code)
            },
          ),
        ],
        actions: case can_be_used(code) {
          False -> []
          True -> [
            html.button(
              [
                attribute.class("action"),
                event.on_click(UserClickedCopy(code.code)),
              ],
              [html.text("Copy")],
            ),
            html.button(
              [
                attribute.class("action"),
                event.on_click(UserClickedCopy(link(model, code.code))),
              ],
              [html.text("Copy sign-up link")],
            ),
            html.button(
              [
                attribute.id(disable_button_id(code)),
                attribute.class("action"),
                event.on_click(UserClickedDisable(code)),
              ],
              [html.text("Disable")],
            ),
          ]
        },
      )
  }
}
