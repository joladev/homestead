# About

Homestead is a standalone Tranquil PDS dashboard client. You can log into any account that exists on any Tranquil PDS instance and manage your account. [homestead.at](https://homestead.at) is a live instance, hosted in Finland.

Type in your handle at [homestead.at/sign-in](https://homestead.at/sign-in) and it automatically discovers your PDS and initiates an OAuth session against it, showing you the consent screen with the required scopes. You can add and manage multiple accounts in the same place, even if the accounts live on different PDS instances.

Homestead adds many new behaviors on top of the Tranquil frontend, such as:

* Backlinks, per account and per record
* Syntax highlighting for records
* Live handle verification
* Account and profile labels

You can browed the AGPL source code at [https://tangled.org/jola.dev/homestead](https://tangled.org/jola.dev/homestead).

## Background

Like any atproto personal data server, Tranquil has a dashboard for user account management. Unlike other PDSs, Tranquil's frontend is a regular public OAuth client. All account management endpoints are covered by OAuth permissions, and can be called using regular XRPC requests with an OAuth access token. In other words, there's nothing special about the dashboard that comes built into Tranquil, you can replace it with your own public OAuth client, and you can even run a shared account management portal that works for all live Tranquil PDS instances. That's what Homestead is.

## How it works

Homestead is a Gleam application that compiles to JS and uses Lustre for rendering. It uses [hayleigh.dev](https://bsky.app/profile/hayleigh.dev)'s [at](https://tangled.org/hayleigh.dev/at) for atproto building blocks and [mary.my.id](https://bsky.app/profile/mary.my.id)'s [atcute](https://github.com/mary-ext/atcute) for the browser OAuth behaviors.

Homestead uses [typeahead.cove.town](https://typeahead.cove.town) to search and resolve handles and identities, and then looks up the PDS that your account lives on. If it is a Tranquil instance, it logs you in, otherwise it shows an error.

Tranquil offers an extension of account management atproto scopes, which is part of how Homestead can work. Most actions can be taken directly through Homestead, with some notable exceptions: passkeys are bound to the host, and so have to be created on the origin PDS, and OAuth consent screens and the login flow are still fully owned by the respective PDS instance.

## Built by

Hi! I'm Johanna, aka [@jola.dev](https://bsky.app/profile/jola.dev). I'm one of the maintainers of the Tranquil PDS project, and I also run community infrastructure at [cove.town](https://cove.town). If you like what I do, consider buying me a coffee or helping me paying for server costs at [Ko-fi](https://ko-fi.com/S7V820WQ7W) or [becoming a Github sponsor](https://github.com/sponsors/joladev).
