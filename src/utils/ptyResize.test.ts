import { expect, it, vi } from "vitest";
import { createPtyResizeScheduler } from "./ptyResize";

const INITIAL_SIZE = Object.freeze({ cols: 80, rows: 24 });
const WIDER_SIZE = Object.freeze({ cols: 100, rows: 24 });
const TALLER_SIZE = Object.freeze({ cols: 100, rows: 30 });

function deferred() {
  let resolve: () => void = () => {};
  let reject: (error: unknown) => void = () => {};
  const promise = new Promise<void>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

it("starts the next PTY resize only after the in-flight invoke settles", async () => {
  const first = deferred();
  const second = deferred();
  const resize = vi.fn().mockReturnValueOnce(first.promise).mockReturnValueOnce(second.promise);
  const scheduler = createPtyResizeScheduler(resize);

  const firstDone = scheduler.request(INITIAL_SIZE);
  const secondDone = scheduler.request(WIDER_SIZE);
  expect(resize.mock.calls).toEqual([[INITIAL_SIZE]]);

  first.resolve();
  await first.promise;
  expect(resize.mock.calls).toEqual([[INITIAL_SIZE], [WIDER_SIZE]]);

  second.resolve();
  await Promise.all([firstDone, secondDone]);
});

it("coalesces pending PTY resizes to only the latest requested size", async () => {
  const first = deferred();
  const resize = vi.fn().mockReturnValueOnce(first.promise).mockResolvedValue(undefined);
  const scheduler = createPtyResizeScheduler(resize);

  const done = scheduler.request(INITIAL_SIZE);
  void scheduler.request(WIDER_SIZE);
  void scheduler.request(TALLER_SIZE);
  expect(resize).toHaveBeenCalledTimes(1);

  first.resolve();
  await done;
  expect(resize.mock.calls).toEqual([[INITIAL_SIZE], [TALLER_SIZE]]);
});

it("deduplicates identical PTY sizes both in flight and after completion", async () => {
  const first = deferred();
  const resize = vi.fn().mockReturnValueOnce(first.promise).mockResolvedValue(undefined);
  const scheduler = createPtyResizeScheduler(resize);

  const done = scheduler.request(INITIAL_SIZE);
  void scheduler.request({ ...INITIAL_SIZE });
  first.resolve();
  await done;
  await scheduler.request({ ...INITIAL_SIZE });
  expect(resize.mock.calls).toEqual([[INITIAL_SIZE]]);

  await scheduler.request(WIDER_SIZE);
  await scheduler.request(TALLER_SIZE);
  expect(resize.mock.calls).toEqual([[INITIAL_SIZE], [WIDER_SIZE], [TALLER_SIZE]]);
});

it("drops a stale pending size when the latest request returns to the in-flight size", async () => {
  const first = deferred();
  const resize = vi.fn().mockReturnValueOnce(first.promise).mockResolvedValue(undefined);
  const scheduler = createPtyResizeScheduler(resize);

  const done = scheduler.request(INITIAL_SIZE);
  void scheduler.request(WIDER_SIZE);
  void scheduler.request({ ...INITIAL_SIZE });
  first.resolve();
  await done;
  expect(resize.mock.calls).toEqual([[INITIAL_SIZE]]);
});

it("continues with the latest pending PTY size after an invoke rejects", async () => {
  const first = deferred();
  const resize = vi.fn().mockReturnValueOnce(first.promise).mockResolvedValue(undefined);
  const scheduler = createPtyResizeScheduler(resize);

  const done = scheduler.request(INITIAL_SIZE);
  void scheduler.request(WIDER_SIZE);
  void scheduler.request(TALLER_SIZE);
  first.reject(new Error("resize failed"));
  await expect(done).resolves.toBeUndefined();
  expect(resize.mock.calls).toEqual([[INITIAL_SIZE], [TALLER_SIZE]]);

  await scheduler.request(INITIAL_SIZE);
  expect(resize).toHaveBeenLastCalledWith(INITIAL_SIZE);
});

it("also recovers from a synchronous PTY resize failure", async () => {
  const resize = vi.fn().mockImplementationOnce(() => {
    throw new Error("invoke failed");
  }).mockResolvedValue(undefined);
  const scheduler = createPtyResizeScheduler(resize);

  await expect(scheduler.request(INITIAL_SIZE)).resolves.toBeUndefined();
  await scheduler.request(WIDER_SIZE);
  expect(resize.mock.calls).toEqual([[INITIAL_SIZE], [WIDER_SIZE]]);
});

it("discards pending and future PTY resizes when disposed", async () => {
  const first = deferred();
  const resize = vi.fn().mockReturnValueOnce(first.promise).mockResolvedValue(undefined);
  const scheduler = createPtyResizeScheduler(resize);

  const done = scheduler.request(INITIAL_SIZE);
  void scheduler.request(WIDER_SIZE);
  scheduler.dispose();
  first.resolve();
  await done;
  await scheduler.request(TALLER_SIZE);
  expect(resize.mock.calls).toEqual([[INITIAL_SIZE]]);
});
