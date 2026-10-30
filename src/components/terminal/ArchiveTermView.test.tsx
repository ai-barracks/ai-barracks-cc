import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { ArchiveTermView } from "./ArchiveTermView";
import type { TerminalSession } from "../../types";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));
vi.mock("../../stores/terminalStore", () => ({ useTerminalStore: () => vi.fn() }));
vi.mock("../../stores/appStore", () => ({ useAppStore: () => "dark" }));

const SESSION: TerminalSession = {
  id: "archive-layout-test",
  barrackPath: "/test",
  title: "Archive",
  mode: "archive",
};

describe("ArchiveTermView layout", () => {
  it("keeps the inset padding outside xterm's parent element", () => {
    const markup = renderToStaticMarkup(<ArchiveTermView session={SESSION} visible />);
    expect(markup).toContain(
      '<div class="w-full h-full min-h-0 min-w-0" style="padding:4px 8px"><div class="w-full h-full min-h-0 min-w-0"></div></div>',
    );
  });
});
