import { app, BrowserWindow, desktopCapturer, ipcMain, session } from "electron";
import type { DesktopCapturerSource } from "electron";
import { Bonjour } from "bonjour-service";
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

// Screen instances advertise themselves over Bonjour as _blittie-screen._tcp
// (confirmed empirically via `dns-sd -B _blittie-screen._tcp local.` against
// a running Screen instance), resolving directly to <host>.local:8787 — the
// same plain ws:// port receiverEndpoint.ts now defaults to, so no scheme
// ambiguity. This restores the "On Your Network" discovery
// ReceiverPickerSheet.swift already does natively; the old browser-only web
// version dropped it entirely because a browser can't do mDNS browsing at
// all, only Electron's main process (which has real Node/UDP access) can.
const SCREEN_SERVICE_TYPE = "blittie-screen";

type DiscoveredScreen = {
  id: string;
  name: string;
  host: string;
  port: number;
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

  session.defaultSession.setDisplayMediaRequestHandler(
    async (_request, callback) => {
      const picked = await requestScreenSource(win);
      if (!picked) {
        callback({});
        return;
      }
      // "loopback" is Windows-only (confirmed against this Electron
      // version's own electron.d.ts) — it's a no-op elsewhere, silently
      // producing a video-only stream. Harmless to always request: this
      // whole handler is skipped in favor of the real system picker
      // wherever useSystemPicker (below) applies, and "loopback" is exactly
      // right on the platforms where the handler still runs.
      callback({ video: picked, audio: "loopback" });
    },
    // Prefer the OS's own screen-share picker over ours whenever the
    // platform supports it — currently macOS 15+ only (per
    // DisplayMediaRequestHandlerOpts), where it's the only way to get
    // system audio, since ScreenCaptureKit audio capture isn't reachable
    // through the desktopCapturer-based handler above at all. When
    // unavailable (older macOS, Windows, Linux, or any future platform
    // where Electron hasn't implemented it yet), Electron silently falls
    // back to invoking the handler as before — so this is safe to leave on
    // unconditionally rather than gating on today's platform/OS-version
    // support matrix.
    { useSystemPicker: true },
  );

  // Runs continuously for the app's lifetime rather than only while the
  // "Choose a Screen" dialog is open — cheap (idle mDNS listener), and
  // means the list is already warm the moment the dialog opens.
  const bonjour = new Bonjour();
  const discovered = new Map<string, DiscoveredScreen>();
  const browser = bonjour.find({ type: SCREEN_SERVICE_TYPE, protocol: "tcp" });
  browser.on("up", (service) => {
    const entry: DiscoveredScreen = {
      id: service.fqdn,
      name: service.name,
      // Bonjour hostnames come back with a trailing dot (e.g. "Autosvcacct.local.").
      host: service.host.replace(/\.$/, ""),
      port: service.port,
    };
    discovered.set(entry.id, entry);
    win.webContents.send("bonjour:update", Array.from(discovered.values()));
  });
  browser.on("down", (service) => {
    discovered.delete(service.fqdn);
    win.webContents.send("bonjour:update", Array.from(discovered.values()));
  });
  // Pull-based snapshot for the renderer's initial mount: 'up' events for
  // Screens discovered before the dialog's IPC listener subscribed would
  // otherwise just be dropped (Electron's ipcRenderer.send has no queuing),
  // and a Screen that's already been broadcasting for a while might not
  // fire 'up' again for a long time.
  ipcMain.handle("bonjour:list", () => Array.from(discovered.values()));
  app.on("before-quit", () => bonjour.destroy());

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});
