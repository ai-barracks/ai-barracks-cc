import { useEffect, useRef, useState } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { invoke } from "@tauri-apps/api/core";
import { useTerminalStore } from "../../stores/terminalStore";
import { useAppStore } from "../../stores/appStore";
import { getTerminalTheme } from "../../hooks/useTerminal";
import type { ScrollbackPayload, TerminalSession } from "../../types";

interface ArchiveTermViewProps {
  session: TerminalSession;
  visible: boolean;
}

function formatClosedAt(iso?: string): string | null {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  return d.toLocaleString();
}

/**
 * Read-only archive view for a dead session restored from disk scrollback.
 *
 * Deliberately does NOT use `useTerminal`: there is no PTY, no input forwarding,
 * no IME interception, no reconnect. It mounts a fresh xterm with
 * `disableStdin: true`, writes the `load_scrollback` text exactly once (the Rust
 * backend already applied ANSI-straddle correction and guarantees valid UTF-8),
 * and never attaches a process. Below the terminal sits a banner + three actions.
 */
export function ArchiveTermView({ session, visible }: ArchiveTermViewProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const termRef = useRef<Terminal | null>(null);
  const fitRef = useRef<FitAddon | null>(null);
  const disposedRef = useRef(false);

  const theme = useAppStore((s) => s.theme);
  const settings = useTerminalStore((s) => s.settings);
  const addSession = useTerminalStore((s) => s.addSession);
  const removeSession = useTerminalStore((s) => s.removeSession);

  const [loadError, setLoadError] = useState<string | null>(null);
  const [empty, setEmpty] = useState(false);

  // Mount xterm + load scrollback once. Keyed on session.id so a given archive
  // tab builds exactly one terminal for its lifetime.
  useEffect(() => {
    const container = containerRef.current;
    if (!container || termRef.current) return;

    const term = new Terminal({
      fontFamily: settings.fontFamily,
      fontSize: settings.fontSize,
      lineHeight: settings.lineHeight,
      cursorStyle: settings.cursorStyle,
      cursorBlink: false,
      disableStdin: true, // read-only: swallow all keyboard input
      theme: getTerminalTheme(theme),
      allowProposedApi: true,
      scrollback: 100000,
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(container);
    termRef.current = term;
    fitRef.current = fit;
    disposedRef.current = false;

    requestAnimationFrame(() => {
      if (disposedRef.current) return;
      fit.fit();
      // Archive sessions are keyed by their original PTY id (session.ptyId),
      // falling back to session.id when they were synthesized from an archive
      // row that had no prior persisted session.
      const terminalId = session.ptyId ?? session.id;
      invoke<ScrollbackPayload>("load_scrollback", { terminalId })
        .then((payload) => {
          if (disposedRef.current) return;
          const text = payload.text;
          if (text == null || text.length === 0) {
            setEmpty(true);
            return;
          }
          // Single write of replay-ready bytes. No further ANSI correction.
          term.write(text);
        })
        .catch((e) => {
          if (disposedRef.current) return;
          setLoadError(String(e));
        });
    });

    const observer = new ResizeObserver((entries) => {
      if (disposedRef.current) return;
      const entry = entries[0];
      if (entry && (entry.contentRect.width < 10 || entry.contentRect.height < 10)) return;
      fit.fit();
    });
    observer.observe(container);

    return () => {
      disposedRef.current = true;
      observer.disconnect();
      term.dispose();
      termRef.current = null;
      fitRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session.id]);

  // Re-fit when the tab becomes visible (display:none → block skips ResizeObserver).
  useEffect(() => {
    if (!visible || !fitRef.current || disposedRef.current) return;
    const raf = requestAnimationFrame(() => {
      if (disposedRef.current) return;
      fitRef.current?.fit();
    });
    return () => cancelAnimationFrame(raf);
  }, [visible]);

  // React to settings/theme changes (matches live terminal behavior).
  useEffect(() => {
    const term = termRef.current;
    if (!term || disposedRef.current) return;
    term.options.fontFamily = settings.fontFamily;
    term.options.fontSize = settings.fontSize;
    term.options.lineHeight = settings.lineHeight;
    term.options.cursorStyle = settings.cursorStyle;
    term.options.theme = getTerminalTheme(theme);
    fitRef.current?.fit();
  }, [settings, theme]);

  // "같은 cwd에서 새 세션 시작": spawn a fresh live terminal in the archived
  // cwd via the normal new-terminal flow, then drop this archive tab.
  const handleRestart = () => {
    addSession({
      id: crypto.randomUUID(),
      title: session.title || "zsh",
      barrackPath: session.barrackPath,
      cwd: session.cwd ?? session.barrackPath,
      source: "terminal",
    });
    removeSession(session.id);
  };

  // "기록 삭제": delete the persisted scrollback, then remove the tab.
  const handleDeleteRecord = async () => {
    const terminalId = session.ptyId ?? session.id;
    try {
      await invoke("delete_scrollback", { terminalId });
    } catch {
      // Idempotent on the backend; swallow so the tab still closes.
    }
    removeSession(session.id);
  };

  // "닫기": remove the tab only; the scrollback record is preserved on disk.
  const handleClose = () => {
    removeSession(session.id);
  };

  const closedLabel = formatClosedAt(session.closedAt);

  return (
    <div className="flex flex-col h-full w-full bg-cc-bg">
      {/* Archive banner */}
      <div className="flex items-center gap-2 px-3 py-1.5 bg-cc-sidebar border-b border-cc-border flex-shrink-0 text-xs">
        <span className="px-1.5 py-0.5 rounded bg-cc-text-muted/20 text-cc-text-muted uppercase tracking-wider text-[10px] font-medium">
          Read-only
        </span>
        <span className="text-cc-text-dim">
          프로세스 종료됨{closedLabel ? ` · ${closedLabel}` : ""}
        </span>
        {session.cwd && (
          <span className="text-cc-text-muted truncate max-w-[200px]" title={session.cwd}>
            {session.cwd}
          </span>
        )}
        <div className="flex-1" />
        <button
          onClick={handleRestart}
          className="px-2 py-0.5 rounded text-cc-accent hover:bg-cc-accent/10 transition-colors"
          title="같은 cwd에서 새 라이브 세션을 시작합니다"
        >
          같은 cwd에서 새 세션 시작
        </button>
        <button
          onClick={handleDeleteRecord}
          className="px-2 py-0.5 rounded text-cc-text-muted hover:text-cc-danger hover:bg-cc-danger/10 transition-colors"
          title="디스크에 저장된 이 세션의 스크롤백 기록을 삭제합니다"
        >
          기록 삭제
        </button>
        <button
          onClick={handleClose}
          className="px-2 py-0.5 rounded text-cc-text-muted hover:text-cc-text hover:bg-cc-card-hover transition-colors"
          title="탭만 닫습니다 (기록은 보존)"
        >
          닫기
        </button>
      </div>

      {/* Read-only terminal */}
      <div className="flex-1 min-h-0 relative overflow-hidden">
        <div
          ref={containerRef}
          className="w-full h-full"
          style={{ padding: "4px 8px" }}
        />
        {(empty || loadError) && (
          <div className="absolute inset-0 flex items-center justify-center pointer-events-none">
            <span className="text-xs text-cc-text-muted">
              {loadError ? `스크롤백을 불러오지 못했습니다: ${loadError}` : "저장된 출력이 없습니다."}
            </span>
          </div>
        )}
      </div>
    </div>
  );
}
