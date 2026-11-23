# Homestead

Homestead is a standalone Tranquil PDS dashboard client. You can log into any account that exists on any Tranquil PDS instance and manage your account.

Like any atproto personal data server, Tranquil has a dashboard for user account management. Unlike other PDSs, Tranquil's frontend is a regular public OAuth client. All account management endpoints are covered by OAuth permissions, and can be called using regular XRPC requests with an OAuth access token. In other words, there's nothing special about the dashboard that comes built into Tranquil, you can replace it with your own public OAuth client, and you can even run a shared account management portal that works for all live Tranquil PDS instances. That's what Homestead is.

Homestead adds many new behaviors on top of the Tranquil frontend, such as:

* Backlinks, per account and per record
* Syntax highlighting for records
* Live handle verification
* Account and profile labels

Try out the live instance at [https://homestead.at](https://homestead.at).

## How it works

Homestead is a Gleam application that compiles to JS and uses Lustre for rendering. It uses [hayleigh.dev](https://bsky.app/profile/hayleigh.dev)'s [at](https://tangled.org/hayleigh.dev/at) for atproto building blocks and [mary.my.id](https://bsky.app/profile/mary.my.id)'s [atcute](https://github.com/mary-ext/atcute) for the browser OAuth behaviors.

Homestead uses [typeahead.cove.town](https://typeahead.cove.town) to search and resolve handles and identities, and then looks up the PDS that your account lives on. If it is a Tranquil instance, it logs you in, otherwise it shows an error.

Tranquil offers an extension of account management atproto scopes, which is part of how Homestead can work. Most actions can be taken directly through Homestead, with some notable exceptions: passkeys are bound to the host, and so have to be created on the origin PDS, and OAuth consent screens and the login flow are still fully owned by the respective PDS instance.

## Development

Homestead is designed to work with a local Tranquil dev setup, following the official instructions. With Tranquil running locally, and the `pds.test` host set up, you can run it with:

```bash
gleam run -m lustre/dev start homestead_dev
```

And some commands for local verification.

```bash
npm ci
gleam format --check src test dev
gleam build --warnings-as-errors
gleam test
gleam run -m lustre/dev build --minify
```

## Configuration

You can run your own Homestead! Feel free to fork and make the design your own, or use it as is. All the dependencies can be configured with environment variables:

| Variable                  | Default                                |
| ------------------------- | -------------------------------------- |
| `HOMESTEAD_PLC`           | `https://plc.directory`                |
| `HOMESTEAD_TYPEAHEAD`     | `https://typeahead.cove.town`          |
| `HOMESTEAD_SLINGSHOT`     | `https://slingshot.cove.town`          |
| `HOMESTEAD_CONSTELLATION` | `https://constellation.microcosm.blue` |
| `HOMESTEAD_APPVIEW`       | `https://public.api.bsky.app`          |
| `HOMESTEAD_LABEL_RELAY`   | `https://labelers.firehose.stream`     |
| `HOMESTEAD_DNS`           | `https://dns10.quad9.net/dns-query`    |


## Contributing

PRs are very welcome, especially efforts to make the code more idiomatic Gleam. AI-assisted contributions are accepted, but all human facing text must be written by a human. This includes PR descriptions, issues, commit messages, and comments.
