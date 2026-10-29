/**
 * Serialize PTY writes. `terminal_write` is an async Tauri command, so two invokes
 * fired back to back run as independent tasks and may reach the PTY out of order.
 * Chaining each write behind the previous one keeps keystrokes in typing order.
 * A failed write (e.g. the PTY already closed) does not block later writes.
 */
export function createSerialWriter(write: (data: string) => Promise<unknown>): (data: string) => Promise<void> {
  let tail: Promise<void> = Promise.resolve();
  return (data: string) => {
    const next = tail.then(() => write(data)).then(
      () => undefined,
      () => undefined,
    );
    tail = next;
    return next;
  };
}
