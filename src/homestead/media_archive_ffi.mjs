import { makeZip } from "client-zip";
import { Result$Error, Result$Ok } from "../gleam.mjs";
import { saveBlob } from "./browser_ffi.mjs";

const EXTENSIONS = {
  "image/jpeg": ".jpg",
  "image/png": ".png",
  "image/gif": ".gif",
  "image/webp": ".webp",
  "image/avif": ".avif",
  "video/mp4": ".mp4",
  "video/webm": ".webm",
  "video/quicktime": ".mov",
  "audio/mpeg": ".mp3",
  "audio/ogg": ".ogg",
  "text/vtt": ".vtt",
};

export function savesToDisk() {
  return "showSaveFilePicker" in window;
}

export function start(origin, did, cids, filename, onProgress, onDone) {
  const stopper = new AbortController();

  save(origin, did, cids, filename, onProgress, stopper.signal).then(
    () => onDone(Result$Ok(undefined)),
    (error) =>
      onDone(
        Result$Error(
          stopper.signal.aborted || !(error instanceof Error)
            ? "AbortError"
            : error.name,
        ),
      ),
  );

  return stopper;
}

export function stop(stopper) {
  stopper.abort();
}

async function save(origin, did, cids, filename, onProgress, signal) {
  const archive = makeZip(files(origin, did, cids, onProgress, signal));

  if (savesToDisk()) {
    const file = await window.showSaveFilePicker({
      suggestedName: filename,
      types: [
        {
          description: "Zip archive",
          accept: { "application/zip": [".zip"] },
        },
      ],
    });

    await archive.pipeTo(await file.createWritable(), { signal });
  } else {
    const held = new Response(archive, {
      headers: { "content-type": "application/zip" },
    });

    saveBlob(await held.blob(), filename);
  }
}

async function* files(origin, did, cids, onProgress, signal) {
  for (const [index, cid] of cids.entries()) {
    const address = new URL("/xrpc/com.atproto.sync.getBlob", origin);
    address.searchParams.set("did", did);
    address.searchParams.set("cid", cid);

    const response = await fetch(address, { signal });

    if (!response.ok) {
      const refusal = new Error(cid);
      refusal.name = "MediaRefused";
      throw refusal;
    }

    yield {
      name: cid + (EXTENSIONS[response.headers.get("content-type")] ?? ""),
      lastModified: new Date(),
      input: response,
    };

    onProgress(index + 1);
  }
}
