import { useTerminalStore } from "../../stores/terminalStore";
import type { TerminalSession } from "../../types";

interface SlotHeaderProps {
  barrackPath: string;
  slotIndex: number;
  session: TerminalSession | null;
  availableSessions: TerminalSession[];
}

export function SlotHeader({ barrackPath, slotIndex, session, availableSessions }: SlotHeaderProps) {
  const setSlotTerminal = useTerminalStore((s) => s.setSlotTerminal);

  return (
    <div className="flex items-center h-6 bg-cc-sidebar border-b border-cc-border px-2 flex-shrink-0">
      <select
        value={session?.id ?? ""}
        onChange={(e) => setSlotTerminal(barrackPath, slotIndex, e.target.value || null)}
        className="text-[11px] bg-transparent text-cc-text-dim border-none outline-none cursor-pointer flex-1 min-w-0 truncate"
      >
        <option value="">-- empty --</option>
        {availableSessions.map((s) => (
          <option key={s.id} value={s.id}>
            {s.title}
          </option>
        ))}
      </select>
      {session?.source && session.source !== "terminal" && (
        <span className="w-1.5 h-1.5 rounded-full bg-cc-accent inline-block flex-shrink-0 ml-1" />
      )}
    </div>
  );
}
