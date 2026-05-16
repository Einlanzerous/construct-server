Write table-driven tests for the following Go function. The test file should compile and pass with `go test ./...`. Use `github.com/stretchr/testify/assert` for assertions.

Cover: happy paths, all error branches, edge cases (whitespace, empty parts, leading/trailing dashes, very long numbers, negative numbers if the function admits them, unicode prefixes).

```go
package ticket

import (
    "fmt"
    "strings"
)

// ParseRef extracts the project key and ticket number from refs like
// "SWY-42" or "loop-7" (case-insensitive prefix). Returns the uppercased
// prefix, the integer suffix, and an error if the format is invalid.
func ParseRef(ref string) (string, int, error) {
    ref = strings.TrimSpace(ref)
    if ref == "" {
        return "", 0, fmt.Errorf("empty ref")
    }
    parts := strings.SplitN(ref, "-", 2)
    if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
        return "", 0, fmt.Errorf("ref %q missing prefix or number", ref)
    }
    var num int
    if _, err := fmt.Sscanf(parts[1], "%d", &num); err != nil {
        return "", 0, fmt.Errorf("ref %q has non-numeric suffix", ref)
    }
    return strings.ToUpper(parts[0]), num, nil
}
```

Show the complete `ticket_test.go` file. Use a slice of struct test cases, name each case clearly, and use `t.Run` for sub-tests.
