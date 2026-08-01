package main

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"tailscale.com/tsnet"
)

type readyMessage struct {
	Type string `json:"type"`
	Host string `json:"host"`
	Port int    `json:"port"`
}

func main() {
	hostname := flag.String("hostname", "shellharbor", "Tailscale node name")
	stateDir := flag.String("state-dir", "", "tsnet state directory")
	loginServer := flag.String("login-server", "", "Tailscale control URL")
	listenAddress := flag.String("listen", "127.0.0.1:0", "SOCKS5 listen address")
	parentPID := flag.Int("parent-pid", 0, "exit after this process exits")
	flag.Parse()

	key, err := bufio.NewReader(os.Stdin).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		fatal(err)
	}
	key = strings.TrimSpace(key)
	if key == "" {
		fatal(errors.New("authentication key is empty"))
	}

	ctx, stop := signal.NotifyContext(
		context.Background(),
		os.Interrupt,
		syscall.SIGTERM,
	)
	defer stop()

	server := &tsnet.Server{
		Hostname:   *hostname,
		Dir:        *stateDir,
		AuthKey:    key,
		ControlURL: strings.TrimSpace(*loginServer),
		Logf:       func(string, ...any) {},
	}
	defer server.Close()
	if _, err := server.Up(ctx); err != nil {
		fatal(fmt.Errorf("start Tailscale: %w", err))
	}

	listener, err := net.Listen("tcp", *listenAddress)
	if err != nil {
		fatal(err)
	}
	defer listener.Close()
	address := listener.Addr().(*net.TCPAddr)
	if err := json.NewEncoder(os.Stdout).Encode(readyMessage{
		Type: "ready",
		Host: "127.0.0.1",
		Port: address.Port,
	}); err != nil {
		fatal(err)
	}

	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()
	if *parentPID > 0 {
		go monitorParent(ctx, *parentPID, listener)
	}
	for {
		connection, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			continue
		}
		go serveSOCKS(ctx, server, connection)
	}
}

func monitorParent(ctx context.Context, pid int, listener net.Listener) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			process, err := os.FindProcess(pid)
			if err != nil || process.Signal(syscall.Signal(0)) != nil {
				_ = listener.Close()
				return
			}
		}
	}
}

func serveSOCKS(ctx context.Context, server *tsnet.Server, client net.Conn) {
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(30 * time.Second))
	reader := bufio.NewReader(client)

	header := make([]byte, 2)
	if _, err := io.ReadFull(reader, header); err != nil || header[0] != 5 {
		return
	}
	methods := make([]byte, int(header[1]))
	if _, err := io.ReadFull(reader, methods); err != nil {
		return
	}
	if _, err := client.Write([]byte{5, 0}); err != nil {
		return
	}

	request := make([]byte, 4)
	if _, err := io.ReadFull(reader, request); err != nil ||
		request[0] != 5 || request[1] != 1 {
		return
	}
	host, err := readSOCKSHost(reader, request[3])
	if err != nil {
		writeSOCKSReply(client, 8)
		return
	}
	portBytes := make([]byte, 2)
	if _, err := io.ReadFull(reader, portBytes); err != nil {
		return
	}
	target := net.JoinHostPort(host, fmt.Sprint(binary.BigEndian.Uint16(portBytes)))
	remote, err := server.Dial(ctx, "tcp", target)
	if err != nil {
		writeSOCKSReply(client, 5)
		return
	}
	defer remote.Close()
	writeSOCKSReply(client, 0)
	_ = client.SetDeadline(time.Time{})

	done := make(chan struct{}, 1)
	go func() {
		_, _ = io.Copy(remote, reader)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(client, remote)
		done <- struct{}{}
	}()
	<-done
}

func readSOCKSHost(reader io.Reader, addressType byte) (string, error) {
	switch addressType {
	case 1:
		value := make([]byte, net.IPv4len)
		_, err := io.ReadFull(reader, value)
		return net.IP(value).String(), err
	case 4:
		value := make([]byte, net.IPv6len)
		_, err := io.ReadFull(reader, value)
		return net.IP(value).String(), err
	case 3:
		length := []byte{0}
		if _, err := io.ReadFull(reader, length); err != nil {
			return "", err
		}
		value := make([]byte, int(length[0]))
		_, err := io.ReadFull(reader, value)
		return string(value), err
	default:
		return "", errors.New("unsupported SOCKS address type")
	}
}

func writeSOCKSReply(writer io.Writer, result byte) {
	_, _ = writer.Write([]byte{5, result, 0, 1, 0, 0, 0, 0, 0, 0})
}

func fatal(err error) {
	message, _ := json.Marshal(map[string]string{
		"type":    "error",
		"message": err.Error(),
	})
	_, _ = fmt.Fprintln(os.Stderr, string(message))
	os.Exit(1)
}
