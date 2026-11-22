import { existsSync } from "node:fs";
import { dirname, join } from "node:path";

export async function aboutHtml() {
  return Bun.markdown.html(
    await Bun.file(join(projectRoot(import.meta.dir), "content/about.md")).text(),
  );
}

function projectRoot(directory) {
  if (existsSync(join(directory, "gleam.toml"))) {
    return directory;
  }

  const parent = dirname(directory);

  if (parent === directory) {
    throw new Error("No gleam.toml above " + import.meta.dir);
  }

  return projectRoot(parent);
}
