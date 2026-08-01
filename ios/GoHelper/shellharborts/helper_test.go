package shellharborts

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"testing"
	"time"
)

func TestForwardHTTPConnect(t *testing.T) {
	target := listenTCP(t)
	defer target.Close()
	go acceptEcho(target)

	proxyListener := listenTCP(t)
	defer proxyListener.Close()
	go acceptHTTPConnect(proxyListener)

	targetHost, targetPort := splitAddress(t, target.Addr().String())
	proxyHost, proxyPort := splitAddress(t, proxyListener.Addr().String())
	helper := NewProxy()
	defer helper.Stop()
	localPort, err := helper.ForwardHTTPConnect(proxyHost, proxyPort, targetHost, targetPort, 25040)
	if err != nil {
		t.Fatal(err)
	}

	connection, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(localPort)), 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	payload := []byte("shellharbor-http-connect")
	if _, err = connection.Write(payload); err != nil {
		t.Fatal(err)
	}
	result := make([]byte, len(payload))
	if _, err = io.ReadFull(connection, result); err != nil {
		t.Fatal(err)
	}
	if string(result) != string(payload) {
		t.Fatalf("received %q, want %q", result, payload)
	}
}

func TestForwardUDP(t *testing.T) {
	target, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer target.Close()
	go func() {
		buffer := make([]byte, 2048)
		for {
			count, peer, readErr := target.ReadFrom(buffer)
			if readErr != nil {
				return
			}
			_, _ = target.WriteTo(buffer[:count], peer)
		}
	}()

	helper := NewProxy()
	defer helper.Stop()
	localPort, err := helper.listenUDPLocked(26040, func() (net.Conn, error) {
		return net.Dial("udp", target.LocalAddr().String())
	})
	if err != nil {
		t.Fatal(err)
	}
	connection, err := net.Dial("udp", net.JoinHostPort("127.0.0.1", strconv.Itoa(localPort)))
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if err = connection.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	payload := []byte("shellharbor-mosh-udp")
	if _, err = connection.Write(payload); err != nil {
		t.Fatal(err)
	}
	result := make([]byte, len(payload))
	if _, err = io.ReadFull(connection, result); err != nil {
		t.Fatal(err)
	}
	if string(result) != string(payload) {
		t.Fatalf("received %q, want %q", result, payload)
	}
}

func listenTCP(t *testing.T) net.Listener {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	return listener
}

func splitAddress(t *testing.T, address string) (string, int) {
	t.Helper()
	host, value, err := net.SplitHostPort(address)
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(value)
	if err != nil {
		t.Fatal(err)
	}
	return host, port
}

func acceptEcho(listener net.Listener) {
	for {
		connection, err := listener.Accept()
		if err != nil {
			return
		}
		go func() {
			defer connection.Close()
			_, _ = io.Copy(connection, connection)
		}()
	}
}

func acceptHTTPConnect(listener net.Listener) {
	for {
		client, err := listener.Accept()
		if err != nil {
			return
		}
		go func() {
			defer client.Close()
			reader := bufio.NewReader(client)
			request, err := http.ReadRequest(reader)
			if err != nil || request.Method != http.MethodConnect {
				return
			}
			upstream, err := net.Dial("tcp", request.Host)
			if err != nil {
				_, _ = fmt.Fprint(client, "HTTP/1.1 502 Bad Gateway\r\n\r\n")
				return
			}
			defer upstream.Close()
			_, _ = fmt.Fprint(client, "HTTP/1.1 200 Connection Established\r\n\r\n")
			go func() { _, _ = io.Copy(upstream, reader) }()
			_, _ = io.Copy(client, upstream)
		}()
	}
}
