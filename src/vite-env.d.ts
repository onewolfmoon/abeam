/// <reference types="vite/client" />

interface PickerSource {
  id: string;
  name: string;
  type: "screen" | "window";
  thumbnail: string;
}

interface Window {
  electronAPI: {
    onScreenPickerRequest: (callback: (sources: PickerSource[]) => void) => () => void;
    selectScreenSource: (id: string | null) => void;
  };
}
