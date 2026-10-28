// Command fakeclient simulates a player using the shared TCP protocol.
package main

import (
	"context"
	"errors"
	"flag"
	"io"
	"log"
	"math"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/DaviAlencastro/EmeraldCo-Op/internal/protocol"
)

type config struct {
	addr          string
	hello         protocol.Hello
	pattern       string
	stepsPerSec   float64
	tradeTarget   string
	confirmTarget string
}

func parseConfig(args []string, getenv func(string) string) (config, error) {
	var cfg config
	flags := flag.NewFlagSet("fakeclient", flag.ContinueOnError)
	// Flag errors and defaults can contain the private key. Print static help.
	flags.SetOutput(io.Discard)
	flags.StringVar(&cfg.addr, "addr", "localhost:8765", "server address")
	flags.StringVar(&cfg.hello.PlayerID, "id", "", "required player ID")
	flags.StringVar(&cfg.hello.JoinKey, "key", getenv("FAKECLIENT_JOIN_KEY"), "shared key")
	flags.StringVar(&cfg.pattern, "pattern", "square", "square, idle or warp")
	flags.Float64Var(&cfg.stepsPerSec, "steps-per-sec", 4, "steps per second (greater than 0, at most 40)")
	flags.StringVar(&cfg.tradeTarget, "trade", "", "optional player ID to send one of each trade message to after welcome")
	flags.StringVar(&cfg.confirmTarget, "trade-confirm", "", "send one synthetic confirm when this player is online (audit test only)")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return config{}, err
		}
		return config{}, errors.New("invalid fakeclient flags; use -h for help")
	}
	if flags.NArg() != 0 {
		return config{}, errors.New("unexpected positional arguments")
	}
	if cfg.addr == "" {
		return config{}, errors.New("addr must not be empty")
	}
	switch cfg.pattern {
	case "square", "idle", "warp":
	default:
		return config{}, errors.New("pattern must be square, idle or warp")
	}
	if math.IsNaN(cfg.stepsPerSec) || math.IsInf(cfg.stepsPerSec, 0) || cfg.stepsPerSec <= 0 || cfg.stepsPerSec > 40 {
		return config{}, errors.New("steps-per-sec must be finite, greater than 0 and at most 40")
	}
	if float64(time.Second)/cfg.stepsPerSec >= float64(math.MaxInt64) {
		return config{}, errors.New("steps-per-sec is too small for a timer interval")
	}
	if cfg.tradeTarget != "" && cfg.confirmTarget != "" {
		return config{}, errors.New("trade and trade-confirm are mutually exclusive")
	}
	for _, target := range []string{cfg.tradeTarget, cfg.confirmTarget} {
		if target != "" {
			if err := (protocol.TradeInvite{PlayerID: "x", TargetID: target}).Validate(); err != nil {
				return config{}, errors.New("trade target must be a valid player ID")
			}
		}
	}
	if cfg.confirmTarget == cfg.hello.PlayerID && cfg.confirmTarget != "" {
		return config{}, errors.New("trade-confirm must target another player")
	}
	cfg.hello.TrainerID = 0
	cfg.hello.Gender = protocol.GenderMale
	cfg.hello.ClientVersion = "fakeclient"
	if err := cfg.hello.Validate(); err != nil {
		return config{}, err
	}
	return cfg, nil
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Getenv, os.Stdout); err != nil {
		log.Print(err)
		os.Exit(1)
	}
}
