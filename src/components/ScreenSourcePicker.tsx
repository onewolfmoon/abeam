// Stands in for Chrome's native getDisplayMedia picker. Electron's main
// process (electron/main.ts) intercepts navigator.mediaDevices.getDisplayMedia()
// via session.setDisplayMediaRequestHandler and asks this component to show
// the choice instead; the pick is sent back over window.electronAPI.
export function ScreenSourcePicker({
  sources,
  onPick,
  onCancel,
}: {
  sources: PickerSource[];
  onPick: (id: string) => void;
  onCancel: () => void;
}) {
  const screens = sources.filter((source) => source.type === "screen");
  const windows = sources.filter((source) => source.type === "window");

  return (
    <div className="dialog-overlay" role="presentation" onClick={onCancel}>
      <div
        className="dialog picker-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="picker-dialog-title"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 id="picker-dialog-title">Choose what to mirror</h2>
        {screens.length > 0 && (
          <>
            <p className="picker-group-label">Screens</p>
            <SourceGrid sources={screens} onPick={onPick} />
          </>
        )}
        {windows.length > 0 && (
          <>
            <p className="picker-group-label">Windows</p>
            <SourceGrid sources={windows} onPick={onPick} />
          </>
        )}
        {sources.length === 0 && <p className="dialog-hint">No screens or windows available.</p>}
        <div className="dialog-actions">
          <button onClick={onCancel}>Cancel</button>
        </div>
      </div>
    </div>
  );
}

function SourceGrid({ sources, onPick }: { sources: PickerSource[]; onPick: (id: string) => void }) {
  return (
    <div className="picker-grid">
      {sources.map((source) => (
        <button key={source.id} className="picker-source" onClick={() => onPick(source.id)} title={source.name}>
          <img src={source.thumbnail} alt="" />
          <span>{source.name}</span>
        </button>
      ))}
    </div>
  );
}
