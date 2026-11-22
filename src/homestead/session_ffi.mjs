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
const CURRENT_ACCOUNT = "homestead:current-account";

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

    localStorage.setItem(CURRENT_ACCOUNT, session.info.sub);

    return new OAuthUserAgent(session);
  });
}

export function actAs(agent, did, scope) {
  return attempt(async () => {
    const login = await createAuthorizationUrl({
      target: { type: "account", identifier: did },
      scope,
    });
    const response = await agent.handle("/oauth/delegation/auth-token", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        request_uri: login.searchParams.get("request_uri"),
        delegated_did: did,
      }),
    });
    const answer = await response.json();

    if (!response.ok || !answer.redirect_uri) {
      const refusal = new Error(answer.error);
      refusal.name = "ActAsRefused";
      throw refusal;
    }

    await new Promise((resolve) =>
      setTimeout(resolve, STORAGE_PERSIST_MILLISECONDS),
    );

    return new URL(answer.redirect_uri, agent.session.info.aud).href;
  });
}

export function storedAccount() {
  const stored = listStoredSessions();
  const current = localStorage.getItem(CURRENT_ACCOUNT);
  const did = stored.includes(current) ? current : stored[0];

  return did === undefined ? Result$Error(undefined) : Result$Ok(did);
}

export function restore(did) {
  return attempt(async () => {
    const session = await getSession(did, { allowStale: true });

    localStorage.setItem(CURRENT_ACCOUNT, did);

    return new OAuthUserAgent(session);
  });
}

export async function end(agent) {
  localStorage.removeItem(CURRENT_ACCOUNT);

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

export function upload(agent, path, file) {
  return attempt(async () => {
    const response = await agent.handle(path, {
      method: "POST",
      headers: { "content-type": file.type || "application/octet-stream" },
      body: file,
    });

    return [response.status, await response.text()];
  });
}

export function save(agent, path, filename) {
  return attempt(async () => {
    const response = await agent.handle(path);

    if (!response.ok) {
      return [response.status, await response.text()];
    }

    const url = URL.createObjectURL(await response.blob());
    const link = document.createElement("a");

    link.href = url;
    link.download = filename;
    document.body.append(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);

    return [response.status, ""];
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

export function origin(agent) {
  return new URL(agent.session.info.aud).origin;
}

async function attempt(run) {
  try {
    return Result$Ok(await run());
  } catch (error) {
    return Result$Error(error instanceof Error ? error.name : String(error));
  }
}
