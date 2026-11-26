import { constants, accessSync, writeSync } from "node:fs";
import { delimiter, join } from "node:path";

// Synchronous writes: a process that exits straight after a write must not lose it, and
// the ordering between stdout and stderr in a CI log is part of what the tests read.
function writeAll(fd: number, text: string): void {
  const buf = Buffer.from(text, "utf8");
  let off = 0;
  while (off < buf.length) {
    try {
      off += writeSync(fd, buf, off);
    } catch (e) {
      // A non-blocking pipe that is momentarily full; the reader will drain it.
      if ((e as NodeJS.ErrnoException).code === "EAGAIN") continue;
      throw e;
    }
  }
}

export const stdout = (text: string): void => writeAll(1, text);
export const stderr = (text: string): void => writeAll(2, text);

// Under --json the document is the only thing on stdout, so everything human moves to
// stderr and the document is written separately with `stdout`.
export class Console {
  private readonly jsonMode: boolean;
  constructor(jsonMode: boolean) {
    this.jsonMode = jsonMode;
  }
  human(text: string): void {
    if (this.jsonMode) stderr(text);
    else stdout(text);
  }
  err(text: string): void {
    stderr(text);
  }
}

// `command -v`: the first executable file named `name` on PATH.
export function onPath(name: string, pathVar = process.env["PATH"] ?? ""): string | null {
  for (const dir of pathVar.split(delimiter)) {
    if (dir === "") continue;
    const candidate = join(dir, name);
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // not here
    }
  }
  return null;
}

