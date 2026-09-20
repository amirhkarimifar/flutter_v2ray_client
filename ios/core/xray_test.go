package xray

import (
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"runtime/debug"
	"strings"
	"sync"
	"testing"
	"time"
)

// These run on any platform with a Go toolchain — no Xcode, no device. They
// cover the half of "does the VPN work" that is not iOS-specific: parsing a
// config, starting the core, and actually moving bytes through it.
//
// The instance is process-global, so tests must not run in parallel.

// freePort asks the kernel for a port and hands it straight back, which is the
// only reliable way to pick one that is not in use.
func freePort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("could not reserve a port: %v", err)
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port
}

// minimalConfig is the smallest thing that still resembles what the plugin
// generates: a local SOCKS inbound plus a direct outbound.
func minimalConfig(socksPort int) []byte {
	return []byte(fmt.Sprintf(`{
	  "log": {"loglevel": "warning"},
	  "inbounds": [{
	    "tag": "in_proxy",
	    "port": %d,
	    "protocol": "socks",
	    "listen": "127.0.0.1",
	    "settings": {"auth": "noauth", "udp": true}
	  }],
	  "outbounds": [{"tag": "direct", "protocol": "freedom"}]
	}`, socksPort))
}

func stopQuietly(t *testing.T) {
	t.Helper()
	if err := Stop(); err != nil {
		t.Fatalf("Stop: %v", err)
	}
}

func TestVersionIsReported(t *testing.T) {
	if Version() == "" {
		t.Fatal("Version returned an empty string")
	}
	t.Logf("xray-core %s", Version())
}

func TestStartRejectsBadInput(t *testing.T) {
	cases := map[string][]byte{
		"empty":        nil,
		"not json":     []byte("this is not a config"),
		"empty object": []byte(`{}`),
	}

	for name, config := range cases {
		t.Run(name, func(t *testing.T) {
			err := Start(config, nil)
			if err == nil {
				stopQuietly(t)
				t.Fatal("expected an error, got none")
			}
			// A rejected Start must leave nothing running, or the next Start
			// fails with "already running" for no visible reason.
			if IsRunning() {
				stopQuietly(t)
				t.Fatal("instance is running after a failed Start")
			}
		})
	}
}

func TestStartStopLifecycle(t *testing.T) {
	config := minimalConfig(freePort(t))

	if IsRunning() {
		t.Fatal("something was already running before the test")
	}
	if err := Start(config, nil); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if !IsRunning() {
		t.Fatal("IsRunning is false after a successful Start")
	}

	// Starting twice must fail rather than silently orphan the first instance.
	if err := Start(config, nil); err == nil {
		t.Fatal("a second Start was allowed")
	}
	if !IsRunning() {
		t.Fatal("the running instance was disturbed by the rejected Start")
	}

	stopQuietly(t)
	if IsRunning() {
		t.Fatal("IsRunning is true after Stop")
	}

	// stopTunnel calls this unconditionally, so it has to tolerate it.
	if err := Stop(); err != nil {
		t.Fatalf("Stop on an idle core: %v", err)
	}
}

// The real test: bytes through the core. A local HTTP server stands in for the
// internet, so this needs no network access.
func TestTrafficFlowsThroughTheCore(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	config := minimalConfig(freePort(t))

	delay, err := MeasureOutboundDelay(config, server.URL, 5000)
	if err != nil {
		t.Fatalf("MeasureOutboundDelay: %v", err)
	}
	if delay < 0 {
		t.Fatalf("negative delay: %d", delay)
	}
	if delay > 5000 {
		t.Fatalf("delay of %dms exceeds the timeout", delay)
	}
	t.Logf("round trip through the core: %dms", delay)

	// The throwaway instance must be gone afterwards, or the extension leaks
	// one instance per server the user tests.
	if IsRunning() {
		stopQuietly(t)
		t.Fatal("MeasureOutboundDelay left an instance running")
	}
}

func TestMeasureOutboundDelayReportsUnreachable(t *testing.T) {
	// Nothing is listening here: the reserved port was released immediately.
	unreachable := fmt.Sprintf("http://127.0.0.1:%d/", freePort(t))

	delay, err := MeasureOutboundDelay(minimalConfig(freePort(t)), unreachable, 2000)
	if err == nil {
		t.Fatal("expected an error for an unreachable host")
	}
	if delay != -1 {
		t.Fatalf("expected -1 on failure, got %d", delay)
	}
}

func TestMeasureDelayNeedsARunningInstance(t *testing.T) {
	if IsRunning() {
		stopQuietly(t)
	}

	delay, err := MeasureDelay("http://127.0.0.1/", 1000)
	if err == nil {
		t.Fatal("expected an error while not running")
	}
	if delay != -1 {
		t.Fatalf("expected -1, got %d", delay)
	}
	// The app distinguishes "not connected" from "unreachable" on this wording.
	if !strings.Contains(err.Error(), "not running") {
		t.Fatalf("unhelpful error for the disconnected case: %v", err)
	}
}

func TestMeasureDelayThroughRunningInstance(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	if err := Start(minimalConfig(freePort(t)), nil); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer stopQuietly(t)

	delay, err := MeasureDelay(server.URL, 5000)
	if err != nil {
		t.Fatalf("MeasureDelay: %v", err)
	}
	if delay < 0 {
		t.Fatalf("negative delay: %d", delay)
	}
}

// recordingLogger collects what the core writes, for the log pump test.
type recordingLogger struct {
	mu    sync.Mutex
	lines []string
}

func (r *recordingLogger) LogInput(line string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lines = append(r.lines, line)
}

func (r *recordingLogger) snapshot() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.lines...)
}

// The pump redirects the process's standard streams, so it has to put them back
// on Stop. If it does not, the second run writes into a pipe with no reader and
// eventually blocks — which in the extension looks like a tunnel that hangs
// after being toggled a few times.
func TestLogPumpForwardsAndRestores(t *testing.T) {
	before := os.Stdout

	logger := &recordingLogger{}
	if err := Start(minimalConfig(freePort(t)), logger); err != nil {
		t.Fatalf("Start: %v", err)
	}

	// Written to the redirected stream, so it travels the same path as the
	// core's own output.
	fmt.Println("flutter_v2ray_client log pump probe")

	deadline := time.Now().Add(3 * time.Second)
	var seen bool
	for time.Now().Before(deadline) {
		for _, line := range logger.snapshot() {
			if strings.Contains(line, "log pump probe") {
				seen = true
				break
			}
		}
		if seen {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	stopQuietly(t)

	if !seen {
		t.Fatal("the logger never received the line written to stdout")
	}
	if os.Stdout != before {
		t.Fatal("stdout was not restored to the stream Start replaced")
	}

	// Writing now must not block or panic.
	fmt.Println("stdout is usable again")

	// A second cycle must work, which is what the extension does on reconnect.
	second := &recordingLogger{}
	if err := Start(minimalConfig(freePort(t)), second); err != nil {
		t.Fatalf("second Start: %v", err)
	}
	stopQuietly(t)
}

func TestSetMemoryLimit(t *testing.T) {
	original := debug.SetMemoryLimit(-1)
	t.Cleanup(func() {
		debug.SetMemoryLimit(original)
		debug.SetGCPercent(100)
	})

	SetMemoryLimit(45)
	if got := debug.SetMemoryLimit(-1); got != 45*1024*1024 {
		t.Fatalf("expected a 45 MiB limit, got %d bytes", got)
	}

	// Zero means "use the default sized for the packet tunnel", not "no limit".
	SetMemoryLimit(0)
	if got := debug.SetMemoryLimit(-1); got != defaultMemoryLimitMB*1024*1024 {
		t.Fatalf("expected the %d MiB default, got %d bytes", defaultMemoryLimitMB, got)
	}
}
