package main

import (
	"bufio"
	"net"
	"testing"
	"time"
)

func TestServeEchoesLines(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go serve(ln)

	conn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}

	r := bufio.NewReader(conn)
	for _, want := range []string{"hello\n", "ping 1\n"} {
		if _, err := conn.Write([]byte(want)); err != nil {
			t.Fatal(err)
		}
		got, err := r.ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		if got != want {
			t.Errorf("echo = %q, want %q", got, want)
		}
	}
}
