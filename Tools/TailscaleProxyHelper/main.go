package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"tailscale.com/tsnet"
)

type readyMessage struct {
	Type        string `json:"type"`
	Host        string `json:"host"`
	Port        int    `json:"port"`
	ControlPort int    `json:"controlPort"`
}

type udpRelayRequest struct {
	Target string `json:"target"`
	Port   int    `json:"port,omitempty"`
}

type udpRelayResponse struct {
	Start int `json:"start"`
	End   int `json:"end"`
}

func main() {
	if filepath.Base(os.Args[0]) == "tailscale-mosh-client" {
		runMoshClientProxy()
		return
	}
	hostname := flag.String("hostname", "shellharbor", "Tailscale node name")
	stateDir := flag.String("state-dir", "", "tsnet state directory")
	loginServer := flag.String("login-server", "", "Tailscale control URL")
	listenAddress := flag.String("listen", "127.0.0.1:0", "SOCKS5 listen address")
	listenStart := flag.Int("listen-start", 0, "find a loopback port starting here")
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

	listener, err := listenSOCKS(*listenAddress, *listenStart)
	if err != nil {
		fatal(err)
	}
	defer listener.Close()
	controlListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fatal(err)
	}
	defer controlListener.Close()
	controlServer := &http.Server{Handler: udpRelayHandler(ctx, server)}
	go func() { _ = controlServer.Serve(controlListener) }()
	defer controlServer.Close()
	address := listener.Addr().(*net.TCPAddr)
	controlAddress := controlListener.Addr().(*net.TCPAddr)
	if err := json.NewEncoder(os.Stdout).Encode(readyMessage{
		Type:        "ready",
		Host:        "127.0.0.1",
		Port:        address.Port,
		ControlPort: controlAddress.Port,
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
			return
		}
		go serveSOCKS(ctx, server, connection)
	}
}

func udpRelayHandler(ctx context.Context, server *tsnet.Server) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost || request.URL.Path != "/udp-relay" {
			http.NotFound(writer, request)
			return
		}
		var input udpRelayRequest
		if json.NewDecoder(request.Body).Decode(&input) != nil || strings.TrimSpace(input.Target) == "" {
			http.Error(writer, "invalid target", http.StatusBadRequest)
			return
		}
		var start, end int
		var err error
		if input.Port > 0 {
			start, err = startSingleUDPRelay(ctx, server, input.Target, input.Port)
			end = start
		} else {
			start, end, err = startUDPRelayRange(ctx, server, input.Target)
		}
		if err != nil {
			http.Error(writer, err.Error(), http.StatusServiceUnavailable)
			return
		}
		writer.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(writer).Encode(udpRelayResponse{Start: start, End: end})
	})
}

func startSingleUDPRelay(ctx context.Context, server *tsnet.Server, target string, remotePort int) (int, error) {
	connection, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		return 0, err
	}
	go relayUDP(ctx, server, connection, net.JoinHostPort(target, fmt.Sprint(remotePort)))
	return connection.LocalAddr().(*net.UDPAddr).Port, nil
}

func runMoshClientProxy() {
	client := "/opt/homebrew/bin/mosh-client"
	if configured := os.Getenv("SHELLHARBOR_MOSH_CLIENT"); configured != "" {
		client = configured
	}
	if len(os.Args) == 2 && os.Args[1] == "-c" {
		if err := syscall.Exec(client, []string{client, "-c"}, os.Environ()); err != nil {
			fatal(err)
		}
	}
	controlPort := os.Getenv("SHELLHARBOR_TAILSCALE_CONTROL_PORT")
	target := os.Getenv("SHELLHARBOR_TAILSCALE_TARGET")
	if controlPort == "" || target == "" || len(os.Args) < 3 {
		fatal(errors.New("missing Tailscale Mosh relay configuration"))
	}
	remotePort := os.Args[len(os.Args)-1]
	port, err := strconv.Atoi(remotePort)
	if err != nil {
		fatal(err)
	}
	body, _ := json.Marshal(udpRelayRequest{Target: target, Port: port})
	response, err := http.Post(
		"http://127.0.0.1:"+controlPort+"/udp-relay",
		"application/json",
		bytes.NewReader(body),
	)
	if err != nil {
		fatal(err)
	}
	defer response.Body.Close()
	var relay udpRelayResponse
	if response.StatusCode != http.StatusOK || json.NewDecoder(response.Body).Decode(&relay) != nil {
		fatal(errors.New("failed to create Tailscale Mosh relay"))
	}
	arguments := append([]string{client}, os.Args[1:]...)
	arguments[len(arguments)-2] = "127.0.0.1"
	arguments[len(arguments)-1] = fmt.Sprint(relay.Start)
	if err := syscall.Exec(client, arguments, os.Environ()); err != nil {
		fatal(err)
	}
}

func startUDPRelayRange(ctx context.Context, server *tsnet.Server, target string) (int, int, error) {
	const width = 10
	for start := 60000; start+width-1 <= 61000; start += width {
		connections := make([]*net.UDPConn, 0, width)
		for port := start; port < start+width; port++ {
			connection, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: port})
			if err != nil {
				for _, opened := range connections {
					_ = opened.Close()
				}
				connections = nil
				break
			}
			connections = append(connections, connection)
		}
		if len(connections) != width {
			continue
		}
		for offset, connection := range connections {
			go relayUDP(ctx, server, connection, net.JoinHostPort(target, fmt.Sprint(start+offset)))
		}
		return start, start + width - 1, nil
	}
	return 0, 0, errors.New("no available Mosh UDP relay range")
}

func relayUDP(ctx context.Context, server *tsnet.Server, local *net.UDPConn, target string) {
	defer local.Close()
	buffer := make([]byte, 65535)
	var client net.Addr
	var remote net.Conn
	for {
		count, source, err := local.ReadFrom(buffer)
		if err != nil {
			return
		}
		if remote == nil {
			remote, err = server.Dial(ctx, "udp", target)
			if err != nil {
				return
			}
			client = source
			go func() {
				response := make([]byte, 65535)
				for {
					count, err := remote.Read(response)
					if err != nil {
						return
					}
					_, _ = local.WriteTo(response[:count], client)
				}
			}()
		}
		_, _ = remote.Write(buffer[:count])
	}
}

func listenSOCKS(address string, start int) (net.Listener, error) {
	if start == 0 {
		return net.Listen("tcp", address)
	}
	for port := start; port <= 65535; port++ {
		listener, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", fmt.Sprint(port)))
		if err == nil {
			return listener, nil
		}
	}
	return nil, fmt.Errorf("no available loopback port from %d", start)
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
