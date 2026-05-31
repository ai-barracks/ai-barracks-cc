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
  const ptyStartTimeRef = useRef<number | null>(null);

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

    // macOS WKWebView Korean/CJK IME — pre-open interception (v1.2.2 partial fix).
    //
    // Why post-open patches kept failing: xterm registers its capture-phase
    // keydown/keypress/input/composition* listeners inside `term.open()` via
    // `_bindKeys()`. Same-element/same-phase listeners fire in registration
    // order — anything added *after* `term.open()` always runs *after* xterm's,
    // and `e.stopImmediatePropagation()` from a later listener cannot un-fire
    // the earlier one. By the time a post-open hook reacts, xterm has already
    // called `_coreService.triggerDataEvent("ㅇ")` for the first jamo.
    //
    // Workaround: monkey-patch `HTMLTextAreaElement.prototype.addEventListener`
    // *before* `term.open()`. When xterm makes its first addEventListener call
    // on the helper-textarea, we synchronously install our listeners *first*.
    // xterm's later listeners run after ours so our `stopImmediatePropagation`
    // actually blocks them.
    //
    // Known limitation (see wiki/topics/AIB-CC-Terminal-Korean-IME-Troubleshooting.md):
    // macOS IME's first keystroke is "preview" mode — `compositionstart` does
    // not fire for the first jamo. We drop Hangul Jamo (U+1100-U+11FF,
    // U+3131-U+318E) at the input listener so it never reaches the PTY. This
    // also means clearing the textarea fragments composition cycles, so the
    // **first syllable of any new Korean burst arrives as 2-3 standalone jamo
    // instead of a composed syllable.** Subsequent syllables compose correctly.
    // Trade-off accepted because the alternative (revert) loses Korean entirely.
    const enableProbe =
      typeof window !== "undefined" && window.localStorage?.getItem("cc-ime-debug") === "1";

    let lastSent: { data: string; t: number } | null = null;
    const sendToPty = (data: string) => {
      if (!data || !terminalIdRef.current) return;
      const now = performance.now();
      if (lastSent && lastSent.data === data && now - lastSent.t < 50) return;
      lastSent = { data, t: now };
      invoke("terminal_write", { terminalId: terminalIdRef.current, data });
    };

    let imeInstalled = false;
    const installImeHandlers = (ta: HTMLTextAreaElement) => {
      if (imeInstalled) return;
      imeInstalled = true;

      if (enableProbe) {
        const enc = new TextEncoder();
        const log = (type: string, extra: Record<string, unknown> = {}) =>
          console.debug("[IME]", performance.now().toFixed(1), type, {
            taValue: ta.value,
            sel: [ta.selectionStart, ta.selectionEnd],
            ...extra,
          });
        (["keydown", "beforeinput", "input", "compositionstart", "compositionupdate", "compositionend"] as const)
          .forEach((t) =>
            ta.addEventListener(
              t,
              (e: Event) => {
                const k = e as KeyboardEvent & InputEvent & CompositionEvent;
                log(t, {
                  key: k.key,
                  keyCode: k.keyCode,
                  isComposing: k.isComposing,
                  data: k.data,
                  inputType: k.inputType,
                });
              },
              true,
            ),
          );
        term.onData((d) =>
          log("onData", {
            data: d,
            hex: Array.from(enc.encode(d))
              .map((b) => b.toString(16).padStart(2, "0"))
              .join(" "),
          }),
        );
      }

      let imeComposing = false;
      let lastCompositionEnd = 0;

      ta.addEventListener("compositionstart", (e: Event) => {
        imeComposing = true;
        e.stopImmediatePropagation();
      }, { capture: true });

      ta.addEventListener("compositionupdate", (e: Event) => {
        e.stopImmediatePropagation();
      }, { capture: true });

      ta.addEventListener("compositionend", (e: Event) => {
        imeComposing = false;
        lastCompositionEnd = performance.now();
        e.stopImmediatePropagation();
        const composed = (e as CompositionEvent).data;
        if (composed) {
          // Drop pure-jamo "compositions" (uncomposed pre-state from fragmented cycles).
          // Composed syllables (U+AC00-U+D7AF) pass through.
          if (!/^[ᄀ-ᇿㄱ-ㆎ]+$/.test(composed)) {
            sendToPty(composed);
          } else if (enableProbe) {
            console.debug("[IME] DROP jamo at compositionend", JSON.stringify(composed));
          }
        }
        ta.value = "";
      }, { capture: true });

      ta.addEventListener("input", (e: Event) => {
        const inputEvent = e as InputEvent;
        if (inputEvent.inputType === "insertFromPaste") {
          // xterm's native paste handler already forwards ClipboardEvent data
          // through onData. The browser may still insert the clipboard text into
          // the helper textarea afterwards, which would make this IME bypass
          // send the same payload a second time. Keep the helper textarea clean
          // without interfering with the already-handled xterm paste path.
          e.stopImmediatePropagation();
          ta.value = "";
          return;
        }
        if (imeComposing) {
          e.stopImmediatePropagation();
          return;
        }
        const data = ta.value;
        e.stopImmediatePropagation();
        ta.value = "";
        if (!data) return;
        if (/[ᄀ-ᇿㄱ-ㆎ]/.test(data)) {
          if (enableProbe) console.debug("[IME] DROP jamo at input", JSON.stringify(data));
          return;
        }
        if (performance.now() - lastCompositionEnd < 50) return;
        sendToPty(data);
      }, { capture: true });

      ta.addEventListener("keydown", (e: KeyboardEvent) => {
        if (e.keyCode === 229) {
          // Block xterm's CompositionHelper.keydown(229), which schedules a
          // 0ms `_handleAnyTextareaChanges` that would re-send pre-composition jamo.
          e.stopImmediatePropagation();
        }
      }, { capture: true });
    };

    const origAddEventListener = HTMLTextAreaElement.prototype.addEventListener;
    HTMLTextAreaElement.prototype.addEventListener = function (
      this: HTMLTextAreaElement,
      type: string,
      listener: EventListenerOrEventListenerObject | null,
      options?: boolean | AddEventListenerOptions,
    ) {
      if (!imeInstalled && this.classList?.contains("xterm-helper-textarea")) {
        installImeHandlers(this);
      }
      return origAddEventListener.call(this, type, listener as EventListener, options);
    };

    try {
      term.open(container);
    } finally {
      HTMLTextAreaElement.prototype.addEventListener = origAddEventListener;
    }

    if (!imeInstalled && term.textarea) {
      installImeHandlers(term.textarea);
    }

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
          const elapsed = ptyStartTimeRef.current ? Date.now() - ptyStartTimeRef.current : null;
          if (elapsed !== null && elapsed < 5000 && initialCommand) {
            const seconds = (elapsed / 1000).toFixed(1);
            term.write(`\r\n\x1b[33m⚠ Process exited ${seconds}s after launch.\x1b[0m\r\n`);
            term.write(`\x1b[33m  Common causes:\x1b[0m\r\n`);
            term.write(`\x1b[33m  • Claude TUI input lockup → check .claude/settings.local.json for unmatched quotes in Bash(...) entries (auto-detected by aib ≥ 1.0.1)\x1b[0m\r\n`);
            term.write(`\x1b[33m  • CLI flag regression (e.g. codex --full-auto removed in 0.128 — fixed in aib ≥ 1.0.1)\x1b[0m\r\n`);
            term.write(`\x1b[33m  • Missing CLI in PATH — verify with \`which claude/gemini/codex\`\x1b[0m\r\n`);
            term.write("\x1b[90m[Process exited]\x1b[0m\r\n");
          } else {
            term.write("\r\n\x1b[90m[Process exited]\x1b[0m\r\n");
          }
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
          ptyStartTimeRef.current = Date.now();
          onPtyCreated?.(id);
        });
      }
    });

    // Handle input — routed through sendToPty so xterm's onData (e.g. ASCII via
    // keypress, special key ANSI sequences) shares the dedup window with our
    // IME bypass listener.
    const inputDisposable = term.onData((data) => sendToPty(data));

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
