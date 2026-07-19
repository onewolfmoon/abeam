/// <reference types="vite/client" />

interface PickerSource {
  id: string;
  name: string;
  type: "screen" | "window";
  thumbnail: string;
}

interface DiscoveredScreen {
  id: string;
  name: string;
  host: string;
  port: number;
}

interface Window {
  electronAPI: {
    onScreenPickerRequest: (callback: (sources: PickerSource[]) => void) => () => void;
    selectScreenSource: (id: string | null) => void;

    getDiscoveredScreens: () => Promise<DiscoveredScreen[]>;
    onDiscoveredScreensChanged: (callback: (screens: DiscoveredScreen[]) => void) => () => void;
  };
}
