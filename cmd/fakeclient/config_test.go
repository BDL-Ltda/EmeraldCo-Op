package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"strings"
	"testing"

	"github.com/DaviAlencastro/EmeraldCo-Op/internal/protocol"
)

const fixtureJoinKey = "fixture-key-never-real"

func noEnvironment(string) string { return "" }

func fixtureEnvironment(name string) string {
	if name == "FAKECLIENT_JOIN_KEY" {
		return fixtureJoinKey
	}
	return ""
}

func TestParseConfigDefaultsAndOverrides(t *testing.T) {
	got, err := parseConfig([]string{"-id", "bot1"}, fixtureEnvironment)
	if err != nil {
		t.Fatal(err)
	}
	wantHello := protocol.Hello{
		PlayerID: "bot1", JoinKey: fixtureJoinKey, TrainerID: 0,
		Gender: protocol.GenderMale, ClientVersion: "fakeclient",
	}
	if got.addr != "localhost:8765" || got.pattern != "square" || got.stepsPerSec != 4 || got.hello != wantHello {
		t.Fatal("defaults or synthetic identity do not match the documented CLI")
	}
	got, err = parseConfig([]string{
		"-addr", "localhost:9999", "-id", "bot_2", "-key", "fixture-flag-key",
		"-pattern", "warp", "-steps-per-sec", "2.5",
	}, fixtureEnvironment)
	if err != nil {
		t.Fatal(err)
	}
	if got.addr != "localhost:9999" || got.pattern != "warp" || got.stepsPerSec != 2.5 || got.hello.PlayerID != "bot_2" || got.hello.JoinKey != "fixture-flag-key" {
		t.Fatal("explicit flags did not override defaults and environment")
	}
	for _, pattern := range []string{"square", "idle", "warp"} {
		if _, err := parseConfig([]string{"-id", "bot1", "-pattern", pattern}, fixtureEnvironment); err != nil {
			t.Errorf("valid pattern %q: %v", pattern, err)
		}
	}
	for _, speed := range []string{"0.5", "40"} {
		if _, err := parseConfig([]string{"-id", "bot1", "-steps-per-sec", speed}, fixtureEnvironment); err != nil {
			t.Errorf("valid speed %q: %v", speed, err)
		}
	}
}

func TestParseConfigRejectsInvalidInputWithoutKeyDisclosure(t *testing.T) {
	for _, test := range []struct {
		name string
		args []string
		env  func(string) string
	}{
		{"missing ID", nil, fixtureEnvironment},
		{"invalid ID", []string{"-id", "bad id"}, fixtureEnvironment},
		{"long ID", []string{"-id", strings.Repeat("a", 17)}, fixtureEnvironment},
		{"missing key", []string{"-id", "bot1"}, noEnvironment},
		{"explicit empty key", []string{"-id", "bot1", "-key", ""}, fixtureEnvironment},
		{"invalid key", []string{"-id", "bot1", "-key", fixtureJoinKey + "\n"}, noEnvironment},
		{"empty address", []string{"-id", "bot1", "-addr", ""}, fixtureEnvironment},
		{"unknown pattern", []string{"-id", "bot1", "-pattern", "circle"}, fixtureEnvironment},
		{"zero speed", []string{"-id", "bot1", "-steps-per-sec", "0"}, fixtureEnvironment},
		{"negative speed", []string{"-id", "bot1", "-steps-per-sec", "-1"}, fixtureEnvironment},
		{"excessive speed", []string{"-id", "bot1", "-steps-per-sec", "40.1"}, fixtureEnvironment},
		{"NaN speed", []string{"-id", "bot1", "-steps-per-sec", "NaN"}, fixtureEnvironment},
		{"infinite speed", []string{"-id", "bot1", "-steps-per-sec", "+Inf"}, fixtureEnvironment},
		{"unrepresentable timer interval", []string{"-id", "bot1", "-steps-per-sec", "1e-300"}, fixtureEnvironment},
		{"invalid speed", []string{"-id", "bot1", "-steps-per-sec", "not-a-number"}, fixtureEnvironment},
		{"unknown flag", []string{"-id", "bot1", "-unknown"}, fixtureEnvironment},
		{"positional argument", []string{"-id", "bot1", "extra"}, fixtureEnvironment},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, err := parseConfig(test.args, test.env)
			if err == nil {
				t.Fatal("expected invalid configuration to fail")
			}
			if strings.Contains(err.Error(), fixtureJoinKey) {
				t.Fatal("configuration error disclosed the fixture join key")
			}
		})
	}
}

func TestHelpDoesNotNeedIdentityOrDiscloseKey(t *testing.T) {
	if _, err := parseConfig([]string{"-h"}, fixtureEnvironment); !errors.Is(err, flag.ErrHelp) {
		t.Fatalf("help: got %v, want flag.ErrHelp", err)
	}
	var output bytes.Buffer
	if err := run(context.Background(), []string{"-h"}, fixtureEnvironment, &output); err != nil {
		t.Fatalf("run help: %v", err)
	}
	if !strings.Contains(output.String(), "-id") || !strings.Contains(output.String(), "-pattern") {
		t.Fatal("help does not describe the CLI flags")
	}
	if strings.Contains(output.String(), fixtureJoinKey) {
		t.Fatal("help disclosed the environment join key")
	}
}

func TestRunInvalidConfigurationDoesNotDialOrDiscloseKey(t *testing.T) {
	var output bytes.Buffer
	err := run(context.Background(), []string{"-id", "bad id", "-key", fixtureJoinKey}, noEnvironment, &output)
	if err == nil {
		t.Fatal("expected configuration error")
	}
	if strings.Contains(output.String(), fixtureJoinKey) || strings.Contains(err.Error(), fixtureJoinKey) {
		t.Fatal("configuration failure disclosed the fixture join key")
	}
}
