package main

import (
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestBuildV2RayCommand(t *testing.T) {
	dir := filepath.Join(string(filepath.Separator), "opt", "raycradle")
	spec := buildV2RayCommand(dir)

	if spec.Path != filepath.Join(dir, "v2ray") {
		t.Fatalf("path = %q, want adjacent v2ray path", spec.Path)
	}
	if !reflect.DeepEqual(spec.Args, []string{"run", "-format", "jsonv5", "-c", "config.json"}) {
		t.Fatalf("args = %#v", spec.Args)
	}
	if spec.Dir != dir {
		t.Fatalf("dir = %q, want %q", spec.Dir, dir)
	}
}

func TestStopSafeWhenNoProcessRunning(t *testing.T) {
	pm, err := NewProcessManager(WithExecutableDir(t.TempDir()))
	if err != nil {
		t.Fatal(err)
	}
	if err := pm.Stop(10*time.Millisecond, true); err != nil {
		t.Fatalf("Stop returned error: %v", err)
	}
}

func TestExpectedProcessExitDoesNotWriteCrashLog(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script process fixture is unix-only")
	}

	dir := t.TempDir()
	writeFakeV2Ray(t, dir, "#!/bin/sh\nsleep 5\n")

	pm, err := NewProcessManager(WithExecutableDir(dir))
	if err != nil {
		t.Fatal(err)
	}
	if err := pm.Start(); err != nil {
		t.Fatalf("Start returned error: %v", err)
	}
	if err := pm.Stop(500*time.Millisecond, true); err != nil {
		t.Fatalf("Stop returned error: %v", err)
	}
	if pm.Running() {
		t.Fatal("process is still marked running")
	}
	if _, err := os.Stat(filepath.Join(dir, crashLogFileName)); !os.IsNotExist(err) {
		t.Fatalf("expected no crash log, stat err = %v", err)
	}
}

func TestUnexpectedProcessExitWritesRecentOutput(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script process fixture is unix-only")
	}

	dir := t.TempDir()
	writeFakeV2Ray(t, dir, "#!/bin/sh\nprintf 'old-output\\n'\nsleep 0.3\nprintf 'recent-output\\n'\nexit 7\n")

	pm, err := NewProcessManager(
		WithExecutableDir(dir),
		WithOutputRetention(120*time.Millisecond),
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := pm.Start(); err != nil {
		t.Fatalf("Start returned error: %v", err)
	}
	waitForStopped(t, pm, 2*time.Second)

	path := filepath.Join(dir, crashLogFileName)
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read crash log: %v", err)
	}
	logText := string(content)
	if strings.Contains(logText, "old-output") {
		t.Fatalf("crash log contains pruned output: %q", logText)
	}
	if !strings.Contains(logText, "recent-output") {
		t.Fatalf("crash log missing recent output: %q", logText)
	}
	if pm.LastCrashLogPath() != path {
		t.Fatalf("LastCrashLogPath = %q, want %q", pm.LastCrashLogPath(), path)
	}
	if pm.LastExitError() == nil {
		t.Fatal("LastExitError is nil")
	}
}

func TestRecentOutputBufferPrunesOldOutput(t *testing.T) {
	now := time.Date(2026, 6, 8, 12, 0, 0, 0, time.UTC)
	buffer := NewRecentOutputBuffer(8*time.Second, func() time.Time {
		return now
	})

	buffer.Write("stdout", []byte("old\n"))
	now = now.Add(9 * time.Second)
	buffer.Write("stderr", []byte("recent\n"))

	snapshot := buffer.Snapshot()
	if strings.Contains(snapshot, "old") {
		t.Fatalf("snapshot contains old output: %q", snapshot)
	}
	if !strings.Contains(snapshot, "recent") {
		t.Fatalf("snapshot missing recent output: %q", snapshot)
	}
	if !strings.Contains(snapshot, "[stderr]") {
		t.Fatalf("snapshot missing stream tag: %q", snapshot)
	}
}

func writeFakeV2Ray(t *testing.T, dir, script string) {
	t.Helper()
	path := filepath.Join(dir, "v2ray")
	if err := os.WriteFile(path, []byte(script), 0755); err != nil {
		t.Fatalf("write fake v2ray: %v", err)
	}
}

func waitForStopped(t *testing.T, pm *ProcessManager, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if !pm.Running() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("timed out waiting for process to stop")
}
