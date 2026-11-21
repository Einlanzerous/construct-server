# Extra targets file

`~/.config/frontend-audit/targets` lists audit targets that have no Switchyard
project or are not listed on the board. It is local and untracked; it lives
outside every repo so names in it never reach a public one. Never copy its
entries into this skill, a ticket, a PR or a commit.

Format, one target per line:

    KEY | NAME | SOURCE | WEB_DIR

- `SOURCE` is a local checkout path (`~` allowed), or `git:<owner>/<repo>` for
  a repo with no persistent checkout. Shallow-clone those into the session
  scratchpad (`gh repo clone <owner>/<repo> <dir> -- --depth 1`), never
  somewhere permanent.
- `WEB_DIR` is the frontend directory inside the checkout.
- Blank lines and lines starting with `#` are ignored.

If the file is missing, create it with just this header and tell the operator
it has no entries:

    # frontend-audit extra targets. Local and untracked: never commit this file.
    # One target per line: KEY | NAME | SOURCE | WEB_DIR
    #   SOURCE   a local checkout path, or git:<owner>/<repo> (shallow-cloned)
    #   WEB_DIR  the frontend directory inside that checkout
