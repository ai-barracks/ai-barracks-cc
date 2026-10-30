import { describe, expect, it } from "vitest";
import { createSerialWriter } from "./ptyWriter";

function deferred() {
  let resolve: () => void = () => {};
  let reject: (e: unknown) => void = () => {};
  const promise = new Promise<void>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

describe("createSerialWriter", () => {
  it("starts the next write only after the previous one settled (keeps keystroke order)", async () => {
    const started: string[] = [];
    const gates = [deferred(), deferred()];
    const write = createSerialWriter((data) => {
      started.push(data);
      return gates[started.length - 1]?.promise ?? Promise.resolve();
    });

    const a = write("a");
    const b = write("b");
    const c = write("c");
    await Promise.resolve();
    expect(started).toEqual(["a"]);

    gates[0].resolve();
    await a;
    await Promise.resolve();
    expect(started).toEqual(["a", "b"]);

    gates[1].resolve();
    await Promise.all([b, c]);
    expect(started).toEqual(["a", "b", "c"]);
  });

  it("keeps identical consecutive writes (no dedup)", async () => {
    const started: string[] = [];
    const write = createSerialWriter(async (data) => {
      started.push(data);
    });
    await Promise.all([write("l"), write("l"), write(" "), write(" ")]);
    expect(started).toEqual(["l", "l", " ", " "]);
  });

  it("continues after a failed write", async () => {
    const started: string[] = [];
    const write = createSerialWriter(async (data) => {
      started.push(data);
      if (data === "boom") throw new Error("pty gone");
    });
    await Promise.all([write("boom"), write("next")]);
    expect(started).toEqual(["boom", "next"]);
  });
});
