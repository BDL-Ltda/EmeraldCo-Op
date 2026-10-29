// Command joybusprobe is a disposable probe for the connection-options spike
// (issue #70, docs/connection-options.md). It is not the co-op client, it is
// not the relay, and nothing in production depends on it.
//
// It plays the GameCube side of the link that stock mGBA 0.10.5 opens from
// File > Connect to Dolphin... (src/gba/sio/dolphin.c at tag 0.10.5): mGBA
// connects to a data port and a clock port on the chosen host, reads 4-byte
// big-endian clock slices from the clock socket and JOY Bus commands from the
// data socket, and answers each command from the GBA's JOY Bus registers
// (src/gba/sio/joybus.c). The probe only reports what comes back; it never
// touches the relay.
package main

import (
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"time"
)

// JOY Bus commands, from include/mgba/gba/interface.h at mGBA 0.10.5.
const (
	cmdPoll  byte = 0x00
	cmdTrans byte = 0x14
	cmdRecv  byte = 0x15
	cmdReset byte = 0xFF
)

// Ports mGBA 0.10.5 always uses (DOLPHIN_DATA_PORT, DOLPHIN_CLOCK_PORT); the
// Qt dialog passes 0, which selects them.
const (
	defaultDataPort  = 54970
	defaultClockPort = 49420
)

// gbaHz is the GBA CPU clock (GBA_ARM7TDMI_FREQUENCY).
const gbaHz = 1 << 24

// replyLen is the number of bytes mGBA sends back for each command
// (GBASIOJOYSendCommand return values in src/gba/sio/joybus.c).
func replyLen(cmd byte) int {
	switch cmd {
	case cmdReset, cmdPoll:
		return 3 // device id (2 bytes) + JOYSTAT
	case cmdRecv:
		return 1 // JOYSTAT
	case cmdTrans:
		return 5 // JOY_TRANS (4 bytes, little-endian) + JOYSTAT
	}
	return 0
}

// link is one mGBA connection: the data and clock sockets.
type link struct {
	data, clock net.Conn
}

func (l *link) close() {
	l.data.Close()
	l.clock.Close()
}

// exchange grants mGBA credit emulated cycles, sends one command and waits for
// its reply. mGBA only reads a command after a clock slice, and reads a
// RECV's four data bytes in the same call as the command byte, so each
// message goes out in a single write.
func (l *link) exchange(cmd byte, payload []byte, credit int32, timeout time.Duration) ([]byte, error) {
	var clock [4]byte
	binary.BigEndian.PutUint32(clock[:], uint32(credit))
	if _, err := l.clock.Write(clock[:]); err != nil {
		return nil, fmt.Errorf("clock write: %w", err)
	}
	if _, err := l.data.Write(append([]byte{cmd}, payload...)); err != nil {
		return nil, fmt.Errorf("data write: %w", err)
	}
	reply := make([]byte, replyLen(cmd))
	if err := l.data.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		return nil, err
	}
	if _, err := io.ReadFull(l.data, reply); err != nil {
		return nil, fmt.Errorf("reply to 0x%02X: %w", cmd, err)
	}
	return reply, nil
}

type options struct {
	tick     time.Duration // time between exchanges
	timeout  time.Duration // how long to wait for one reply
	recvEach int           // send a RECV + TRANS pair every N exchanges
	report   time.Duration // how often to log statistics
	limit    int           // stop after this many exchanges (0: never)
}

// result summarizes one session, for logs and tests.
type result struct {
	exchanges int
	deviceID  uint16
	lastTrans uint32
	lastStat  byte
	maxRTT    time.Duration
}

// runSession drives one connected mGBA until an error or opts.limit.
func runSession(l *link, opts options, logf func(string, ...any)) (result, error) {
	var res result
	var word uint32 = 0xC0DE0000
	last := time.Now()
	windowStart, windowCount := last, 0
	var windowRTT time.Duration

	send := func(cmd byte, payload []byte) ([]byte, error) {
		now := time.Now()
		// Credit exactly the wall-clock time since the previous exchange, so
		// the probe paces emulation at real time without letting mGBA's
		// signed 32-bit clockSlice grow.
		credit := int32(now.Sub(last).Seconds() * gbaHz)
		if credit < 1 {
			credit = 1
		}
		last = now
		start := time.Now()
		reply, err := l.exchange(cmd, payload, credit, opts.timeout)
		if err != nil {
			return nil, err
		}
		rtt := time.Since(start)
		res.exchanges++
		windowCount++
		windowRTT += rtt
		if rtt > res.maxRTT {
			res.maxRTT = rtt
		}
		return reply, nil
	}

	reply, err := send(cmdReset, nil)
	if err != nil {
		return res, fmt.Errorf("no reply to RESET (is the JOY Bus driver active?): %w", err)
	}
	res.deviceID = binary.BigEndian.Uint16(reply[0:2])
	res.lastStat = reply[2]
	logf("RESET reply: device 0x%04X, JOYSTAT 0x%02X", res.deviceID, res.lastStat)

	for opts.limit == 0 || res.exchanges < opts.limit {
		time.Sleep(opts.tick)
		if opts.recvEach > 0 && res.exchanges%opts.recvEach == 0 {
			word++
			var payload [4]byte
			binary.LittleEndian.PutUint32(payload[:], word)
			reply, err = send(cmdRecv, payload[:])
			if err != nil {
				return res, err
			}
			res.lastStat = reply[0]
			reply, err = send(cmdTrans, nil)
			if err != nil {
				return res, err
			}
			trans := binary.LittleEndian.Uint32(reply[0:4])
			if trans != res.lastTrans || reply[4] != res.lastStat {
				logf("sent RECV 0x%08X; TRANS now 0x%08X, JOYSTAT 0x%02X", word, trans, reply[4])
			}
			res.lastTrans, res.lastStat = trans, reply[4]
		} else {
			reply, err = send(cmdPoll, nil)
			if err != nil {
				return res, err
			}
			res.lastStat = reply[2]
		}
		if opts.report > 0 && time.Since(windowStart) >= opts.report && windowCount > 0 {
			logf("%d exchanges in %s, mean RTT %s, max RTT %s",
				windowCount, time.Since(windowStart).Round(time.Millisecond),
				(windowRTT / time.Duration(windowCount)).Round(time.Microsecond),
				res.maxRTT.Round(time.Microsecond))
			windowStart, windowCount, windowRTT = time.Now(), 0, 0
		}
	}
	return res, nil
}

// accept waits for mGBA's two connections. mGBA connects the data socket
// first, then the clock socket.
func accept(data, clock net.Listener, clockWait time.Duration) (*link, error) {
	d, err := data.Accept()
	if err != nil {
		return nil, err
	}
	type accepted struct {
		c   net.Conn
		err error
	}
	ch := make(chan accepted, 1)
	go func() {
		c, err := clock.Accept()
		ch <- accepted{c, err}
	}()
	select {
	case a := <-ch:
		if a.err != nil {
			d.Close()
			return nil, a.err
		}
		return &link{data: d, clock: a.c}, nil
	case <-time.After(clockWait):
		d.Close()
		return nil, errors.New("data socket connected but the clock socket did not")
	}
}

func main() {
	host := flag.String("host", "127.0.0.1", "address to listen on; keep it on loopback")
	dataPort := flag.Int("data-port", defaultDataPort, "data port mGBA connects to")
	clockPort := flag.Int("clock-port", defaultClockPort, "clock port mGBA connects to")
	tick := flag.Duration("tick", 2*time.Millisecond, "time between exchanges")
	flag.Parse()

	data, err := net.Listen("tcp", net.JoinHostPort(*host, fmt.Sprint(*dataPort)))
	if err != nil {
		log.Fatal(err)
	}
	clock, err := net.Listen("tcp", net.JoinHostPort(*host, fmt.Sprint(*clockPort)))
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("waiting for mGBA: File > Connect to Dolphin... > Local computer > Connect")
	opts := options{tick: *tick, timeout: 2 * time.Second, recvEach: 30, report: 5 * time.Second}
	for {
		l, err := accept(data, clock, 5*time.Second)
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		log.Printf("mGBA connected")
		res, err := runSession(l, opts, log.Printf)
		l.close()
		log.Printf("session ended after %d exchanges: %v", res.exchanges, err)
		log.Printf("mGBA does not reconnect by itself: press Disconnect, then Connect, in its dialog")
	}
}
