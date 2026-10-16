// Command echoserver is a test helper for the mGBA scripting spike (issue #8).
// It accepts TCP connections and writes every received line back unchanged.
// It is not the relay server.
package main

import (
	"bufio"
	"flag"
	"log"
	"net"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:8765", "address to listen on")
	flag.Parse()

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("echoing lines on %s", ln.Addr())
	serve(ln)
}

// serve accepts connections until ln is closed.
func serve(ln net.Listener) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		go echo(conn)
	}
}

// echo writes each line read from conn back to it, then closes conn.
func echo(conn net.Conn) {
	defer conn.Close()
	log.Printf("%s connected", conn.RemoteAddr())
	r := bufio.NewReader(conn)
	for {
		line, err := r.ReadBytes('\n')
		if len(line) > 0 {
			log.Printf("%s: %q", conn.RemoteAddr(), line)
			if _, werr := conn.Write(line); werr != nil {
				break
			}
		}
		if err != nil {
			break
		}
	}
	log.Printf("%s disconnected", conn.RemoteAddr())
}
