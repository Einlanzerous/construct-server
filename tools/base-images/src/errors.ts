// A refusal is exit 2: bad usage, a missing dependency, an unreadable policy, or a document
// that could not be assembled. It is never exit 1, which means "the sweep found something".
export class Refusal extends Error {}

export function die(message: string): never {
  throw new Refusal(message);
}
