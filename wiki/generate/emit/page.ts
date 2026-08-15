/** One emitted Markdown file. `path` is extension-less and relative to the docs root. */
export interface Page {
  path: string;
  body: string;
}
