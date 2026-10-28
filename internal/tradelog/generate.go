//go:build ignore

// Generate the standalone server's species names from the pinned decomp.
// Run from this directory: go run generate.go -rom ../../rom -out species_names.go
package main

import (
	"bytes"
	"flag"
	"fmt"
	"go/format"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

func main() {
	rom := flag.String("rom", "../../rom", "pinned ROM source directory")
	out := flag.String("out", "species_names.go", "generated Go file")
	flag.Parse()
	constants, err := os.ReadFile(filepath.Join(*rom, "include/constants/species.h"))
	check(err)
	names, err := os.ReadFile(filepath.Join(*rom, "src/data/text/species_names.h"))
	check(err)
	ids := map[string]int{}
	for _, m := range regexp.MustCompile(`(?m)^#define (SPECIES_\w+) (\d+)\s*$`).FindAllStringSubmatch(string(constants), -1) {
		ids[m[1]], err = strconv.Atoi(m[2])
		check(err)
	}
	values := make([]string, ids["SPECIES_EGG"]+1)
	for _, m := range regexp.MustCompile(`\[(SPECIES_\w+)\] = _\("([^"]*)"\)`).FindAllStringSubmatch(string(names), -1) {
		id, ok := ids[m[1]]
		if !ok {
			panic("species name without a numeric ID: " + m[1])
		}
		name := m[2]
		if strings.Trim(name, "?") == "" {
			name = strings.TrimPrefix(m[1], "SPECIES_")
		}
		values[id] = name
	}
	values[ids["SPECIES_EGG"]] = "EGG"
	var source bytes.Buffer
	fmt.Fprintln(&source, "// Code generated from the pinned ROM species.h and species_names.h; DO NOT EDIT.")
	fmt.Fprintln(&source, "// See docs/memory-map.md#pokemon-bytes-in-the-trade-log for source revisions.")
	fmt.Fprintln(&source, "//go:generate go run generate.go -rom ../../rom -out species_names.go")
	fmt.Fprintln(&source, "\npackage tradelog\n\nvar speciesNames = [...]string{")
	for id, name := range values {
		if name == "" {
			panic(fmt.Sprintf("missing species name for ID %d", id))
		}
		fmt.Fprintf(&source, "\t%d: %q,\n", id, name)
	}
	fmt.Fprintln(&source, "}")
	formatted, err := format.Source(source.Bytes())
	check(err)
	check(os.WriteFile(*out, formatted, 0o644))
}

func check(err error) {
	if err != nil {
		panic(err)
	}
}
