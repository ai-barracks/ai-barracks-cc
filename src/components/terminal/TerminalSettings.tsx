import { useTerminalStore } from "../../stores/terminalStore";

interface TerminalSettingsProps {
  onClose: () => void;
}

export function TerminalSettingsPanel({ onClose }: TerminalSettingsProps) {
  const { settings, updateSettings } = useTerminalStore();

  return (
    <div className="absolute top-full right-0 mt-1 w-72 bg-cc-panel border border-cc-border rounded-lg shadow-lg p-4 z-50">
      <div className="flex items-center justify-between mb-3">
        <span className="text-xs font-medium text-cc-text-dim uppercase tracking-wider">
          Terminal Settings
        </span>
        <button
          onClick={onClose}
          className="text-cc-text-muted hover:text-cc-text text-sm transition-colors"
        >
          x
        </button>
      </div>

      {/* Font Family */}
      <div className="mb-3">
        <label className="text-[10px] text-cc-text-muted block mb-1">Font Family</label>
        <input
          type="text"
          value={settings.fontFamily}
          onChange={(e) => updateSettings({ fontFamily: e.target.value })}
          className="w-full text-xs px-2 py-1.5 bg-cc-bg border border-cc-border rounded text-cc-text focus:outline-none focus:border-cc-accent"
        />
      </div>

      {/* Font Size */}
      <div className="mb-3">
        <label className="text-[10px] text-cc-text-muted block mb-1">
          Font Size: {settings.fontSize}px
        </label>
        <div className="flex items-center gap-2">
          <input
            type="range"
            min={10}
            max={24}
            step={1}
            value={settings.fontSize}
            onChange={(e) => updateSettings({ fontSize: Number(e.target.value) })}
            className="flex-1 accent-cc-accent"
          />
          <input
            type="number"
            min={10}
            max={24}
            value={settings.fontSize}
            onChange={(e) => {
              const v = Number(e.target.value);
              if (v >= 10 && v <= 24) updateSettings({ fontSize: v });
            }}
            className="w-12 text-xs px-1 py-1 bg-cc-bg border border-cc-border rounded text-cc-text text-center focus:outline-none focus:border-cc-accent"
          />
        </div>
      </div>

      {/* Line Height */}
      <div className="mb-3">
        <label className="text-[10px] text-cc-text-muted block mb-1">
          Line Height: {settings.lineHeight.toFixed(1)}
        </label>
        <input
          type="range"
          min={1.0}
          max={2.0}
          step={0.1}
          value={settings.lineHeight}
          onChange={(e) => updateSettings({ lineHeight: Number(e.target.value) })}
          className="w-full accent-cc-accent"
        />
      </div>

      {/* Cursor Style */}
      <div>
        <label className="text-[10px] text-cc-text-muted block mb-1">Cursor Style</label>
        <div className="flex gap-1">
          {(["block", "underline", "bar"] as const).map((style) => (
            <button
              key={style}
              onClick={() => updateSettings({ cursorStyle: style })}
              className={`flex-1 text-xs py-1 rounded border transition-colors ${
                settings.cursorStyle === style
                  ? "border-cc-accent bg-cc-accent/10 text-cc-accent"
                  : "border-cc-border text-cc-text-dim hover:border-cc-accent/40"
              }`}
            >
              {style}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}
