/**
 * Pure decision logic for the helper-textarea IME bypass in `useTerminal`.
 *
 * The DOM listeners in useTerminal translate textarea events (and xterm's own
 * `onData`) into `ImeEvent`s and forward whatever `stepIme` returns in `send` to
 * the PTY. Keeping the rules here lets recorded WKWebView event sequences run as
 * plain unit tests.
 *
 * Text ownership per keystroke:
 * - keydown-handled keys (letters, digits, Enter, arrows, …) → xterm sends them and
 *   cancels the event, so no keypress/input follows;
 * - keypress-handled keys (Space, Shift+letters, Option characters) → xterm sends
 *   them from `_keyPress` *without* cancelling, so WebKit still inserts the text
 *   (a lone space becomes U+00A0) and fires `input`. When xterm really sent data
 *   during that keypress, the trailing input is the same keystroke and must be
 *   ignored — otherwise every space reaches the PTY twice (" " + NBSP);
 * - IME commits → `compositionend` (xterm's CompositionHelper is bypassed); WebKit
 *   may echo the committed text as one more `input`, which is consumed only if it
 *   is that same text;
 * - everything else that only lands in the textarea (emoji/character palette) →
 *   forwarded from `input`.
 * No rule drops input because it repeats earlier input: key repeat and fast
 * double letters are real keystrokes.
 */

/** Hangul Jamo (U+1100–U+11FF) and Hangul Compatibility Jamo (U+3131–U+318E). */
const CONTAINS_JAMO = /[ᄀ-ᇿㄱ-ㆎ]/;
const ONLY_JAMO = /^[ᄀ-ᇿㄱ-ㆎ]+$/;

/** How long after compositionend an identical `input` is treated as WebKit's echo. */
const COMPOSITION_ECHO_WINDOW_MS = 50;

export type ImeEvent =
  | { type: "keydown"; keyCode: number }
  | { type: "keypress" }
  /** xterm emitted data through `onData` (fires synchronously inside its handlers). */
  | { type: "xtermData" }
  | { type: "compositionstart" }
  | { type: "compositionend"; data: string; now: number }
  | { type: "input"; inputType: string; value: string; now: number };

export interface ImeState {
  readonly composing: boolean;
  /** A keypress fired since the last keydown. */
  readonly keypressSeen: boolean;
  /** xterm sent data while handling that keypress, so its text is already out. */
  readonly keypressSent: boolean;
  /** Text committed by the last compositionend, still eligible as an echo. */
  readonly pendingEcho: string | null;
  readonly lastCompositionEnd: number;
}

export interface ImeStep {
  readonly state: ImeState;
  readonly send: string | null;
}

export const INITIAL_IME_STATE: ImeState = {
  composing: false,
  keypressSeen: false,
  keypressSent: false,
  pendingEcho: null,
  lastCompositionEnd: Number.NEGATIVE_INFINITY,
};

const KEYSTROKE_RESET = { keypressSeen: false, keypressSent: false, pendingEcho: null } as const;

function isCompositionEcho(state: ImeState, value: string, now: number): boolean {
  return state.pendingEcho !== null
    && value === state.pendingEcho
    && now - state.lastCompositionEnd < COMPOSITION_ECHO_WINDOW_MS;
}

function inputDecision(state: ImeState, inputType: string, value: string, now: number): string | null {
  if (inputType === "insertFromPaste" || state.composing || !value) return null;
  if (state.keypressSent && inputType === "insertText") return null;
  if (isCompositionEcho(state, value, now)) return null;
  if (CONTAINS_JAMO.test(value)) return null;
  return value;
}

export function stepIme(state: ImeState, event: ImeEvent): ImeStep {
  switch (event.type) {
    case "keydown":
      return { state: { ...state, ...KEYSTROKE_RESET }, send: null };
    case "keypress":
      return { state: { ...state, keypressSeen: true }, send: null };
    case "xtermData":
      return { state: state.keypressSeen ? { ...state, keypressSent: true } : state, send: null };
    case "compositionstart":
      return { state: { ...state, ...KEYSTROKE_RESET, composing: true }, send: null };
    case "compositionend": {
      const committed = event.data && !ONLY_JAMO.test(event.data) ? event.data : null;
      return {
        state: { ...state, composing: false, pendingEcho: committed, lastCompositionEnd: event.now },
        send: committed,
      };
    }
    case "input":
      return {
        state: state.composing ? state : { ...state, ...KEYSTROKE_RESET },
        send: inputDecision(state, event.inputType, event.value, event.now),
      };
  }
}
