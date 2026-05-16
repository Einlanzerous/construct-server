The following Go function is supposed to fetch every URL concurrently with at most `concurrency` workers running at once, collecting all bodies into a slice. It compiles but is wrong in multiple ways.

Find every bug and produce a corrected version. Then write a one-paragraph explanation of what was broken and why your fix works.

```go
package fetcher

import (
    "io"
    "net/http"
    "sync"
)

func FetchAll(urls []string, concurrency int) []string {
    results := make([]string, 0, len(urls))
    sem := make(chan struct{}, concurrency)
    var wg sync.WaitGroup

    for _, url := range urls {
        wg.Add(1)
        sem <- struct{}{}
        go func() {
            defer wg.Done()
            defer func() { <-sem }()

            resp, err := http.Get(url)
            if err != nil {
                return
            }
            body, _ := io.ReadAll(resp.Body)
            results = append(results, string(body))
        }()
    }

    wg.Wait()
    return results
}
```

Constraints for your fix:
- Keep the same signature
- Preserve concurrency (bounded by `concurrency`)
- Order of results does not need to match input order
- Use `context.Context` for cancellation if you think it should
