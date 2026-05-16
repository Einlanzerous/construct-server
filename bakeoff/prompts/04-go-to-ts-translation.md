Translate this Go function to idiomatic TypeScript. The TS version should:

- Run on Bun (no Node-specific APIs)
- Use modern strict TypeScript — no `any`
- Be a pure function with no I/O
- Preserve the original semantics exactly
- Use idiomatic TS (e.g. `Date.now()` for unix millis would be wrong if the source uses int64 millis; just use `number`)

```go
package agentic

// Attempt represents a single retry attempt by the planning agent.
type Attempt struct {
    StartedAt int64  // unix millis
    Ok        bool
    Output    string
    Err       *AttemptError
}

type AttemptError struct {
    Severity int    // lower = less bad
    Message  string
}

// MergeAttempts collapses retry attempts into a single best result.
// Rules:
//   1. If any attempt succeeded (Ok=true), return that one — first success wins.
//   2. Otherwise, return the attempt with the lowest Err.Severity.
//   3. If multiple share the lowest severity, prefer the most recent (highest StartedAt).
//   4. Empty input returns nil.
func MergeAttempts(attempts []Attempt) *Attempt {
    if len(attempts) == 0 {
        return nil
    }
    var best *Attempt
    for i := range attempts {
        a := &attempts[i]
        if a.Ok {
            return a
        }
        if best == nil || a.Err.Severity < best.Err.Severity {
            best = a
            continue
        }
        if a.Err.Severity == best.Err.Severity && a.StartedAt > best.StartedAt {
            best = a
        }
    }
    return best
}
```

Show the full TypeScript file including the type definitions and the function. After the code, briefly (2-3 sentences) note any places where the Go-to-TS translation forced a judgment call (e.g. how you represented the pointer return, mutability of inputs).
