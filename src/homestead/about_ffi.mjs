import { aboutHtml } from "./about_macro.mjs" with { type: "macro" };

const rendered = aboutHtml();

export function html() {
  return rendered;
}
