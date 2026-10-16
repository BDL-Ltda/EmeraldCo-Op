package main

import (
	"bufio"
	"bytes"
	"context"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
)

func env(values map[string]string) func(string) string {
	return func(name string) string { return values[name] }
}

func TestSIGTERMShutdown(t *testing.T) {
	if os.Getenv("EMERALD_SIGNAL_TEST") == "1" {
		os.Args = []string{"server"}
		main()
		return
	}
	if runtime.GOOS == "windows" {
		t.Skip("sending SIGTERM is a Unix process test")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestSIGTERMShutdown$")
	cmd.Env = append(os.Environ(), "EMERALD_SIGNAL_TEST=1", "SERVER_JOIN_KEY=test-key", "SERVER_ADDR=127.0.0.1:0", "SERVER_MAX_PLAYERS=5")
	stderr, err := cmd.StderrPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()
	lines := bufio.NewScanner(stderr)
	if !lines.Scan() || !strings.Contains(lines.Text(), "listening addr=") {
		t.Fatalf("child did not start listener: %s", lines.Text())
	}
	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	if err := cmd.Wait(); err != nil {
		t.Fatalf("SIGTERM did not take graceful exit path: %v", err)
	}
}

func TestConfigDefaultsAndOverrides(t *testing.T) {
	cfg, err := parseConfig(nil, env(map[string]string{"SERVER_JOIN_KEY": "test-key"}))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.addr != ":8765" || cfg.room.MaxPlayers != 5 || cfg.room.JoinKey != "test-key" {
		t.Fatalf("defaults: %#v", cfg)
	}
	values := map[string]string{"SERVER_ADDR": ":9000", "SERVER_JOIN_KEY": "env-key", "SERVER_MAX_PLAYERS": "3"}
	cfg, err = parseConfig(nil, env(values))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.addr != ":9000" || cfg.room.MaxPlayers != 3 || cfg.room.JoinKey != "env-key" {
		t.Fatal("environment fallback failed")
	}
	values["SERVER_MAX_PLAYERS"] = "invalid"
	cfg, err = parseConfig([]string{"-addr", ":9001", "-join-key", "flag-key", "-max-players", "2"}, env(values))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.addr != ":9001" || cfg.room.MaxPlayers != 2 || cfg.room.JoinKey != "flag-key" {
		t.Fatal("flag overrides failed")
	}
}

func TestInvalidConfig(t *testing.T) {
	for _, args := range [][]string{
		nil, {"-join-key", ""}, {"-join-key", "bad\nkey"},
		{"-join-key", strings.Repeat("x", 65)},
		{"-join-key", "test-key", "-max-players", "0"},
		{"-join-key", "test-key", "-max-players", "6"},
		{"-join-key", "test-key", "-max-players", "invalid"},
		{"-join-key", "test-key", "-addr", ""},
		{"-unknown"}, {"-join-key"}, {"unexpected"},
	} {
		if _, err := parseConfig(args, env(nil)); err == nil {
			t.Fatalf("accepted invalid config %q", args)
		}
	}
}

func TestHelpAndErrorsNeverPrintKey(t *testing.T) {
	for _, args := range [][]string{{"-h"}, {"-unknown"}, {"-max-players", "private-config-key"}, nil} {
		var output bytes.Buffer
		err := run(context.Background(), args, env(map[string]string{"SERVER_JOIN_KEY": "private-config-key", "SERVER_MAX_PLAYERS": "0"}), &output)
		if strings.Contains(output.String(), "private-config-key") || (err != nil && strings.Contains(err.Error(), "private-config-key")) {
			t.Fatal("key exposed in configuration output")
		}
		if len(args) > 0 && args[0] == "-h" && (err != nil || !strings.Contains(output.String(), "Usage:")) {
			t.Fatal("help failed")
		}
	}
}

func TestRunRejectsMissingKeyBeforeListening(t *testing.T) {
	if err := run(context.Background(), []string{"-addr", "invalid-address"}, env(nil), &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "join-key") {
		t.Fatalf("got %v, want missing-key error", err)
	}
}

func TestRunListenerAndCancellation(t *testing.T) {
	getenv := env(map[string]string{"SERVER_JOIN_KEY": "test-key"})
	if err := run(context.Background(), []string{"-addr", "invalid-address"}, getenv, &bytes.Buffer{}); err == nil {
		t.Fatal("expected listener error")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	var output bytes.Buffer
	if err := run(ctx, []string{"-addr", "127.0.0.1:0"}, getenv, &output); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "listening") || strings.Contains(output.String(), "test-key") {
		t.Fatal("expected listener log without key")
	}
}
