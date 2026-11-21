import {
  CompositeDidDocumentResolver,
  LocalActorResolver,
  PlcDidDocumentResolver,
  WebDidDocumentResolver,
  WellKnownHandleResolver,
} from "@atcute/identity-resolver";
import {
  OAuthUserAgent,
  configureOAuth,
  createAuthorizationUrl,
  deleteStoredSession,
  finalizeAuthorization,
  getSession,
  listStoredSessions,
} from "@atcute/oauth-browser-client";
import { Result$Error, Result$Ok } from "../gleam.mjs";

const STORAGE_PERSIST_MILLISECONDS = 200;

export function configure(clientId, redirectUri, directory) {
  configureOAuth({
    metadata: { client_id: clientId, redirect_uri: redirectUri },
    identityResolver: new LocalActorResolver({
      handleResolver: new WellKnownHandleResolver(),
      didDocumentResolver: new CompositeDidDocumentResolver({
        methods: {
          plc: new PlcDidDocumentResolver({ apiUrl: directory }),
          web: new WebDidDocumentResolver(),
        },
      }),
    }),
  });
}

export function begin(did, scope) {
  return attempt(async () => {
    const login = await createAuthorizationUrl({
      target: { type: "account", identifier: did },
      scope,
    });
    await new Promise((resolve) =>
      setTimeout(resolve, STORAGE_PERSIST_MILLISECONDS),
    );

    return login.href;
  });
}

export function complete(answer) {
  return attempt(async () => {
    const { session } = await finalizeAuthorization(
      new URLSearchParams(answer),
    );

    return new OAuthUserAgent(session);
  });
}

export function storedAccount() {
  const [did] = listStoredSessions();

  return did === undefined ? Result$Error(undefined) : Result$Ok(did);
}

export function restore(did) {
  return attempt(async () => {
    const session = await getSession(did, { allowStale: true });

    return new OAuthUserAgent(session);
  });
}

export async function end(agent) {
  try {
    await agent.signOut();
  } catch {
    deleteStoredSession(agent.sub);
  }
}

export function get(agent, path) {
  return attempt(async () => {
    const response = await agent.handle(path);

    return [response.status, await response.text()];
  });
}

export function post(agent, path, body) {
  return attempt(async () => {
    const response = await agent.handle(path, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body,
    });

    return [response.status, await response.text()];
  });
}

export function forget(agent) {
  deleteStoredSession(agent.sub);
}

export function account(agent) {
  return agent.sub;
}

export function server(agent) {
  return new URL(agent.session.info.aud).host;
}

async function attempt(run) {
  try {
    return Result$Ok(await run());
  } catch (error) {
    return Result$Error(error instanceof Error ? error.name : String(error));
  }
}
