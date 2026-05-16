Refactor the following TypeScript function. It works most of the time, but it's hard to read, mixes concerns, and has at least two real bugs. Produce a cleaner version with these properties:

- No nested `.then` chains — use `async/await` throughout
- Errors from any step propagate to the caller (no silent swallowing)
- Parallelize the two genuinely independent fetches (`projects.findById` and `users.findById` can run concurrently with each other; `history.byTicket` can too)
- Strict TypeScript — no `any`. Define proper types for the `db` parameter
- Add a short header comment listing any **behavior changes** from the original

```typescript
type HistoryEvent = { id: string; ts: number; kind: string; payload: unknown };

type EnrichedTicket = {
    id: string;
    title: string;
    project: { id: string; name: string };
    assignee: { id: string; displayName: string } | null;
    history: HistoryEvent[];
};

async function enrichTicket(ticketId: string, db: any): Promise<EnrichedTicket | null> {
    return db.tickets.findById(ticketId).then((t: any) => {
        if (!t) return null;
        return db.projects.findById(t.project_id).then((proj: any) => {
            if (t.assignee_id) {
                return db.users.findById(t.assignee_id).then((u: any) => {
                    return db.history.byTicket(ticketId).then((history: any) => {
                        return {
                            id: t.id, title: t.title,
                            project: { id: proj.id, name: proj.name },
                            assignee: { id: u.id, displayName: u.display_name },
                            history,
                        };
                    });
                });
            } else {
                return db.history.byTicket(ticketId).then((history: any) => {
                    return {
                        id: t.id, title: t.title,
                        project: { id: proj.id, name: proj.name },
                        assignee: null,
                        history,
                    };
                });
            }
        });
    });
}
```

After the refactored code:
1. Name each bug you found and explain the fix in one line
2. Note any behavior preserved that you suspect is actually wrong but didn't change (because the spec is ambiguous)
