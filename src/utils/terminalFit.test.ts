import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { createTerminalFitScheduler, TERMINAL_RESIZE_DEBOUNCE_MS } from "./terminalFit";

const TIMER_TICK_MS = 1;
const RESIZE_EVENT_INTERVAL_MS = TERMINAL_RESIZE_DEBOUNCE_MS / 2;
const RESIZE_EVENT_COUNT = 5;

beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

it("fits only once after a continuous sequence of container resizes stops", () => {
  const fit = vi.fn();
  const scheduler = createTerminalFitScheduler(fit, () => true);

  scheduler.request();
  for (let event = 0; event < RESIZE_EVENT_COUNT; event += 1) {
    vi.advanceTimersByTime(RESIZE_EVENT_INTERVAL_MS);
    scheduler.request();
    expect(fit).not.toHaveBeenCalled();
  }
  vi.advanceTimersByTime(TERMINAL_RESIZE_DEBOUNCE_MS - TIMER_TICK_MS);
  expect(fit).not.toHaveBeenCalled();
  vi.advanceTimersByTime(TIMER_TICK_MS);
  expect(fit).toHaveBeenCalledTimes(1);
  expect(vi.getTimerCount()).toBe(0);
});

it("defers a panel drag fit until the drag-end request, without another resize event", () => {
  let isResizing = true;
  const fit = vi.fn();
  const scheduler = createTerminalFitScheduler(fit, () => !isResizing);

  scheduler.request();
  vi.advanceTimersByTime(TERMINAL_RESIZE_DEBOUNCE_MS);
  expect(fit).not.toHaveBeenCalled();

  isResizing = false;
  scheduler.request();
  vi.advanceTimersByTime(TERMINAL_RESIZE_DEBOUNCE_MS);
  expect(fit).toHaveBeenCalledTimes(1);
});

it("checks current visibility at fit time and can fit after becoming visible again", () => {
  const fit = vi.fn();
  const canFit = vi.fn().mockReturnValue(true);
  const scheduler = createTerminalFitScheduler(fit, canFit);

  scheduler.request();
  canFit.mockReturnValue(false);
  vi.advanceTimersByTime(TERMINAL_RESIZE_DEBOUNCE_MS);
  expect(fit).not.toHaveBeenCalled();

  canFit.mockReturnValue(true);
  scheduler.request();
  vi.advanceTimersByTime(TERMINAL_RESIZE_DEBOUNCE_MS);
  expect(fit).toHaveBeenCalledTimes(1);
});

it("cancels queued fits and ignores new requests after disposal", () => {
  const fit = vi.fn();
  const scheduler = createTerminalFitScheduler(fit, () => true);

  scheduler.request();
  scheduler.dispose();
  scheduler.request();
  vi.advanceTimersByTime(TERMINAL_RESIZE_DEBOUNCE_MS);
  expect(fit).not.toHaveBeenCalled();
  expect(vi.getTimerCount()).toBe(0);
});
