import homestead/browser
import homestead/layout
import homestead/reauth
import homestead/remote.{type Remote, Failed, Loaded, Loading}
import homestead/session.{type Session}
import homestead/tranquil.{type OlderApps, type Problem}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html

const switch_id = "older-apps"

pub opaque type Model {
  Model(session: Session, preference: Remote(OlderApps), action: Action)
}

type Action {
  Resting
  Saving(allowed: Bool)
  SigningInAgain(allowed: Bool, reauth: reauth.Model)
  Refused(problem: Problem)
}

pub fn init(session: Session) -> #(Model, Effect(Message)) {
  #(
    Model(session:, preference: Loading, action: Resting),
    tranquil.load(session, tranquil.older_apps(), ServerReturnedPreference),
  )
}

pub fn is_offered(model: Model) -> Bool {
  case model.preference {
    Loaded(value: preference) -> preference.has_second_step
    Loading | Failed(_) -> False
  }
}

pub opaque type Message {
  ServerReturnedPreference(result: Result(OlderApps, Problem))
  UserPickedAllowed(allowed: Bool)
  ServerSavedPreference(allowed: Bool, result: Result(Nil, Problem))
  ReauthProducedMessage(message: reauth.Message)
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  let session = model.session

  case message {
    ServerReturnedPreference(result:) -> #(
      Model(..model, preference: remote.from_result(result)),
      effect.none(),
    )

    UserPickedAllowed(allowed:) -> #(
      Model(..model, action: Saving(allowed:)),
      save(session, allowed),
    )

    ServerSavedPreference(allowed:, result: Ok(Nil)) -> #(
      Model(
        ..model,
        preference: remote.map(model.preference, fn(preference) {
          tranquil.OlderApps(..preference, allowed:)
        }),
        action: Resting,
      ),
      effect.none(),
    )

    ServerSavedPreference(
      allowed:,
      result: Error(tranquil.Refused("ReauthRequired", _)),
    ) -> {
      let #(reauth, effect) = reauth.init(session)

      #(
        Model(..model, action: SigningInAgain(allowed:, reauth:)),
        effect.map(effect, ReauthProducedMessage),
      )
    }

    ServerSavedPreference(result: Error(problem), ..) -> #(
      Model(..model, action: Refused(problem:)),
      effect.none(),
    )

    ReauthProducedMessage(message:) ->
      case model.action {
        SigningInAgain(allowed:, reauth:) -> {
          let #(reauth, effect) = reauth.update(reauth, message)

          case reauth.outcome(reauth) {
            reauth.Waiting -> #(
              Model(..model, action: SigningInAgain(allowed:, reauth:)),
              effect.map(effect, ReauthProducedMessage),
            )
            reauth.Confirmed -> #(
              Model(..model, action: Saving(allowed:)),
              save(session, allowed),
            )
            reauth.Cancelled -> #(
              Model(..model, action: Resting),
              browser.focus(layout.switch_choice_id(switch_id, allowed)),
            )
          }
        }
        Resting | Saving(_) | Refused(_) -> #(model, effect.none())
      }
  }
}

fn save(session: Session, allowed: Bool) -> Effect(Message) {
  tranquil.perform(
    session,
    tranquil.allow_older_apps(allowed),
    ServerSavedPreference(allowed, _),
  )
}

pub fn view(model: Model) -> List(Element(Message)) {
  [
    layout.block(case model.preference {
      Loading -> []
      Failed(_) -> [layout.problem("Couldn't load")]
      Loaded(value: preference) -> [
        layout.row(
          tone: layout.Plain,
          name: "Password only",
          details: [html.text("Let apps sign in with only the password")],
          actions: [
            layout.switch(
              id: switch_id,
              label: "Password-only sign-in",
              is_on: preference.allowed,
              is_disabled: case model.action {
                Saving(_) | SigningInAgain(..) -> True
                Resting | Refused(_) -> False
              },
              on_pick: UserPickedAllowed,
            ),
          ],
        ),
        case model.action {
          Refused(_) -> layout.problem("The server didn't save that")
          Resting | Saving(_) | SigningInAgain(..) -> element.none()
        },
      ]
    }),
    case model.action {
      SigningInAgain(reauth:, ..) ->
        reauth.view(reauth) |> element.map(ReauthProducedMessage)
      Resting | Saving(_) | Refused(_) -> element.none()
    },
  ]
}
