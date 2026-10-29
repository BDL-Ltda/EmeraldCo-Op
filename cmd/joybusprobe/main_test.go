package main

import (
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"
)

// fakeGBA models the mGBA 0.10.5 side of the link, transcribed from
// src/gba/sio/dolphin.c (_processCommand) and src/gba/sio/joybus.c
// (GBASIOJOYSendCommand). It checks the probe's framing only; it is not
// evidence about real mGBA behavior.
type fakeGBA struct {
	joystat byte
	trans   uint32 // what the ROM wrote to JOY_TRANS
	recv    uint32 // what the host last wrote with RECV
	clock   int64  // total credit granted
}

func (g *fakeGBA) serve(t *testing.T, data, clock net.Conn) {
	t.Helper()
	for {
		var c [4]byte
		if _, err := io.ReadFull(clock, c[:]); err != nil {
			return
		}
		g.clock += int64(int32(binary.BigEndian.Uint32(c[:])))
		var cmd [1]byte
		if _, err := io.ReadFull(data, cmd[:]); err != nil {
			return
		}
		var reply []byte
		switch cmd[0] {
		case cmdReset, cmdPoll:
			reply = []byte{0x00, 0x04, g.joystat}
		case cmdRecv:
			var p [4]byte
			if _, err := io.ReadFull(data, p[:]); err != nil {
				return
			}
			g.recv = binary.LittleEndian.Uint32(p[:])
			g.joystat |= 0x02 // JOYSTAT_RECV
			reply = []byte{g.joystat}
		case cmdTrans:
			reply = make([]byte, 5)
			binary.LittleEndian.PutUint32(reply, g.trans)
			reply[4] = g.joystat
			g.joystat &^= 0x08 // JOYSTAT_TRANS
		default:
			t.Errorf("unexpected command 0x%02X", cmd[0])
			return
		}
		if _, err := data.Write(reply); err != nil {
			return
		}
	}
}

func TestProbeAgainstModel(t *testing.T) {
	dataLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer dataLn.Close()
	clockLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer clockLn.Close()

	g := &fakeGBA{joystat: 0x08, trans: 0x12345678}
	done := make(chan struct{})
	go func() {
		defer close(done)
		// Same order as GBASIODolphinConnect: data, then clock.
		data, err := net.Dial("tcp", dataLn.Addr().String())
		if err != nil {
			t.Error(err)
			return
		}
		defer data.Close()
		clock, err := net.Dial("tcp", clockLn.Addr().String())
		if err != nil {
			t.Error(err)
			return
		}
		defer clock.Close()
		g.serve(t, data, clock)
	}()

	l, err := accept(dataLn, clockLn, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	opts := options{tick: time.Millisecond, timeout: time.Second, recvEach: 5, limit: 40}
	res, err := runSession(l, opts, t.Logf)
	l.close()
	<-done
	if err != nil {
		t.Fatal(err)
	}
	if res.deviceID != 0x0004 {
		t.Errorf("device id = 0x%04X, want 0x0004", res.deviceID)
	}
	if res.lastTrans != 0x12345678 {
		t.Errorf("TRANS = 0x%08X, want 0x12345678", res.lastTrans)
	}
	if g.recv>>16 != 0xC0DE {
		t.Errorf("RECV word = 0x%08X, want the probe's 0xC0DExxxx counter", g.recv)
	}
	if res.exchanges < opts.limit {
		t.Errorf("exchanges = %d, want at least %d", res.exchanges, opts.limit)
	}
	if g.clock <= 0 {
		t.Errorf("total clock credit = %d, want > 0", g.clock)
	}
}

func TestAcceptNeedsClockSocket(t *testing.T) {
	dataLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer dataLn.Close()
	clockLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer clockLn.Close()
	c, err := net.Dial("tcp", dataLn.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if _, err := accept(dataLn, clockLn, 100*time.Millisecond); err == nil {
		t.Fatal("accept succeeded without a clock connection")
	}
}
