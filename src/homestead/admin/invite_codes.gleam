import gleam/list
import gleam/string
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import homestead/browser
import homestead/confirmation
import homestead/date
import homestead/layout
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{type InviteCode, type Problem}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

const new_button_id = "new-invite-code"

pub opaque type Model {
  Model(
    session: Session,
    local_offset: Duration,
    is_required: Remote(Bool),
    codes: Remote(List(InviteCode)),
    action: Action,
    copied: Copied,
  )
}

type Action {
  Resting
  Creating
  ConfirmingDisable(code: InviteCode)
  Disabling
  Refused(problem: Problem)
}

type Copied {
  NothingCopied
  Copied(code: String)
  CopyFailed(code: String)
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  #(
    Model(
      session:,
      local_offset: calendar.local_offset(),
      is_required: Loading,
      codes: Loading,
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
  ServerCreatedCode(result: Result(String, Problem))
  UserClickedCopy(code: String)
  BrowserCopiedText(code: String, result: Result(Nil, Nil))
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
      Model(..model, codes: remote.from_result(result)),
      effect.none(),
    )

    UserClickedNew -> #(
      Model(..model, action: Creating),
      tranquil.perform(
        session,
        tranquil.create_invite_code(),
        ServerCreatedCode,
      ),
    )

    ServerCreatedCode(result: Ok(_)) | ServerDisabledCode(result: Ok(Nil)) -> #(
      Model(..model, action: Resting),
      load(session),
    )

    ServerCreatedCode(result: Error(problem))
    | ServerDisabledCode(result: Error(problem)) -> #(
      Model(..model, action: Refused(problem:)),
      effect.none(),
    )

    UserClickedCopy(code:) -> #(
      model,
      browser.copy(code, BrowserCopiedText(code, _)),
    )

    BrowserCopiedText(code:, result:) -> #(
      Model(..model, copied: case result {
        Ok(Nil) -> Copied(code:)
        Error(Nil) -> CopyFailed(code:)
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

fn disable_button_id(code: InviteCode) -> String {
  "disable-" <> code.code
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
  case model.codes {
    Loaded(_) -> [
      html.button(
        [
          attribute.id(new_button_id),
          attribute.class("action"),
          attribute.disabled(model.action == Creating),
          event.on_click(UserClickedNew),
        ],
        [html.text("New code")],
      ),
    ]
    Loading | Failed(_) -> []
  }
}

pub fn view(model: Model) -> List(Element(Message)) {
  [
    layout.block(
      list.flatten([
        case model.codes {
          Loading -> [layout.loading(3)]
          Failed(_) -> [layout.problem("Couldn't load")]
          Loaded(value: codes) ->
            layout.listing(
              empty: "No invite codes",
              rows: list.map(codes, view_code(_, model)),
              actions: [],
            )
        },
        case model.action {
          Refused(_) -> [layout.problem("The server didn't accept that")]
          Resting | Creating | ConfirmingDisable(_) | Disabling -> []
        },
      ]),
    ),
  ]
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
            <> case model.copied {
              Copied(code: copied) if copied == code.code -> " \u{00B7} copied"
              CopyFailed(code: copied) if copied == code.code ->
                " \u{00B7} couldn't copy"
              NothingCopied | Copied(_) | CopyFailed(_) -> ""
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
