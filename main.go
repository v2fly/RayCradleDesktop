package main

import (
	"context"
	cryptoRand "crypto/rand"
	"encoding/hex"
	"fmt"
	"html"
	"log"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/wailsapp/wails/v3/pkg/application"
	"github.com/wailsapp/wails/v3/pkg/events"
)

const appName = "RayCradleDesktop"

const (
	webUIReadyTimeout = 15 * time.Second
	webUIProbeEvery   = 250 * time.Millisecond
	webUILoadParam    = "raycradle_load"
)

type desktopApp struct {
	app    *application.App
	window application.Window
	tray   *application.SystemTray
	pm     *ProcessManager

	quitting atomic.Bool
	statusMu sync.Mutex
	status   string
}

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	configureWebKitEnvironment()

	desktop := &desktopApp{}
	pm, err := NewProcessManager(WithExitHandler(desktop.onV2RayExit))
	if err != nil {
		return err
	}
	desktop.pm = pm

	app := application.New(application.Options{
		Name:        appName,
		Description: "Desktop wrapper for the adjacent V2Ray web UI",
		OnShutdown: func() {
			desktop.quitting.Store(true)
			_ = pm.Stop(3*time.Second, true)
		},
	})
	desktop.app = app

	desktop.window = app.Window.NewWithOptions(application.WebviewWindowOptions{
		Name:      "raycradle-web-ui",
		Title:     appName,
		Width:     1180,
		Height:    760,
		MinWidth:  720,
		MinHeight: 520,
	})
	desktop.window.RegisterHook(events.Common.WindowClosing, func(event *application.WindowEvent) {
		if desktop.quitting.Load() {
			return
		}
		event.Cancel()
		desktop.window.Hide()
	})

	desktop.setupTray()

	desktop.loadInitialWebUI()
	desktop.window.Show()
	return app.Run()
}

func (d *desktopApp) loadInitialWebUI() {
	if err := d.pm.Start(); err != nil {
		d.setStatus(fmt.Sprintf("V2Ray failed to start: %v", err))
		d.showStatusPage("V2Ray failed to start", err.Error())
		return
	}

	d.setStatus("V2Ray running; waiting for Web UI")
	ctx, cancel := context.WithTimeout(context.Background(), webUIReadyTimeout)
	defer cancel()
	if err := d.waitForManagedWebUI(ctx); err != nil {
		d.setStatus(fmt.Sprintf("V2Ray started, but Web UI is not ready: %v", err))
		d.showStatusPage("Web UI is not ready", err.Error())
		return
	}

	d.setStatus("V2Ray running")
	d.reloadWebUI()
}

func (d *desktopApp) setupTray() {
	d.tray = d.app.SystemTray.New()
	d.tray.SetLabel(appName)
	d.tray.SetTooltip(appName)

	menu := d.app.NewMenu()
	menu.Add("Open Web UI").OnClick(func(ctx *application.Context) {
		d.showWindow()
	})
	menu.Add("Restart V2Ray").OnClick(func(ctx *application.Context) {
		d.restartV2Ray()
	})
	menu.AddSeparator()
	menu.Add("Quit").OnClick(func(ctx *application.Context) {
		d.quit()
	})
	d.tray.SetMenu(menu)
}

func (d *desktopApp) restartV2Ray() {
	d.setStatus("Restarting V2Ray")
	if err := d.pm.Restart(); err != nil {
		d.setStatus(fmt.Sprintf("V2Ray restart failed: %v", err))
		return
	}

	d.setStatus("V2Ray running; waiting for Web UI")
	ctx, cancel := context.WithTimeout(context.Background(), webUIReadyTimeout)
	defer cancel()
	if err := d.waitForManagedWebUI(ctx); err != nil {
		d.setStatus(fmt.Sprintf("V2Ray restarted, but Web UI is not ready: %v", err))
		return
	}

	d.setStatus("V2Ray running")
	d.reloadWebUI()
}

func (d *desktopApp) showWindow() {
	if d.window == nil {
		return
	}
	d.window.SetURL(randomizedWebUIURL())
	d.window.Show()
	d.window.Restore()
	d.window.Focus()
	go func() {
		time.Sleep(150 * time.Millisecond)
		if d.quitting.Load() {
			return
		}
		d.window.Show()
		d.window.Restore()
		d.window.Focus()
	}()
}

func (d *desktopApp) reloadWebUI() {
	if d.window == nil || d.quitting.Load() {
		return
	}
	d.window.SetURL(randomizedWebUIURL())
}

func randomizedWebUIURL() string {
	parsed, err := url.Parse(v2rayURL)
	if err != nil {
		return fmt.Sprintf("%s?%s=%s", v2rayURL, webUILoadParam, randomToken())
	}
	query := parsed.Query()
	query.Set(webUILoadParam, randomToken())
	parsed.RawQuery = query.Encode()
	return parsed.String()
}

func randomToken() string {
	var token [16]byte
	if _, err := cryptoRand.Read(token[:]); err == nil {
		return hex.EncodeToString(token[:])
	}
	return fmt.Sprintf("%d", time.Now().UnixNano())
}

func (d *desktopApp) quit() {
	if d.quitting.Swap(true) {
		return
	}
	d.setStatus("Quitting")
	_ = d.pm.Stop(3*time.Second, true)
	d.app.Quit()
}

func (d *desktopApp) onV2RayExit(status ProcessExitStatus) {
	if status.Expected || d.quitting.Load() {
		return
	}

	message := fmt.Sprintf("V2Ray exited: %v", status.Err)
	if status.CrashLogPath != "" {
		message = fmt.Sprintf("%s; recent output written to %s", message, status.CrashLogPath)
	}
	d.setStatus(message)
	d.showStatusPage("V2Ray exited", message)
}

func (d *desktopApp) setStatus(status string) {
	d.statusMu.Lock()
	d.status = status
	d.statusMu.Unlock()

	title := appName
	if status != "" && status != "V2Ray running" {
		title = appName + " - " + status
	}
	if d.window != nil {
		d.window.SetTitle(title)
	}
	if d.tray != nil {
		d.tray.SetLabel(appName)
		if status == "" || status == "V2Ray running" {
			d.tray.SetTooltip(appName)
		} else {
			d.tray.SetTooltip(appName + ": " + status)
		}
	}
}

func (d *desktopApp) showStatusPage(title, detail string) {
	if d.window == nil || d.quitting.Load() {
		return
	}
	d.window.SetHTML(statusPageHTML(title, detail))
}

func statusPageHTML(title, detail string) string {
	safeTitle := html.EscapeString(title)
	safeDetail := html.EscapeString(detail)
	return fmt.Sprintf(`<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
html, body {
	margin: 0;
	min-height: 100%%;
	background: #f6f7f9;
	color: #1f2933;
	font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
body {
	display: grid;
	place-items: center;
}
main {
	width: min(680px, calc(100%% - 48px));
}
h1 {
	margin: 0 0 12px;
	font-size: 24px;
	font-weight: 650;
	letter-spacing: 0;
}
p {
	margin: 0;
	color: #52616f;
	font-size: 14px;
	line-height: 1.55;
	white-space: pre-wrap;
	word-break: break-word;
}
</style>
</head>
<body>
<main>
<h1>%s</h1>
<p>%s</p>
</main>
</body>
</html>`, safeTitle, safeDetail)
}

func (d *desktopApp) waitForManagedWebUI(ctx context.Context) error {
	client := &http.Client{
		Timeout: 2 * time.Second,
	}
	ticker := time.NewTicker(webUIProbeEvery)
	defer ticker.Stop()

	var lastErr error
	for {
		if err := d.v2rayExitedBeforeWebUIReady(); err != nil {
			return err
		}

		ready, err := probeWebUI(ctx, client, v2rayURL)
		if ready {
			return nil
		}
		if err != nil {
			lastErr = err
		}

		if err := d.v2rayExitedBeforeWebUIReady(); err != nil {
			return err
		}

		select {
		case <-ctx.Done():
			if lastErr != nil {
				return lastErr
			}
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

func (d *desktopApp) v2rayExitedBeforeWebUIReady() error {
	if d.pm == nil || d.pm.Running() {
		return nil
	}
	if err := d.pm.LastExitError(); err != nil {
		return fmt.Errorf("v2ray exited before Web UI was ready: %w", err)
	}
	return fmt.Errorf("v2ray exited before Web UI was ready")
}

func waitForWebUI(ctx context.Context, url string) error {
	client := &http.Client{
		Timeout: 2 * time.Second,
	}
	ticker := time.NewTicker(webUIProbeEvery)
	defer ticker.Stop()

	var lastErr error
	for {
		ready, err := probeWebUI(ctx, client, url)
		if ready {
			return nil
		}
		if err != nil {
			lastErr = err
		}

		select {
		case <-ctx.Done():
			if lastErr != nil {
				return lastErr
			}
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

func probeWebUI(ctx context.Context, client *http.Client, url string) (bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return false, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()

	body := make([]byte, 64*1024)
	n, _ := resp.Body.Read(body)
	content := string(body[:n])

	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		return false, fmt.Errorf("web ui returned %s", resp.Status)
	}
	if strings.TrimSpace(content) == "" {
		return false, fmt.Errorf("web ui returned an empty response")
	}
	if strings.Contains(content, "Missing index.html") {
		return false, fmt.Errorf("web ui returned missing index.html page")
	}
	return true, nil
}
