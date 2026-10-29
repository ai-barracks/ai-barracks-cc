import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { XTermInstance } from "./XTermInstance";
import type { TerminalSession } from "../../types";

vi.mock("../../hooks/useTerminal", () => ({ useTerminal: vi.fn() }));
vi.mock("../../stores/terminalStore", () => ({ useTerminalStore: () => vi.fn() }));
vi.mock("./ArchiveTermView", () => ({ ArchiveTermView: () => null }));

const SESSION: TerminalSession = {
  id: "terminal-layout-test",
  barrackPath: "/test",
  title: "Terminal",
};

describe("XTermInstance layout", () => {
  it.each([true, false])("keeps padding outside xterm's parent (visible: %s)", (visible) => {
    const markup = renderToStaticMarkup(<XTermInstance session={SESSION} visible={visible} />);
    const display = visible ? "block" : "none";

    expect(markup).toBe(
      `<div class="w-full h-full min-h-0 min-w-0" style="display:${display};padding:4px 8px">` +
      '<div class="w-full h-full min-h-0 min-w-0"></div></div>',
    );
  });
});
