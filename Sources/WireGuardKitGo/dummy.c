//go:build darwin

// Empty — present so Xcode treats the directory as containing C sources.
// The build constraint keeps non-darwin `go build` (used for native tests of
// the untagged pure-logic files) from requiring cgo.
