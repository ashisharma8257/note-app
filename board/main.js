// Excalidraw for one board in the Notes app (Notes/Board.swift). The app serves this page, the board's file
// (at "scene") and the library every board shares (at "library") from its own URL scheme, and receives both
// back through the "board" message handler.
import { createElement as h } from "react";
import { createRoot } from "react-dom/client";
import { Excalidraw, exportToBlob, serializeAsJSON, serializeLibraryAsJSON } from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";

// Fonts load from the app rather than Excalidraw's CDN, so boards work offline.
window.EXCALIDRAW_ASSET_PATH = new URL(".", location.href).href;

const native = window.webkit?.messageHandlers?.board;
let scene; // the latest onChange arguments: [elements, appState, files]
let savedKey; // the board without image data, as last handed to the app
let timer;

// Cheap to compare: images, the bulk of a big board, only count by id.
const key = ([elements, appState, files]) => serializeAsJSON(elements, appState, {}, "local") + Object.keys(files).join();

// The board as .excalidraw JSON if it changed since the last save, else null. The app calls this before it closes the board.
window.pendingScene = () => {
  clearTimeout(timer);
  timer = undefined;
  if (!scene || key(scene) === savedKey) return null;
  savedKey = key(scene);
  return serializeAsJSON(...scene, "local");
};

async function save() {
  const json = window.pendingScene();
  if (!json) return;
  native?.postMessage({ scene: json }); // before the cover, which takes a while, in case the board closes meanwhile
  const [elements, appState, files] = scene;
  // The library tile; an empty board has nothing to export.
  const blob = await exportToBlob({ elements, appState, files, mimeType: "image/jpeg", maxWidthOrHeight: 280 }).catch(() => null);
  native?.postMessage({ cover: blob ? await dataURL(blob) : null });
}

const dataURL = (blob) =>
  new Promise((resolve) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.readAsDataURL(blob);
  });

// Excalidraw calls onChange for every pointer move too, so save at most twice a second rather than after a pause
// (the pointer may never pause). It only calls it once the board has loaded; that first call is the saved state.
function onChange(...args) {
  scene = args;
  if (savedKey === undefined) savedKey = key(scene);
  else timer ??= setTimeout(save, 500);
}

const root = createRoot(document.getElementById("root"));
try {
  const data = await (await fetch("scene")).json();
  const library = await fetch("library").then((r) => r.json()).catch(() => ({})); // none yet: 404
  root.render(
    h(Excalidraw, {
      initialData: { ...data, libraryItems: library.libraryItems, scrollToContent: true },
      onChange,
      onLibraryChange: (items) => native?.postMessage({ library: serializeLibraryAsJSON(items) }),
      // The board saves itself; Open, Save to… and Export Image still work through the app's downloads.
      UIOptions: { canvasActions: { saveToActiveFile: false } },
    }),
  );
} catch (error) {
  // Never show an empty editor for a board that didn't load: its first save would overwrite the file.
  root.render(h("p", { style: { font: "16px -apple-system", padding: 24 } }, `This board couldn't be opened: ${error}`));
}
