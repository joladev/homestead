import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import homestead/browser
import homestead/confirmation
import homestead/date
import homestead/delegation/access
import homestead/layout
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{
  type AccessLevel, type Controller, type FoundController, type Problem,
}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

const add_button_id = "add-controller"

const identifier_id = "controller-handle"

pub opaque type Model {
  Model(
    session: Session,
    local_offset: Duration,
    controllers: Remote(List(Controller)),
    action: Action,
  )
}

type Action {
  Resting
  Adding(identifier: String, lookup: Lookup, level: String, is_adding: Bool)
  ConfirmingRemove(controller: Controller)
  Removing
  Refused(problem: Problem)
}

type Lookup {
  NotLooked
  Looking
  Found(controller: FoundController)
  LookupRefused(problem: Problem)
  AddRefused(controller: FoundController, problem: Problem)
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  #(
    Model(
      session:,
      local_offset: calendar.local_offset(),
      controllers: Loading,
      action: Resting,
    ),
    load(session),
  )
}

pub fn has_any(model: Model) -> Bool {
  case model.controllers {
    Loaded(value: [_, ..]) -> True
    Loaded(value: []) | Loading | Failed(_) -> False
  }
}

pub fn names(model: Model) -> List(#(String, String)) {
  case model.controllers {
    Loaded(value: controllers) ->
      list.filter_map(controllers, fn(controller) {
        option.to_result(controller.handle, Nil)
        |> result.map(fn(handle) { #(controller.did, handle) })
      })
    Loading | Failed(_) -> []
  }
}

pub opaque type Message {
  ServerReturnedControllers(result: Result(List(Controller), Problem))
  UserClickedAdd
  UserTypedIdentifier(identifier: String)
  UserSubmittedIdentifier
  ServerFoundController(result: Result(FoundController, Problem))
  UserPickedLevel(level: String)
  UserCancelledAdd
  UserConfirmedAdd(controller: FoundController, scopes: String)
  ServerAddedController(
    controller: FoundController,
    result: Result(Nil, Problem),
  )
  UserClickedRemove(controller: Controller)
  UserCancelledRemove(controller: Controller)
  UserConfirmedRemove(controller: Controller)
  ServerRemovedController(result: Result(Nil, Problem))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  let session = model.session

  case message, model.action {
    ServerReturnedControllers(result:), _ -> #(
      Model(..model, controllers: remote.from_result(result)),
      effect.none(),
    )

    UserClickedAdd, _ -> #(
      Model(
        ..model,
        action: Adding(
          identifier: "",
          lookup: NotLooked,
          level: "",
          is_adding: False,
        ),
      ),
      browser.focus(identifier_id),
    )

    UserTypedIdentifier(identifier:), Adding(level:, ..) -> #(
      Model(
        ..model,
        action: Adding(identifier:, lookup: NotLooked, level:, is_adding: False),
      ),
      effect.none(),
    )

    UserSubmittedIdentifier, Adding(identifier:, level:, ..) -> #(
      Model(
        ..model,
        action: Adding(identifier:, lookup: Looking, level:, is_adding: False),
      ),
      tranquil.load(
        session,
        tranquil.find_controller(case string.trim(identifier) {
          "@" <> handle -> handle
          handle -> handle
        }),
        ServerFoundController,
      ),
    )

    ServerFoundController(result:), Adding(identifier:, level:, ..) -> #(
      Model(
        ..model,
        action: Adding(
          identifier:,
          lookup: case result {
            Ok(controller) -> Found(controller:)
            Error(problem) -> LookupRefused(problem:)
          },
          level:,
          is_adding: False,
        ),
      ),
      case result {
        Ok(_) -> confirmation.focus_cancel()
        Error(_) -> browser.focus(identifier_id)
      },
    )

    UserPickedLevel(level:), Adding(identifier:, lookup:, ..) -> #(
      Model(
        ..model,
        action: Adding(identifier:, lookup:, level:, is_adding: False),
      ),
      effect.none(),
    )

    UserCancelledAdd, _ -> #(
      Model(..model, action: Resting),
      browser.focus(add_button_id),
    )

    UserConfirmedAdd(controller:, scopes:), Adding(identifier:, level:, ..) -> #(
      Model(
        ..model,
        action: Adding(
          identifier:,
          lookup: Found(controller:),
          level:,
          is_adding: True,
        ),
      ),
      tranquil.perform(
        session,
        tranquil.add_controller(controller.did, scopes),
        ServerAddedController(controller, _),
      ),
    )

    ServerAddedController(result: Ok(Nil), ..), _ -> #(
      Model(..model, action: Resting),
      load(session),
    )

    ServerAddedController(controller:, result: Error(problem)),
      Adding(identifier:, level:, ..)
    -> #(
      Model(
        ..model,
        action: Adding(
          identifier:,
          lookup: AddRefused(controller:, problem:),
          level:,
          is_adding: False,
        ),
      ),
      effect.none(),
    )

    UserClickedRemove(controller:), _ -> #(
      Model(..model, action: ConfirmingRemove(controller:)),
      confirmation.focus_cancel(),
    )

    UserCancelledRemove(controller:), _ -> #(
      Model(..model, action: Resting),
      browser.focus(remove_button_id(controller)),
    )

    UserConfirmedRemove(controller:), _ -> #(
      Model(..model, action: Removing),
      tranquil.perform(
        session,
        tranquil.remove_controller(controller.did),
        ServerRemovedController,
      ),
    )

    ServerRemovedController(result: Ok(Nil)), _ -> #(
      Model(..model, action: Resting),
      load(session),
    )

    ServerRemovedController(result: Error(problem)), _ -> #(
      Model(..model, action: Refused(problem:)),
      effect.none(),
    )

    UserTypedIdentifier(_), _
    | UserSubmittedIdentifier, _
    | ServerFoundController(_), _
    | UserPickedLevel(_), _
    | UserConfirmedAdd(..), _
    | ServerAddedController(..), _
    -> #(model, effect.none())
  }
}

fn load(session: Session) -> Effect(Message) {
  tranquil.load(session, tranquil.controllers(), ServerReturnedControllers)
}

fn remove_button_id(controller: Controller) -> String {
  "remove-controller-" <> controller.did
}

pub fn describe_refusal(problem: Problem) -> String {
  case problem {
    tranquil.Refused("ControllerNotFound", _) -> "No account by that name"
    tranquil.Refused("InvalidDelegation", message) if message != "" -> message
    tranquil.Refused(_, _) | tranquil.Unreachable | tranquil.NotUnderstood ->
      tranquil.describe(problem)
  }
}

pub fn view_actions(
  model: Model,
  controls_accounts: Bool,
) -> List(Element(Message)) {
  case model.controllers, model.action, controls_accounts {
    Loading, _, _ | Failed(_), _, _ | _, Adding(..), _ | _, _, True -> []
    Loaded(_), Resting, False
    | Loaded(_), ConfirmingRemove(_), False
    | Loaded(_), Removing, False
    | Loaded(_), Refused(_), False
    -> [
      html.button(
        [
          attribute.id(add_button_id),
          attribute.class("action"),
          event.on_click(UserClickedAdd),
        ],
        [html.text("Add controller")],
      ),
    ]
  }
}

pub fn view(
  model: Model,
  levels: Remote(List(AccessLevel)),
  controls_accounts: Bool,
) -> List(Element(Message)) {
  [
    layout.block(
      list.flatten([
        {
          use controllers <- layout.rows(model.controllers, placeholders: 1)
          layout.listing(
            empty: "No controllers",
            rows: list.map(controllers, fn(item) {
              #(item.did, view_controller(item, model, levels))
            }),
            actions: [],
          )
        },
        case model.action, controls_accounts {
          Adding(identifier:, lookup:, level:, is_adding:), _ ->
            view_form(identifier, lookup, level, is_adding, levels)

          Refused(problem:), _ -> [layout.problem(describe_refusal(problem))]

          Resting, True | ConfirmingRemove(_), True | Removing, True -> [
            layout.note(
              "This account controls other accounts, so it cannot have controllers",
              [],
            ),
          ]

          Resting, False | ConfirmingRemove(_), False | Removing, False -> []
        },
      ]),
    ),
  ]
}

fn view_controller(
  controller: Controller,
  model: Model,
  levels: Remote(List(AccessLevel)),
) -> Element(Message) {
  let name = option.unwrap(controller.handle, controller.did)

  case model.action == ConfirmingRemove(controller:) {
    True ->
      confirmation.view(
        question: "Remove?",
        consequence: name <> " can no longer act as this account.",
        accept: "Remove controller",
        on_cancel: UserCancelledRemove(controller),
        on_accept: UserConfirmedRemove(controller),
      )

    False ->
      layout.row(
        tone: layout.Plain,
        name:,
        details: [
          access.view_level(levels, controller.access),
          layout.dim(string.join(
            list.flatten([
              [
                "\u{00B7} since "
                <> date.describe(controller.since, model.local_offset),
              ],
              case controller.is_active {
                True -> []
                False -> ["inactive"]
              },
              case controller.is_local {
                True -> []
                False -> ["on another server"]
              },
            ]),
            " \u{00B7} ",
          )),
        ],
        actions: [
          html.button(
            [
              attribute.id(remove_button_id(controller)),
              attribute.class("action"),
              event.on_click(UserClickedRemove(controller)),
            ],
            [html.text("Remove")],
          ),
        ],
      )
  }
}

fn view_form(
  identifier: String,
  lookup: Lookup,
  level: String,
  is_adding: Bool,
  levels: Remote(List(AccessLevel)),
) -> List(Element(Message)) {
  let level = case level {
    "" -> access.first(levels)
    level -> level
  }
  let found = case lookup {
    Found(controller:) | AddRefused(controller:, ..) -> Some(controller)
    NotLooked | Looking | LookupRefused(_) -> None
  }

  list.flatten([
    [
      html.form([event.on_submit(fn(_) { UserSubmittedIdentifier })], [
        layout.field(
          html.label([attribute.for(identifier_id)], [html.text("Handle")]),
          html.div([attribute.class("inline")], [
            html.input([
              attribute.id(identifier_id),
              attribute.type_("text"),
              attribute.value(identifier),
              attribute.autocomplete("off"),
              attribute.autocapitalize("none"),
              attribute.spellcheck(False),
              attribute.disabled(lookup == Looking || is_adding),
              event.on_input(UserTypedIdentifier),
            ]),
            html.button(
              [
                attribute.class("action"),
                attribute.disabled(
                  lookup == Looking || string.trim(identifier) == "",
                ),
              ],
              [html.text("Find")],
            ),
            case found {
              Some(_) -> element.none()
              None ->
                html.button(
                  [
                    attribute.class("action"),
                    attribute.type_("button"),
                    event.on_click(UserCancelledAdd),
                  ],
                  [html.text("Cancel")],
                )
            },
          ]),
        ),
      ]),
    ],
    case lookup {
      LookupRefused(problem:) | AddRefused(problem:, ..) -> [
        layout.problem(describe_refusal(problem)),
      ]
      NotLooked | Looking | Found(_) -> []
    },
    case found {
      None -> []
      Some(controller) -> [
        layout.row(
          tone: layout.Plain,
          name: "Found",
          details: [
            html.text(option.unwrap(controller.handle, controller.did) <> " "),
            layout.dim(case controller.is_local, controller.server {
              False, Some(server) -> "\u{00B7} on " <> server
              True, _ | False, None -> ""
            }),
          ],
          actions: [],
        ),
        layout.row(
          tone: layout.Plain,
          name: "Access",
          details: [
            access.view_choice(
              id: "controller-access",
              levels:,
              picked: level,
              is_disabled: is_adding,
              on_pick: UserPickedLevel,
            ),
          ],
          actions: [],
        ),
        confirmation.view(
          question: "Add?",
          consequence: "Only the controller can sign in to this account afterwards.",
          accept: "Add controller",
          on_cancel: UserCancelledAdd,
          on_accept: UserConfirmedAdd(controller, access.scopes(levels, level)),
        ),
      ]
    },
  ])
}
