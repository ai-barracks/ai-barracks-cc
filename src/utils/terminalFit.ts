// A 180 ms quiet period coalesces brief window-drag pauses to reduce TUI redraws
// without a long post-drag delay.
export const TERMINAL_RESIZE_DEBOUNCE_MS = 180;

export function createTerminalFitScheduler(fit: () => void, canFit: () => boolean) {
  let timeout: ReturnType<typeof setTimeout> | null = null;
  let disposed = false;

  const cancel = () => {
    if (timeout !== null) clearTimeout(timeout);
    timeout = null;
  };

  return {
    request() {
      if (disposed) return;
      cancel();
      timeout = setTimeout(() => {
        timeout = null;
        if (!disposed && canFit()) fit();
      }, TERMINAL_RESIZE_DEBOUNCE_MS);
    },
    dispose() {
      disposed = true;
      cancel();
    },
  };
}
