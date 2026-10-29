export interface PtySize {
  readonly cols: number;
  readonly rows: number;
}

function sameSize(last: PtySize | null, size: PtySize): boolean {
  return last?.cols === size.cols && last.rows === size.rows;
}

/** Serialize async PTY resizes, retaining only the latest pending dimensions. */
export function createPtyResizeScheduler(resize: (size: PtySize) => Promise<unknown>) {
  let latest: PtySize | null = null;
  let lastSent: PtySize | null = null;
  let running = false;
  let disposed = false;
  let pending: Promise<void> = Promise.resolve();

  const flush = async () => {
    while (latest && !disposed) {
      const size = latest;
      latest = null;
      if (sameSize(lastSent, size)) continue;
      lastSent = size;
      try {
        await resize(size);
      } catch {
        // A failed invoke must not block the latest pending size.
      }
    }
    running = false;
  };

  return {
    request(size: PtySize): Promise<void> {
      if (disposed) return Promise.resolve();
      latest = { ...size };
      if (!running) {
        running = true;
        pending = flush();
      }
      return pending;
    },
    dispose() {
      disposed = true;
      latest = null;
    },
  };
}
