import { useState, useEffect, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useAppStore } from "../../stores/appStore";
import { useTerminalStore } from "../../stores/terminalStore";
import type { SearchResult } from "../../types";

const SOURCE_STYLES: Record<string, string> = {
  session: "text-orange-400",
  wiki: "text-green-400",
  rules: "text-purple-400",
  config: "text-blue-400",
};

export function SearchBar() {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<SearchResult[]>([]);
  const [isOpen, setIsOpen] = useState(false);
  const [searching, setSearching] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout>>(undefined);

  useEffect(() => {
    if (query.trim().length < 2) {
      setResults([]);
      setIsOpen(false);
      return;
    }

    clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(async () => {
      setSearching(true);
      try {
        const res = await invoke<SearchResult[]>("search_all", { query });
        setResults(res);
        setIsOpen(res.length > 0);
      } catch {
        setResults([]);
      } finally {
        setSearching(false);
      }
    }, 300);

    return () => clearTimeout(debounceRef.current);
  }, [query]);

  useEffect(() => {
    const handleClick = (e: MouseEvent) => {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setIsOpen(false);
      }
    };
    document.addEventListener("mousedown", handleClick);
    return () => document.removeEventListener("mousedown", handleClick);
  }, []);

  return (
    <div ref={containerRef} className="relative px-3 py-2">
      <input
        type="text"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        onFocus={() => results.length > 0 && setIsOpen(true)}
        placeholder="Search..."
        className="w-full text-[12px] px-2.5 py-1.5 bg-cc-panel border border-cc-border rounded-md text-cc-text placeholder:text-cc-text-muted focus:outline-none focus:border-cc-accent/50"
      />
      {searching && (
        <span className="absolute right-5 top-1/2 -translate-y-1/2 text-[10px] text-cc-text-muted">
          ...
        </span>
      )}

      {isOpen && (
        <div className="absolute left-3 right-3 top-full mt-1 bg-cc-panel border border-cc-border rounded-lg shadow-cc max-h-80 overflow-y-auto z-50">
          {results.map((r, i) => (
            <button
              key={i}
              onClick={() => {
                // Select the matching barrack
                const barracks = useAppStore.getState().barracks;
                const match = barracks.find((b) => b.name === r.barrack || b.path.endsWith(r.barrack));
                if (match) {
                  useAppStore.getState().selectBarrack(match);
                }
                // Open file in terminal
                useTerminalStore.getState().addSession({
                  id: crypto.randomUUID(),
                  title: `${r.source}: ${r.title}`,
                  cwd: r.file_path.substring(0, r.file_path.lastIndexOf("/")),
                  initialCommand: `cat '${r.file_path}' | grep -n -C 2 '${query.replace(/'/g, "'\\''")}'`,
                });
                setIsOpen(false);
                setQuery("");
              }}
              className="w-full text-left px-3 py-2 border-b border-cc-border last:border-0 hover:bg-cc-card-hover transition-colors"
            >
              <div className="flex items-center gap-2 mb-0.5">
                <span
                  className={`text-[10px] font-medium uppercase ${SOURCE_STYLES[r.source] ?? "text-cc-text-muted"}`}
                >
                  {r.source}
                </span>
                <span className="text-[12px] font-medium text-cc-text">
                  {r.title}
                </span>
                <span className="text-[10px] text-cc-text-muted ml-auto">
                  {r.barrack}
                </span>
              </div>
              <p className="text-[11px] text-cc-text-dim truncate">
                {r.snippet}
              </p>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
