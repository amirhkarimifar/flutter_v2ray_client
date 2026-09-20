// Package xray exposes a small, gomobile-friendly surface over Xray-core for use
// from Swift inside a NEPacketTunnelProvider.
//
// Only types gomobile can bridge appear in exported signatures: string, bool,
// int, int64, []byte, error and interfaces declared in this package. Exported
// functions returning (T, error) surface in Swift as throwing functions.
//
// The generated framework is named Xray, so Swift sees XrayStart, XrayStop,
// XrayVersion, XrayLogger, and so on.
package xray

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf/serial"

	// Registers every protocol, transport and app that Xray-core ships with.
	_ "github.com/xtls/xray-core/main/distro/all"
)

// Logger receives Xray-core's console output, one line per call. Implemented on
// the Swift side so the packet tunnel can forward logs to the host app.
type Logger interface {
	LogInput(line string)
}

// defaultMemoryLimitMB leaves headroom under the 50 MiB jetsam cap that iOS 15+
// applies to a packet tunnel provider (15 MiB on iOS 14 and earlier).
const defaultMemoryLimitMB = 45

// gcInterval forces unused pages back to the OS. Go's collector is too relaxed
// for the extension's budget on its own.
const gcInterval = time.Second

var (
	mu       sync.Mutex
	instance *core.Instance
	stopGC   chan struct{}
	logStop  chan struct{}

	// Saved so the standard streams can be put back when the pump stops.
	// Without this a second Start writes into a pipe nobody reads any more,
	// and the process blocks once its buffer fills.
	realStdout *os.File
	realStderr *os.File
	logWriter  *os.File
)

// Version reports the Xray-core version this framework was built against.
func Version() string {
	return core.Version()
}

// IsRunning reports whether an Xray instance is currently started.
func IsRunning() bool {
	mu.Lock()
	defer mu.Unlock()
	return instance != nil
}

// SetMemoryLimit caps the Go heap and tightens the collector. Call it before
// Start. A megabytes value of zero or less applies a default sized for the
// packet tunnel's jetsam budget.
func SetMemoryLimit(megabytes int) {
	if megabytes <= 0 {
		megabytes = defaultMemoryLimitMB
	}
	debug.SetGCPercent(10)
	debug.SetMemoryLimit(int64(megabytes) * 1024 * 1024)
}

// SetAssetPath points Xray-core at a directory holding geoip.dat / geosite.dat.
// Leave it unset unless a config actually references geo data: loading those
// files inside the packet tunnel is the most common way to hit the memory cap.
func SetAssetPath(path string) error {
	if err := os.Setenv("XRAY_LOCATION_ASSET", path); err != nil {
		return err
	}
	return os.Setenv("XRAY_LOCATION_CONFIG", path)
}

// Start builds an Xray instance from a JSON config and starts it. Any console
// output is forwarded to logger, which may be nil.
//
// Calling Start while an instance is running returns an error; call Stop first.
func Start(configJSON []byte, logger Logger) error {
	mu.Lock()
	defer mu.Unlock()

	if instance != nil {
		return errors.New("xray: already running")
	}
	if len(configJSON) == 0 {
		return errors.New("xray: empty configuration")
	}

	// Redirect the standard streams before the instance captures them, so the
	// console writer lands in the Swift logger. Done by hand rather than
	// through xray-core's log handler registry, which moves between releases;
	// stdout redirection behaves the same across versions.
	if logger != nil {
		startLogPump(logger)
	}

	config, err := serial.LoadJSONConfig(strings.NewReader(string(configJSON)))
	if err != nil {
		stopLogPump()
		return fmt.Errorf("xray: invalid configuration: %w", err)
	}

	inst, err := core.New(config)
	if err != nil {
		stopLogPump()
		return fmt.Errorf("xray: cannot create instance: %w", err)
	}
	if err := inst.Start(); err != nil {
		_ = inst.Close()
		stopLogPump()
		return fmt.Errorf("xray: cannot start instance: %w", err)
	}

	instance = inst
	startGC()
	return nil
}

// Stop shuts the running instance down. Stopping when nothing runs is a no-op,
// so it is safe to call from stopTunnel unconditionally.
func Stop() error {
	mu.Lock()
	defer mu.Unlock()

	stopGCLocked()
	stopLogPump()

	if instance == nil {
		return nil
	}
	err := instance.Close()
	instance = nil
	if err != nil {
		return fmt.Errorf("xray: cannot stop instance: %w", err)
	}
	return nil
}

// MeasureDelay times an HTTP GET to url through the running instance and
// returns the round trip in milliseconds. It reports an error when no instance
// is running, so the caller can tell "not connected" from "unreachable".
func MeasureDelay(url string, timeoutMillis int) (int64, error) {
	mu.Lock()
	inst := instance
	mu.Unlock()

	if inst == nil {
		return -1, errors.New("xray: not running")
	}
	return measure(inst, url, timeout(timeoutMillis))
}

// MeasureOutboundDelay starts a throwaway instance from configJSON, times an
// HTTP GET to url through it, and tears it down. Use it to test a server the
// app is not currently connected to; it runs happily in the host app process
// because it needs no tunnel.
func MeasureOutboundDelay(configJSON []byte, url string, timeoutMillis int) (int64, error) {
	if len(configJSON) == 0 {
		return -1, errors.New("xray: empty configuration")
	}

	config, err := serial.LoadJSONConfig(strings.NewReader(string(configJSON)))
	if err != nil {
		return -1, fmt.Errorf("xray: invalid configuration: %w", err)
	}

	inst, err := core.New(config)
	if err != nil {
		return -1, fmt.Errorf("xray: cannot create instance: %w", err)
	}
	if err := inst.Start(); err != nil {
		_ = inst.Close()
		return -1, fmt.Errorf("xray: cannot start instance: %w", err)
	}
	defer func() {
		_ = inst.Close()
	}()

	return measure(inst, url, timeout(timeoutMillis))
}

func timeout(millis int) time.Duration {
	if millis <= 0 {
		return 10 * time.Second
	}
	return time.Duration(millis) * time.Millisecond
}

// measure dials through the given instance rather than the system stack, so the
// figure reflects the proxy path and not the device's direct route.
func measure(inst *core.Instance, url string, limit time.Duration) (int64, error) {
	ctx, cancel := context.WithTimeout(context.Background(), limit)
	defer cancel()

	client := &http.Client{
		Timeout: limit,
		Transport: &http.Transport{
			DisableKeepAlives: true,
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				dest, err := xnet.ParseDestination(network + ":" + addr)
				if err != nil {
					return nil, err
				}
				return core.Dial(ctx, inst, dest)
			},
		},
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return -1, err
	}

	started := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return -1, err
	}
	defer resp.Body.Close()
	// Drain a little so the round trip covers the response, not just headers.
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1024))

	return time.Since(started).Milliseconds(), nil
}

func startGC() {
	stopGC = make(chan struct{})
	done := stopGC
	go func() {
		ticker := time.NewTicker(gcInterval)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				debug.FreeOSMemory()
			}
		}
	}()
}

func stopGCLocked() {
	if stopGC != nil {
		close(stopGC)
		stopGC = nil
	}
}

func startLogPump(logger Logger) {
	if logStop != nil {
		// Already pumping; a second pipe would orphan the first.
		return
	}

	reader, writer, err := os.Pipe()
	if err != nil {
		return
	}

	realStdout, realStderr = os.Stdout, os.Stderr
	os.Stdout, os.Stderr = writer, writer
	logWriter = writer

	logStop = make(chan struct{})
	go func() {
		defer reader.Close()
		scanner := bufio.NewScanner(reader)
		// Xray can emit long lines; a cap keeps a malformed stream from growing
		// without bound inside the extension's memory budget.
		scanner.Buffer(make([]byte, 0, 4096), 64*1024)
		// Ends when the writer is closed by stopLogPump.
		for scanner.Scan() {
			logger.LogInput(scanner.Text())
		}
	}()
}

func stopLogPump() {
	if logStop == nil {
		return
	}
	close(logStop)
	logStop = nil

	// Restore before closing, so nothing writes into a closed pipe.
	if realStdout != nil {
		os.Stdout, realStdout = realStdout, nil
	}
	if realStderr != nil {
		os.Stderr, realStderr = realStderr, nil
	}
	if logWriter != nil {
		// Closing gives the scanner EOF, which ends the goroutine.
		_ = logWriter.Close()
		logWriter = nil
	}
}
