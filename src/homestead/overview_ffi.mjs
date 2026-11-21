import { Result$Error, Result$Ok } from "../gleam.mjs";

export async function copy(text) {
  try {
    await navigator.clipboard.writeText(text);

    return Result$Ok(undefined);
  } catch {
    return Result$Error(undefined);
  }
}
