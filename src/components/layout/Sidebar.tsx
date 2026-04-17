import { useAppStore } from "../../stores/appStore";
import { SearchBar } from "../system/SearchBar";
import type { BarrackInfo } from "../../types";

function BarrackCard({ barrack }: { barrack: BarrackInfo }) {
  const { selectedBarrack, selectBarrack, cliVersion } = useAppStore();
  const isSelected = selectedBarrack?.path === barrack.path;
  const isOutdated = cliVersion && barrack.aib_version !== cliVersion;

  return (
    <button
      onClick={() => selectBarrack(barrack)}
      className={`w-full text-left px-3 py-2.5 rounded-md transition-all ${
        isSelected
          ? "bg-cc-accent/10 text-cc-text"
          : "text-cc-text-dim hover:bg-cc-card-hover hover:text-cc-text"
      }`}
    >
      <div className="flex items-center justify-between">
        <span className={`text-[13px] font-medium ${isSelected ? "text-cc-text" : ""}`}>
          {barrack.name}
        </span>
        {barrack.active_sessions > 0 && (
          <span className="w-1.5 h-1.5 rounded-full bg-cc-success" />
        )}
      </div>
      <div className="flex items-center gap-1.5 mt-0.5 text-[11px] text-cc-text-muted">
        {barrack.active_sessions > 0 && (
          <>
            <span className="text-cc-success">{barrack.active_sessions} active</span>
            <span>·</span>
          </>
        )}
        <span>{barrack.wiki_topic_count} topics</span>
        {isOutdated && (
          <>
            <span>·</span>
            <span className="text-cc-warning">v{barrack.aib_version}</span>
          </>
        )}
      </div>
    </button>
  );
}

export function Sidebar() {
  const { barracks, cliVersion, appVersion, theme, toggleTheme, selectedBarrack, showSystemView } = useAppStore();

  return (
    <div className="w-60 min-w-[240px] bg-cc-sidebar border-r border-cc-border flex flex-col h-full">
      <button
        onClick={showSystemView}
        className={`px-4 py-3 border-b border-cc-border text-left transition-colors ${
          !selectedBarrack ? "bg-cc-accent/10" : "hover:bg-cc-card-hover"
        }`}
      >
        <h1 className="text-[13px] font-semibold text-cc-text">
          CommandCenter{appVersion && <span className="font-normal text-cc-text-muted ml-1">v{appVersion}</span>}
        </h1>
        <p className="text-[11px] text-cc-text-muted">
          AI Barracks {cliVersion && `v${cliVersion}`}
        </p>
      </button>

      <SearchBar />

      <div className="flex-1 overflow-y-auto px-2 py-2 space-y-0.5">
        {barracks.map((b) => (
          <BarrackCard key={b.path} barrack={b} />
        ))}
      </div>

      <div className="px-3 py-2 border-t border-cc-border flex items-center justify-between">
        <span className="text-[11px] text-cc-text-muted">
          {barracks.length} barracks
        </span>
        <button
          onClick={toggleTheme}
          className="text-[11px] px-2 py-0.5 rounded bg-cc-panel text-cc-text-dim hover:text-cc-text transition-colors"
        >
          {theme === "dark" ? "Light" : "Dark"}
        </button>
      </div>
    </div>
  );
}
