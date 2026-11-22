import { Result$Error, Result$Ok } from "../gleam.mjs";

export function focus(id) {
  document.getElementById(id)?.focus();
}

export function openDialog(id) {
  document.getElementById(id)?.showModal();
}

export function after(milliseconds, callback) {
  setTimeout(callback, milliseconds);
}

export function toFile(value) {
  return value instanceof File ? Result$Ok(value) : Result$Error(undefined);
}

export function emptyFile() {
  return new File([], "");
}

export function fileName(file) {
  return file.name;
}

export async function copy(text) {
  try {
    await navigator.clipboard.writeText(text);

    return Result$Ok(undefined);
  } catch {
    return Result$Error(undefined);
  }
}
