// Command symgen generates Lua global addresses from a ROM build's ELF.
package main

import (
	_ "embed"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

//go:embed symbols.txt
var defaultSymbols string

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("symgen", flag.ContinueOnError)
	flags.SetOutput(stderr)
	elfPath := flags.String("elf", "", "ELF from the ROM build (required)")
	romPath := flags.String("rom", "", "ROM from the same build (required)")
	outPath := flags.String("out", "", "generated Lua output path (required)")
	symbolsPath := flags.String("symbols", "", "override the embedded symbol allowlist")
	flags.Usage = func() {
		fmt.Fprintln(stderr, "Usage: symgen -elf FILE -rom FILE -out FILE [-symbols FILE]")
		flags.PrintDefaults()
	}
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}
	if *elfPath == "" || *romPath == "" || *outPath == "" || flags.NArg() != 0 {
		fmt.Fprintln(stderr, "symgen: -elf, -rom and -out are required; positional arguments are not supported")
		flags.Usage()
		return 2
	}

	elfFile, err := os.Open(*elfPath)
	if err != nil {
		fmt.Fprintf(stderr, "symgen: open ELF: %v\n", err)
		return 1
	}
	defer elfFile.Close()
	romFile, err := os.Open(*romPath)
	if err != nil {
		fmt.Fprintf(stderr, "symgen: open ROM: %v\n", err)
		return 1
	}
	defer romFile.Close()

	var allowlist io.Reader = strings.NewReader(defaultSymbols)
	if *symbolsPath != "" {
		file, err := os.Open(*symbolsPath)
		if err != nil {
			fmt.Fprintf(stderr, "symgen: open symbol allowlist: %v\n", err)
			return 1
		}
		defer file.Close()
		allowlist = file
	}
	output, err := generate(elfFile, romFile, allowlist)
	if err != nil {
		fmt.Fprintf(stderr, "symgen: %v\n", err)
		return 1
	}
	if err := writeOutput(*outPath, output); err != nil {
		fmt.Fprintf(stderr, "symgen: write output: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "symgen: wrote %s\n", *outPath)
	return 0
}

// Prepare the complete replacement beside the destination before renaming it.
// In particular, generation failures never truncate an existing address file.
func writeOutput(path string, data []byte) error {
	temp, err := os.CreateTemp(filepath.Dir(path), ".symgen-*")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if err := temp.Chmod(0o644); err != nil {
		temp.Close()
		return err
	}
	if _, err := temp.Write(data); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(tempPath, path)
}
