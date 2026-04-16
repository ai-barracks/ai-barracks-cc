import { useCallback, useRef } from "react";
import { useTerminalStore } from "../stores/terminalStore";

interface UseEmbeddedTerminalResizeOptions {
  currentWidth: number;
  onWidthChange: (w: number) => void;
}

export function useEmbeddedTerminalResize({
  currentWidth,
  onWidthChange,
}: UseEmbeddedTerminalResizeOptions) {
  const setIsResizing = useTerminalStore((s) => s.setIsResizing);
  const isDragging = useRef(false);

  const handleMouseDown = useCallback(
    (e: React.MouseEvent) => {
      e.preventDefault();
      isDragging.current = true;
      setIsResizing(true);

      const startX = e.clientX;
      const startWidth = currentWidth;

      const handleMouseMove = (e: MouseEvent) => {
        if (!isDragging.current) return;
        const delta = startX - e.clientX;
        const newWidth = Math.max(280, Math.min(Math.floor(window.innerWidth / 2), startWidth + delta));
        onWidthChange(newWidth);
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
    [currentWidth, onWidthChange, setIsResizing]
  );

  return { handleMouseDown };
}
