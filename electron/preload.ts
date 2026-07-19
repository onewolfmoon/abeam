import { contextBridge, ipcRenderer } from "electron";

export type PickerSource = {
  id: string;
  name: string;
  type: "screen" | "window";
  thumbnail: string;
};

contextBridge.exposeInMainWorld("electronAPI", {
  onScreenPickerRequest: (callback: (sources: PickerSource[]) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, sources: PickerSource[]) => callback(sources);
    ipcRenderer.on("screen-picker:show", listener);
    return () => ipcRenderer.removeListener("screen-picker:show", listener);
  },
  selectScreenSource: (id: string | null) => ipcRenderer.send("screen-picker:selected", id),
});
