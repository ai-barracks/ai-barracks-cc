import { useCallback, useRef } from "react";
import { useTerminalStore } from "../../stores/terminalStore";

export function PanelResizeHandle() {
  const setPanelWidth = useTerminalStore((s) => s.setPanelWidth);
  const setIsResizing = useTerminalStore((s) => s.setIsResizing);
  const isDragging = useRef(false);

  const handleMouseDown = useCallback(
    (e: React.MouseEvent) => {
      e.preventDefault();
      isDragging.current = true;
      setIsResizing(true);

      const startX = e.clientX;
      const startWidth = useTerminalStore.getState().panelWidth;

      const handleMouseMove = (e: MouseEvent) => {
        if (!isDragging.current) return;
        const delta = startX - e.clientX;
        const newWidth = Math.max(280, Math.min(window.innerWidth - 400, startWidth + delta));
        setPanelWidth(newWidth);
      };

      const handleMouseUp = () => {
        isDragging.current = false;
        setIsResizing(false);
        document.removeEventListener("mousemove", handleMouseMove);
        document.removeEventListener("mouseup", handleMouseUp);
        document.body.style.cursor = "";
        document.body.style.userSelect = "";
      };

      document.body.style.cursor = "col-resize";
      document.body.style.userSelect = "none";
      document.addEventListener("mousemove", handleMouseMove);
      document.addEventListener("mouseup", handleMouseUp);
    },
    [setPanelWidth, setIsResizing]
  );

  return (
    <div
      onMouseDown={handleMouseDown}
      className="w-1 cursor-col-resize bg-cc-border hover:bg-cc-accent transition-colors flex-shrink-0"
    />
  );
}
