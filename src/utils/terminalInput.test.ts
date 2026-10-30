import { describe, expect, it } from "vitest";
import { INITIAL_IME_STATE, stepIme, type ImeEvent, type ImeState, type ImeStep } from "./terminalInput";

/** Feed a recorded DOM event sequence through the reducer; collect what it would send to the PTY. */
function run(events: ImeEvent[], start: ImeState = INITIAL_IME_STATE): { sent: string[]; state: ImeState } {
  return events.reduce<{ sent: string[]; state: ImeState }>(
    (acc, event) => {
      const step = stepIme(acc.state, event);
      return { state: step.state, sent: step.send === null ? acc.sent : [...acc.sent, step.send] };
    },
    { sent: [], state: start },
  );
}

describe("stepIme — keypress-owned keystrokes (xterm already sends them)", () => {
  // Recorded in WKWebView (aib-cc 1.6.0 repro, 2026-10-29): one Space press produced
  // keydown(32) → keypress(32) → beforeinput/input(insertText, textarea.value="\u00a0").
  // xterm sends " " from _keyPress, so the bypass must NOT also send the NBSP.
  it("does not re-send the NBSP WebKit inserts after a space keypress", () => {
    const { sent } = run([
      { type: "keydown", keyCode: 32 },
      { type: "keypress", char: "?", now: 0 },
      { type: "xtermData" },
      { type: "input", inputType: "insertText", value: "\u00a0", now: 1000 },
    ]);
    expect(sent).toEqual([]);
  });

  it("does not re-send uppercase letters that xterm handles in keypress", () => {
    const { sent } = run([
      { type: "keydown", keyCode: 65 },
      { type: "keypress", char: "?", now: 0 },
      { type: "xtermData" },
      { type: "input", inputType: "insertText", value: "A", now: 1000 },
    ]);
    expect(sent).toEqual([]);
  });

  it("handles every space of a typed sentence exactly once (none from the bypass)", () => {
    const space = (now: number): ImeEvent[] => [
      { type: "keydown", keyCode: 32 },
      { type: "keypress", char: "?", now: 0 },
      { type: "xtermData" },
      { type: "input", inputType: "insertText", value: "\u00a0", now },
    ];
    const { sent } = run([...space(100), ...space(300), ...space(320)]);
    expect(sent).toEqual([]);
  });
});

describe("stepIme — text that only arrives through the textarea", () => {
  it("forwards non-keypress insertText such as the emoji/character palette", () => {
    const { sent } = run([{ type: "input", inputType: "insertText", value: "😀", now: 1000 }]);
    expect(sent).toEqual(["😀"]);
  });

  it("forwards the same character twice in a row (no time-window dedup)", () => {
    const { sent } = run([
      { type: "input", inputType: "insertText", value: "é", now: 1000 },
      { type: "input", inputType: "insertText", value: "é", now: 1010 },
    ]);
    expect(sent).toEqual(["é", "é"]);
  });

  it("forwards keypress text that xterm did not send itself", () => {
    const { sent } = run([
      { type: "keydown", keyCode: 88 },
      { type: "keypress", char: "?", now: 0 },
      { type: "input", inputType: "insertText", value: "x", now: 1000 },
    ]);
    expect(sent).toEqual(["x"]);
  });

  it("ignores xterm data that is not part of a keypress (e.g. keydown-handled keys)", () => {
    const { sent } = run([
      { type: "keydown", keyCode: 13 },
      { type: "xtermData" },
      { type: "input", inputType: "insertText", value: "😀", now: 1000 },
    ]);
    expect(sent).toEqual(["😀"]);
  });

  it("forgets the keypress flag at the next keydown", () => {
    const { sent } = run([
      { type: "keydown", keyCode: 32 },
      { type: "keypress", char: "?", now: 0 },
      { type: "xtermData" },
      { type: "input", inputType: "insertText", value: "\u00a0", now: 1000 },
      { type: "keydown", keyCode: 229 },
      { type: "input", inputType: "insertText", value: "😀", now: 1200 },
    ]);
    expect(sent).toEqual(["😀"]);
  });

  it("ignores paste input because xterm's native paste handler already sent it", () => {
    const { sent } = run([{ type: "input", inputType: "insertFromPaste", value: "echo hi", now: 1000 }]);
    expect(sent).toEqual([]);
  });

  it("ignores empty textarea input", () => {
    const { sent } = run([{ type: "input", inputType: "insertText", value: "", now: 1000 }]);
    expect(sent).toEqual([]);
  });
});

describe("stepIme — Korean IME composition (behaviour preserved from v1.2.2)", () => {
  it("sends the committed syllable on compositionend", () => {
    const { sent, state } = run([
      { type: "keydown", keyCode: 229 },
      { type: "compositionstart" },
      { type: "input", inputType: "insertCompositionText", value: "아", now: 1000 },
      { type: "keydown", keyCode: 229 },
      { type: "compositionend", data: "안", now: 1100 },
    ]);
    expect(sent).toEqual(["안"]);
    expect(state.composing).toBe(false);
  });

  it("does not forward textarea input while composing", () => {
    const { sent } = run([
      { type: "compositionstart" },
      { type: "input", inputType: "insertCompositionText", value: "ㅇ", now: 1000 },
    ]);
    expect(sent).toEqual([]);
  });

  it("drops a pure-jamo commit left over from a fragmented cycle", () => {
    const { sent } = run([
      { type: "compositionstart" },
      { type: "compositionend", data: "ㅏ", now: 1000 },
    ]);
    expect(sent).toEqual([]);
  });

  it("drops the first-keystroke preview jamo that arrives before compositionstart", () => {
    const { sent } = run([
      { type: "keydown", keyCode: 229 },
      { type: "input", inputType: "insertText", value: "ㅇ", now: 1000 },
    ]);
    expect(sent).toEqual([]);
  });

  it("forwards different text that arrives right after compositionend (not an echo)", () => {
    const { sent } = run([
      { type: "compositionstart" },
      { type: "compositionend", data: "녕", now: 1000 },
      { type: "input", inputType: "insertText", value: " ", now: 1010 },
    ]);
    expect(sent).toEqual(["녕", " "]);
  });

  it("forwards the same syllable typed again after the echo window", () => {
    const { sent } = run([
      { type: "compositionstart" },
      { type: "compositionend", data: "가", now: 1000 },
      { type: "input", inputType: "insertText", value: "가", now: 1200 },
    ]);
    expect(sent).toEqual(["가", "가"]);
  });

  it("sends back-to-back compositions of the same syllable twice", () => {
    const { sent } = run([
      { type: "compositionstart" },
      { type: "compositionend", data: "가", now: 1000 },
      { type: "keydown", keyCode: 229 },
      { type: "compositionstart" },
      { type: "compositionend", data: "가", now: 1010 },
    ]);
    expect(sent).toEqual(["가", "가"]);
  });

  it("drops the echo input WebKit fires right after compositionend", () => {
    const { sent } = run([
      { type: "compositionstart" },
      { type: "compositionend", data: "녕", now: 1000 },
      { type: "input", inputType: "insertText", value: "녕", now: 1020 },
    ]);
    expect(sent).toEqual(["녕"]);
  });
});

describe("stepIme — abandoned composition", () => {
  it("an empty compositionend (sent on blur) unblocks input without sending anything", () => {
    const { sent, state } = run([
      { type: "compositionstart" },
      { type: "compositionend", data: "", now: 1000 },
      { type: "input", inputType: "insertText", value: "😀", now: 2000 },
    ]);
    expect(sent).toEqual(["😀"]);
    expect(state.composing).toBe(false);
  });
});

describe("stepIme — WebKit synthetic keypress after a composition commit", () => {
  // xtermjs/xterm.js#5894 (WKWebView, dead tilde then "/"): after compositionend("~")
  // WebKit fires keypress(charCode=126 "~") for the "/" key, then input(insertText "/").
  it("blocks the synthetic keypress from xterm and forwards the real key", () => {
    const steps: ImeStep[] = [];
    const events: ImeEvent[] = [
      { type: "keydown", keyCode: 78 },
      { type: "compositionstart" },
      { type: "input", inputType: "insertCompositionText", value: "~", now: 1000 },
      { type: "compositionend", data: "~", now: 1100 },
      { type: "keypress", char: "~", now: 1101 },
      { type: "input", inputType: "insertText", value: "/", now: 1102 },
    ];
    events.reduce((state, event) => {
      const step = stepIme(state, event);
      steps.push(step);
      return step.state;
    }, INITIAL_IME_STATE);
    expect(steps.map((step) => step.send).filter((sent) => sent !== null)).toEqual(["~", "/"]);
    expect(steps[4].blockXterm).toBe(true);
  });

  it("treats a keypress carrying the committed syllable the same way (space after 녕)", () => {
    const { sent } = run([
      { type: "compositionstart" },
      { type: "compositionend", data: "녕", now: 1000 },
      { type: "keypress", char: "녕", now: 1001 },
      { type: "input", inputType: "insertText", value: " ", now: 1002 },
    ]);
    expect(sent).toEqual(["녕", " "]);
  });

  it("lets a real keypress after a commit through to xterm (space typed after 녕)", () => {
    const steps = [
      { type: "compositionstart" },
      { type: "compositionend", data: "녕", now: 1000 },
      { type: "keypress", char: " ", now: 1001 },
      { type: "xtermData" },
      { type: "input", inputType: "insertText", value: " ", now: 1002 },
    ] satisfies ImeEvent[];
    const { sent } = run(steps);
    expect(sent).toEqual(["녕"]);
    expect(stepIme({ ...INITIAL_IME_STATE, pendingEcho: "녕", lastCompositionEnd: 1000 }, steps[2]).blockXterm).toBe(false);
  });

  it("does not block a matching keypress once a new keystroke started", () => {
    const step = stepIme(
      stepIme({ ...INITIAL_IME_STATE, pendingEcho: "~", lastCompositionEnd: 1000 }, { type: "keydown", keyCode: 192 }).state,
      { type: "keypress", char: "~", now: 1010 },
    );
    expect(step.blockXterm).toBe(false);
    expect(step.state.keypressSeen).toBe(true);
  });
});
