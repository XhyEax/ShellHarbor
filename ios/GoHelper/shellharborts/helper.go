package shellharborts

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"

	xproxy "golang.org/x/net/proxy"
	"tailscale.com/tsnet"
)

// Proxy owns one reusable tsnet node and any TCP forwarders opened through it.
// Its exported surface intentionally uses only gomobile-compatible types.
type Proxy struct {
	mu        sync.Mutex
	server    *tsnet.Server
	listeners []net.Listener
	packets   []net.PacketConn
	remotes   []net.Conn
	ctx       context.Context
	cancel    context.CancelFunc
}

func NewProxy() *Proxy { return &Proxy{} }

func (p *Proxy) Start(stateDir, hostname, loginServer, authKey string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.server != nil {
		return nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	server := &tsnet.Server{
		Dir:        stateDir,
		Hostname:   hostname,
		ControlURL: loginServer,
		AuthKey:    authKey,
		Ephemeral:  false,
		Logf:       func(string, ...any) {},
	}
	startupCtx, stopStartup := context.WithTimeout(ctx, 45*time.Second)
	defer stopStartup()
	if _, err := server.Up(startupCtx); err != nil {
		cancel()
		_ = server.Close()
		if errors.Is(err, context.DeadlineExceeded) {
			return errors.New("tailscale start timed out after 45 seconds")
		}
		return fmt.Errorf("tailscale start failed: %w", err)
	}
	p.server = server
	p.ctx = ctx
	p.cancel = cancel
	return nil
}

// Forward opens the first free loopback port starting at startPort and routes
// accepted TCP connections to targetHost:targetPort through tsnet.
func (p *Proxy) Forward(targetHost string, targetPort, startPort int) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.server == nil {
		return 0, errors.New("tailscale proxy is not started")
	}
	target := net.JoinHostPort(targetHost, strconv.Itoa(targetPort))
	return p.listenLocked(startPort, func() (net.Conn, error) {
		return p.server.Dial(p.ctx, "tcp", target)
	})
}

// ForwardUDP opens the first free loopback UDP port starting at startPort and
// routes datagrams to targetHost:targetPort through the reusable tsnet node.
// Mosh uses a single connected UDP peer, so one forwarder can preserve its
// bidirectional packet flow without exposing the tailnet identity to iOS.
func (p *Proxy) ForwardUDP(targetHost string, targetPort, startPort int) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.server == nil {
		return 0, errors.New("tailscale proxy is not started")
	}
	target := net.JoinHostPort(targetHost, strconv.Itoa(targetPort))
	return p.listenUDPLocked(startPort, func() (net.Conn, error) {
		return p.server.Dial(p.ctx, "udp", target)
	})
}

// ForwardSOCKS5 exposes a loopback forwarder that connects through an existing
// SOCKS5 proxy. Credentials are intentionally unsupported until the profile
// model has a protected credential field.
func (p *Proxy) ForwardSOCKS5(proxyHost string, proxyPort int, targetHost string, targetPort, startPort int) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	dialer, err := xproxy.SOCKS5(
		"tcp",
		net.JoinHostPort(proxyHost, strconv.Itoa(proxyPort)),
		nil,
		&net.Dialer{Timeout: 20 * time.Second},
	)
	if err != nil {
		return 0, fmt.Errorf("invalid SOCKS5 proxy: %w", err)
	}
	target := net.JoinHostPort(targetHost, strconv.Itoa(targetPort))
	return p.listenLocked(startPort, func() (net.Conn, error) { return dialer.Dial("tcp", target) })
}

// ForwardHTTPConnect exposes a loopback forwarder through an HTTP CONNECT proxy.
func (p *Proxy) ForwardHTTPConnect(proxyHost string, proxyPort int, targetHost string, targetPort, startPort int) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	proxyAddress := net.JoinHostPort(proxyHost, strconv.Itoa(proxyPort))
	target := net.JoinHostPort(targetHost, strconv.Itoa(targetPort))
	return p.listenLocked(startPort, func() (net.Conn, error) {
		conn, err := net.DialTimeout("tcp", proxyAddress, 20*time.Second)
		if err != nil {
			return nil, err
		}
		_ = conn.SetDeadline(time.Now().Add(20 * time.Second))
		if _, err = fmt.Fprintf(conn, "CONNECT %s HTTP/1.1\r\nHost: %s\r\nProxy-Connection: Keep-Alive\r\n\r\n", target, target); err != nil {
			_ = conn.Close()
			return nil, err
		}
		reader := bufio.NewReader(conn)
		response, err := http.ReadResponse(reader, &http.Request{Method: http.MethodConnect})
		if err != nil {
			_ = conn.Close()
			return nil, err
		}
		if response.StatusCode < 200 || response.StatusCode >= 300 {
			_ = response.Body.Close()
			_ = conn.Close()
			return nil, fmt.Errorf("HTTP CONNECT failed: %s", response.Status)
		}
		_ = conn.SetDeadline(time.Time{})
		return &bufferedConn{Conn: conn, reader: reader}, nil
	})
}

type bufferedConn struct {
	net.Conn
	reader *bufio.Reader
}

func (c *bufferedConn) Read(data []byte) (int, error) { return c.reader.Read(data) }

func (p *Proxy) listenLocked(startPort int, dial func() (net.Conn, error)) (int, error) {
	var listener net.Listener
	var port int
	var err error
	for candidate := startPort; candidate < startPort+1000; candidate++ {
		listener, err = net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(candidate)))
		if err == nil {
			port = candidate
			break
		}
	}
	if listener == nil {
		return 0, fmt.Errorf("no loopback port available: %w", err)
	}
	p.listeners = append(p.listeners, listener)
	go p.accept(listener, dial)
	return port, nil
}

func (p *Proxy) listenUDPLocked(startPort int, dial func() (net.Conn, error)) (int, error) {
	remote, err := dial()
	if err != nil {
		return 0, fmt.Errorf("UDP target connection failed: %w", err)
	}
	var local net.PacketConn
	var port int
	for candidate := startPort; candidate < startPort+1000; candidate++ {
		local, err = net.ListenPacket("udp", net.JoinHostPort("127.0.0.1", strconv.Itoa(candidate)))
		if err == nil {
			port = candidate
			break
		}
	}
	if local == nil {
		_ = remote.Close()
		return 0, fmt.Errorf("no loopback UDP port available: %w", err)
	}
	p.packets = append(p.packets, local)
	p.remotes = append(p.remotes, remote)
	go p.forwardUDP(local, remote)
	return port, nil
}

func (p *Proxy) forwardUDP(local net.PacketConn, remote net.Conn) {
	var peerMu sync.RWMutex
	var peer net.Addr
	go func() {
		buffer := make([]byte, 64*1024)
		for {
			count, address, err := local.ReadFrom(buffer)
			if err != nil {
				return
			}
			peerMu.Lock()
			peer = address
			peerMu.Unlock()
			if _, err = remote.Write(buffer[:count]); err != nil {
				return
			}
		}
	}()
	buffer := make([]byte, 64*1024)
	for {
		count, err := remote.Read(buffer)
		if err != nil {
			return
		}
		peerMu.RLock()
		address := peer
		peerMu.RUnlock()
		if address != nil {
			if _, err = local.WriteTo(buffer[:count], address); err != nil {
				return
			}
		}
	}
}

func (p *Proxy) accept(listener net.Listener, dial func() (net.Conn, error)) {
	for {
		local, err := listener.Accept()
		if err != nil {
			return
		}
		go p.forward(local, dial)
	}
}

func (p *Proxy) forward(local net.Conn, dial func() (net.Conn, error)) {
	defer local.Close()
	remote, err := dial()
	if err != nil {
		return
	}
	defer remote.Close()
	done := make(chan struct{}, 2)
	copyOne := func(dst, src net.Conn) {
		_, _ = io.Copy(dst, src)
		if closer, ok := dst.(interface{ CloseWrite() error }); ok {
			_ = closer.CloseWrite()
		}
		done <- struct{}{}
	}
	go copyOne(remote, local)
	go copyOne(local, remote)
	<-done
}

func (p *Proxy) Stop() {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, listener := range p.listeners {
		_ = listener.Close()
	}
	p.listeners = nil
	for _, packet := range p.packets {
		_ = packet.Close()
	}
	p.packets = nil
	for _, remote := range p.remotes {
		_ = remote.Close()
	}
	p.remotes = nil
	if p.cancel != nil {
		p.cancel()
	}
	if p.server != nil {
		_ = p.server.Close()
	}
	p.server = nil
	p.cancel = nil
	p.ctx = nil
}
