import { useEffect, useRef, useCallback } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { invoke, Channel } from "@tauri-apps/api/core";
import { useTerminalStore, appendToBuffer } from "../stores/terminalStore";
import { useAppStore } from "../stores/appStore";
import type { TerminalSettings } from "../types";

interface TerminalOutputData {
  type: "Data";
  data: string;
}

interface TerminalOutputExit {
  type: "Exit";
  code: number | null;
}

type TerminalOutput = TerminalOutputData | TerminalOutputExit;

function getTerminalTheme(appTheme: "dark" | "light") {
  if (appTheme === "dark") {
    return {
      background: "#1c1c1e",
      foreground: "#f5f5f7",
      cursor: "#0a84ff",
      cursorAccent: "#1c1c1e",
      selectionBackground: "rgba(10, 132, 255, 0.25)",
      selectionForeground: "#f5f5f7",
      black: "#3a3a3c",
      red: "#ff453a",
      green: "#30d158",
      yellow: "#ffd60a",
      blue: "#0a84ff",
      magenta: "#bf5af2",
      cyan: "#5ac8fa",
      white: "#f5f5f7",
      brightBlack: "#636366",
      brightRed: "#ff6961",
      brightGreen: "#4cd964",
      brightYellow: "#ffe620",
      brightBlue: "#409cff",
      brightMagenta: "#da8fff",
      brightCyan: "#70d7ff",
      brightWhite: "#ffffff",
    };
  }
  return {
    background: "#faf9f7",
    foreground: "#1d1d1f",
    cursor: "#0071e3",
    cursorAccent: "#faf9f7",
    selectionBackground: "rgba(0, 113, 227, 0.2)",
    selectionForeground: "#1d1d1f",
    black: "#1d1d1f",
    red: "#d70015",
    green: "#248a3d",
    yellow: "#b25000",
    blue: "#0071e3",
    magenta: "#a550a7",
    cyan: "#0f8a8a",
    white: "#e5e2dd",
    brightBlack: "#6e6e73",
    brightRed: "#ff3b30",
    brightGreen: "#34c759",
    brightYellow: "#ff9500",
    brightBlue: "#007aff",
    brightMagenta: "#bf5af2",
    brightCyan: "#5ac8fa",
    brightWhite: "#f5f5f7",
  };
}

interface UseTerminalOptions {
  sessionId: string;
  containerRef: React.RefObject<HTMLDivElement | null>;
  cwd?: string;
  initialCommand?: string;
  visible?: boolean;
  onExit?: (code?: number | null) => void;
  onPtyCreated?: (ptyId: string) => void;
  /** If set, reconnect to existing PTY instead of creating a new one */
  reconnectTerminalId?: string;
}

export function useTerminal({ sessionId, containerRef, cwd, initialCommand, visible, onExit, onPtyCreated, reconnectTerminalId }: UseTerminalOptions) {
  const terminalRef = useRef<Terminal | null>(null);
  const fitAddonRef = useRef<FitAddon | null>(null);
  const terminalIdRef = useRef<string | null>(null);
  const isDisposedRef = useRef(false);

  const settings = useTerminalStore((s) => s.settings);
  const theme = useAppStore((s) => s.theme);

  const applySettings = useCallback((term: Terminal, s: TerminalSettings, t: "dark" | "light") => {
    term.options.fontFamily = s.fontFamily;
    term.options.fontSize = s.fontSize;
    term.options.lineHeight = s.lineHeight;
    term.options.cursorStyle = s.cursorStyle;
    term.options.theme = getTerminalTheme(t);
    fitAddonRef.current?.fit();
  }, []);

  useEffect(() => {
    const container = containerRef.current;
    if (!container || terminalRef.current) return;

    const term = new Terminal({
      fontFamily: settings.fontFamily,
      fontSize: settings.fontSize,
      lineHeight: settings.lineHeight,
      cursorStyle: settings.cursorStyle,
      cursorBlink: true,
      theme: getTerminalTheme(theme),
      allowProposedApi: true,
      scrollback: 10000,
    });

    const fitAddon = new FitAddon();
    const webLinksAddon = new WebLinksAddon();

    term.loadAddon(fitAddon);
    term.loadAddon(webLinksAddon);
    term.open(container);

    // IME 조합 중 raw key event 차단 (한글/일본어/중국어 입력)
    term.attachCustomKeyEventHandler((event: KeyboardEvent) => {
      if (event.isComposing || event.keyCode === 229) {
        return false;
      }
      return true;
    });

    terminalRef.current = term;
    fitAddonRef.current = fitAddon;
    isDisposedRef.current = false;

    // Fit after DOM is ready, THEN create or reconnect PTY.
    requestAnimationFrame(() => {
      if (isDisposedRef.current) return;

      fitAddon.fit();

      const channel = new Channel<TerminalOutput>();
      channel.onmessage = (msg) => {
        if (isDisposedRef.current) return;
        if (msg.type === "Data") {
          term.write(msg.data);
          appendToBuffer(sessionId, msg.data);
        } else if (msg.type === "Exit") {
          term.write("\r\n\x1b[90m[Process exited]\x1b[0m\r\n");
          onExit?.(msg.code);
        }
      };

      if (reconnectTerminalId) {
        // Reconnect to existing PTY
        invoke<string>("terminal_reconnect", {
          terminalId: reconnectTerminalId,
          onOutput: channel,
        }).then((id) => {
          if (isDisposedRef.current) return;
          terminalIdRef.current = id;
        }).catch(() => {
          // PTY no longer exists — show message
          term.write("\r\n\x1b[90m[PTY disconnected — session expired]\x1b[0m\r\n");
        });
      } else {
        // Create new PTY
        invoke<string>("terminal_create", {
          onOutput: channel,
          cwd: cwd ?? null,
          initialCommand: initialCommand ?? null,
          cols: term.cols,
          rows: term.rows,
        }).then((id) => {
          if (isDisposedRef.current) {
            invoke("terminal_close", { terminalId: id });
            return;
          }
          terminalIdRef.current = id;
          onPtyCreated?.(id);
        });
      }
    });

    // Handle input
    const inputDisposable = term.onData((data) => {
      if (terminalIdRef.current) {
        invoke("terminal_write", { terminalId: terminalIdRef.current, data });
      }
    });

    // Handle resize — send to PTY
    const resizeDisposable = term.onResize(({ cols, rows }) => {
      if (terminalIdRef.current && !isDisposedRef.current) {
        invoke("terminal_resize", { terminalId: terminalIdRef.current, cols, rows });
      }
    });

    // ResizeObserver — skip fit() during active panel drag or when off-screen
    let fitTimeout: ReturnType<typeof setTimeout> | null = null;
    const observer = new ResizeObserver((entries) => {
      if (isDisposedRef.current) return;
      // Skip fit when container is invisible or too small (off-screen panel)
      const entry = entries[0];
      if (entry && (entry.contentRect.width < 10 || entry.contentRect.height < 10)) return;
      if (fitTimeout) clearTimeout(fitTimeout);
      const check = () => {
        if (isDisposedRef.current) return;
        if (useTerminalStore.getState().isResizing) {
          fitTimeout = setTimeout(check, 200);
        } else {
          fitAddon.fit();
        }
      };
      fitTimeout = setTimeout(check, 100);
    });
    observer.observe(container);

    return () => {
      isDisposedRef.current = true;
      observer.disconnect();
      if (fitTimeout) clearTimeout(fitTimeout);
      inputDisposable.dispose();
      resizeDisposable.dispose();
      if (terminalIdRef.current) {
        invoke("terminal_close", { terminalId: terminalIdRef.current });
      }
      term.dispose();
      terminalRef.current = null;
      fitAddonRef.current = null;
      terminalIdRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [containerRef]);

  // Re-fit and focus when tab becomes visible (display:none → block skips ResizeObserver)
  useEffect(() => {
    if (!visible || !fitAddonRef.current || isDisposedRef.current) return;
    // Use rAF to ensure DOM layout is settled before fitting
    const raf = requestAnimationFrame(() => {
      if (isDisposedRef.current) return;
      fitAddonRef.current?.fit();
      terminalRef.current?.focus();
    });
    return () => cancelAnimationFrame(raf);
  }, [visible]);

  // React to settings/theme changes
  useEffect(() => {
    if (terminalRef.current && !isDisposedRef.current) {
      applySettings(terminalRef.current, settings, theme);
    }
  }, [settings, theme, applySettings]);

  return { terminalRef, fitAddonRef };
}
