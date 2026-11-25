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

export function saveBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");

  link.href = url;
  link.download = filename;
  document.body.append(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

export async function copy(text) {
  try {
    await navigator.clipboard.writeText(text);

    return Result$Ok(undefined);
  } catch {
    return Result$Error(undefined);
  }
}

const PASSWORD_CHARACTERS =
  "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";

export function generatePassword() {
  for (;;) {
    const values = crypto.getRandomValues(new Uint32Array(20));
    const password = Array.from(
      values,
      (value) => PASSWORD_CHARACTERS[value % PASSWORD_CHARACTERS.length],
    ).join("");

    if (/[A-Z]/.test(password) && /[a-z]/.test(password) && /[0-9]/.test(password)) {
      return password;
    }
  }
}

