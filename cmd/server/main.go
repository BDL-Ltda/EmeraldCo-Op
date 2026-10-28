// Command server runs the single-room TCP presence server.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"strconv"
	"syscall"

	"github.com/DaviAlencastro/EmeraldCo-Op/internal/room"
	"github.com/DaviAlencastro/EmeraldCo-Op/internal/tradelog"
)

type config struct {
	addr         string
	room         room.Config
	tradeLogPath string
}

func parseConfig(args []string, getenv func(string) string) (config, error) {
	fallback := func(name, value string) string {
		if env := getenv(name); env != "" {
			return env
		}
		return value
	}
	var cfg config
	flags := flag.NewFlagSet("server", flag.ContinueOnError)
	// Do not print defaults: they can contain the private environment key.
	flags.SetOutput(io.Discard)
	flags.StringVar(&cfg.addr, "addr", fallback("SERVER_ADDR", ":8765"), "listen address")
	flags.StringVar(&cfg.room.JoinKey, "join-key", getenv("SERVER_JOIN_KEY"), "required shared key")
	max := flags.String("max-players", fallback("SERVER_MAX_PLAYERS", "5"), "room capacity (1-5)")
	flags.StringVar(&cfg.tradeLogPath, "trade-log", tradelog.DefaultPath, "append-only trade log path")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return config{}, err
		}
		return config{}, errors.New("invalid server flags; use -h for help")
	}
	if flags.NArg() != 0 {
		return config{}, errors.New("unexpected positional arguments")
	}
	var err error
	cfg.room.MaxPlayers, err = strconv.Atoi(*max)
	if err != nil {
		return config{}, errors.New("max-players must be an integer from 1 to 5")
	}
	if cfg.addr == "" {
		return config{}, errors.New("addr must not be empty")
	}
	if cfg.tradeLogPath == "" {
		return config{}, errors.New("trade-log must not be empty")
	}
	if err := cfg.room.Validate(); err != nil {
		return config{}, err
	}
	return cfg, nil
}

func run(ctx context.Context, args []string, getenv func(string) string, output io.Writer) error {
	cfg, err := parseConfig(args, getenv)
	if errors.Is(err, flag.ErrHelp) {
		_, err = fmt.Fprintln(output, "Usage: server [-addr ADDRESS] [-join-key KEY] [-max-players 1-5] [-trade-log PATH]\nEnvironment fallbacks: SERVER_ADDR, SERVER_JOIN_KEY, SERVER_MAX_PLAYERS.\nDefaults: addr=:8765, max-players=5, trade-log=trade-log.jsonl (working directory). A join key is required.")
		return err
	}
	if err != nil {
		return err
	}
	logger := log.New(output, "", log.LstdFlags)
	cfg.room.TradeLog = tradelog.NewFile(cfg.tradeLogPath)
	server, err := room.New(cfg.room, logger)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", cfg.addr)
	if err != nil {
		return err
	}
	logger.Printf("listening addr=%q max_players=%d", listener.Addr(), cfg.room.MaxPlayers)
	return server.Serve(ctx, listener)
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Getenv, os.Stderr); err != nil {
		log.Print(err)
		os.Exit(1)
	}
}
