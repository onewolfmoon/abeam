import { contextBridge, ipcRenderer } from "electron";

export type PickerSource = {
  id: string;
  name: string;
  type: "screen" | "window";
  thumbnail: string;
};

export type DiscoveredScreen = {
  id: string;
  name: string;
  host: string;
  port: number;
};

contextBridge.exposeInMainWorld("electronAPI", {
  onScreenPickerRequest: (callback: (sources: PickerSource[]) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, sources: PickerSource[]) => callback(sources);
    ipcRenderer.on("screen-picker:show", listener);
    return () => ipcRenderer.removeListener("screen-picker:show", listener);
  },
  selectScreenSource: (id: string | null) => ipcRenderer.send("screen-picker:selected", id),

  getDiscoveredScreens: (): Promise<DiscoveredScreen[]> => ipcRenderer.invoke("bonjour:list"),
  onDiscoveredScreensChanged: (callback: (screens: DiscoveredScreen[]) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, screens: DiscoveredScreen[]) => callback(screens);
    ipcRenderer.on("bonjour:update", listener);
    return () => ipcRenderer.removeListener("bonjour:update", listener);
  },
});
