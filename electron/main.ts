import { app, BrowserWindow, desktopCapturer, ipcMain, session } from "electron";
import type { DesktopCapturerSource } from "electron";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Chromium normally obfuscates its own host ICE candidates behind a random
// <uuid>.local mDNS name (a standing privacy default, not overridable from
// page JS). Screen's WebKit-based receiver never resolves that name, so
// Mirror mode's ICE negotiation stalls before a real candidate pair ever
// forms — see reports/mirror-mode-mdns-findings.md. This is Electron's
// equivalent of chrome://flags/#enable-webrtc-hide-local-ips-with-mdns ->
// Disabled: fine here because the only WebRTC peer this app ever talks to
// is our own trusted Screen receiver, not arbitrary websites. Must be set
// before app.whenReady() / renderer process creation.
app.commandLine.appendSwitch("disable-features", "WebRtcHideLocalIpsWithMdns");

const VITE_DEV_SERVER_URL = process.env["VITE_DEV_SERVER_URL"];

// Serialized subset of DesktopCapturerSource sent to the renderer over IPC
// (the raw source's thumbnail is a NativeImage, not JSON-transferable).
type SerializedSource = {
  id: string;
  name: string;
  type: "screen" | "window";
  thumbnail: string;
};

function createWindow(): BrowserWindow {
  const win = new BrowserWindow({
    width: 1080,
    height: 720,
    webPreferences: {
      preload: path.join(__dirname, "preload.mjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  if (VITE_DEV_SERVER_URL) {
    win.loadURL(VITE_DEV_SERVER_URL);
  } else {
    win.loadFile(path.join(__dirname, "../dist/index.html"));
  }

  return win;
}

// Stands in for Chrome's native getDisplayMedia picker (screen/window/tab
// chooser) — Electron doesn't show one itself, so this asks the renderer to
// display ScreenSourcePicker.tsx and waits for the user's choice over IPC.
// navigator.mediaDevices.getDisplayMedia() in MirrorSession.createOffer is
// unchanged; this handler intercepts it transparently.
async function requestScreenSource(win: BrowserWindow): Promise<DesktopCapturerSource | null> {
  const sources = await desktopCapturer.getSources({
    types: ["screen", "window"],
    thumbnailSize: { width: 300, height: 200 },
  });
  const serialized: SerializedSource[] = sources.map((source) => ({
    id: source.id,
    name: source.name,
    type: source.id.startsWith("screen:") ? "screen" : "window",
    thumbnail: source.thumbnail.toDataURL(),
  }));

  const pickedId = await new Promise<string | null>((resolve) => {
    ipcMain.once("screen-picker:selected", (_event, id: string | null) => resolve(id));
    win.webContents.send("screen-picker:show", serialized);
  });

  return sources.find((source) => source.id === pickedId) ?? null;
}

app.whenReady().then(() => {
  const win = createWindow();

  session.defaultSession.setDisplayMediaRequestHandler(async (_request, callback) => {
    const picked = await requestScreenSource(win);
    if (!picked) {
      callback({});
      return;
    }
    // "loopback" captures the picked source's system audio directly
    // (ScreenCaptureKit-backed on macOS); requires a recent-enough Electron
    // + macOS 13+. Verify during testing — if unsupported here, drop to
    // video-only rather than shipping silently-broken audio.
    callback({ video: picked, audio: "loopback" });
  });

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});
