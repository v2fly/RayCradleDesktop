package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
)

const (
	v2rayURL         = "http://127.0.0.1:19829/"
	crashLogFileName = "raycradle-v2ray-crash.log"
	outputRetention  = 8 * time.Second
)

var v2rayArgs = []string{"run", "-format", "jsonv5", "-c", "config.json"}

type commandSpec struct {
	Path string
	Args []string
	Dir  string
}

type ProcessExitStatus struct {
	Err          error
	Expected     bool
	CrashLogPath string
}

type managedProcess struct {
	cmd    *exec.Cmd
	buffer *RecentOutputBuffer
	done   chan struct{}
}

type ProcessManager struct {
	mu               sync.Mutex
	executableDir    string
	retention        time.Duration
	now              func() time.Time
	cmdFactory       func(commandSpec) *exec.Cmd
	process          *managedProcess
	expectedExit     bool
	lastExitError    error
	lastCrashLogPath string
	onExit           func(ProcessExitStatus)
}

type ProcessManagerOption func(*ProcessManager)

func NewProcessManager(options ...ProcessManagerOption) (*ProcessManager, error) {
	executableDir, err := currentExecutableDir()
	if err != nil {
		return nil, err
	}

	pm := &ProcessManager{
		executableDir: executableDir,
		retention:     outputRetention,
		now:           time.Now,
	}
	pm.cmdFactory = func(spec commandSpec) *exec.Cmd {
		cmd := exec.Command(spec.Path, spec.Args...)
		cmd.Dir = spec.Dir
		return cmd
	}

	for _, option := range options {
		option(pm)
	}
	if pm.retention <= 0 {
		pm.retention = outputRetention
	}
	if pm.now == nil {
		pm.now = time.Now
	}
	if pm.cmdFactory == nil {
		pm.cmdFactory = func(spec commandSpec) *exec.Cmd {
			cmd := exec.Command(spec.Path, spec.Args...)
			cmd.Dir = spec.Dir
			return cmd
		}
	}

	return pm, nil
}

func WithExecutableDir(dir string) ProcessManagerOption {
	return func(pm *ProcessManager) {
		pm.executableDir = dir
	}
}

func WithOutputRetention(retention time.Duration) ProcessManagerOption {
	return func(pm *ProcessManager) {
		pm.retention = retention
	}
}

func WithClock(now func() time.Time) ProcessManagerOption {
	return func(pm *ProcessManager) {
		pm.now = now
	}
}

func WithExitHandler(handler func(ProcessExitStatus)) ProcessManagerOption {
	return func(pm *ProcessManager) {
		pm.onExit = handler
	}
}

func buildV2RayCommand(execDir string) commandSpec {
	return commandSpec{
		Path: filepath.Join(execDir, "v2ray"),
		Args: append([]string(nil), v2rayArgs...),
		Dir:  execDir,
	}
}

func currentExecutableDir() (string, error) {
	if appImage := os.Getenv("APPIMAGE"); appImage != "" {
		return executablePathDir(appImage)
	}

	executable, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("resolve executable path: %w", err)
	}
	return executablePathDir(executable)
}

func executablePathDir(path string) (string, error) {
	if !filepath.IsAbs(path) {
		absolute, err := filepath.Abs(path)
		if err != nil {
			return "", fmt.Errorf("resolve executable directory: %w", err)
		}
		path = absolute
	}
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		path = resolved
	}
	return filepath.Dir(path), nil
}

func (pm *ProcessManager) Start() error {
	pm.mu.Lock()
	if pm.process != nil {
		pm.mu.Unlock()
		return nil
	}

	spec := buildV2RayCommand(pm.executableDir)
	cmd := pm.cmdFactory(spec)
	buffer := NewRecentOutputBuffer(pm.retention, pm.now)
	proc := &managedProcess{
		cmd:    cmd,
		buffer: buffer,
		done:   make(chan struct{}),
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		pm.mu.Unlock()
		return fmt.Errorf("capture v2ray stdout: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		pm.mu.Unlock()
		return fmt.Errorf("capture v2ray stderr: %w", err)
	}

	pm.lastExitError = nil
	pm.lastCrashLogPath = ""
	pm.expectedExit = false
	pm.mu.Unlock()

	if err := cmd.Start(); err != nil {
		pm.mu.Lock()
		pm.lastExitError = err
		pm.mu.Unlock()
		return fmt.Errorf("start v2ray: %w", err)
	}

	var copyWG sync.WaitGroup
	copyWG.Add(2)
	go copyProcessOutput(&copyWG, buffer, "stdout", stdout)
	go copyProcessOutput(&copyWG, buffer, "stderr", stderr)

	pm.mu.Lock()
	pm.process = proc
	pm.mu.Unlock()

	go func() {
		waitErr := cmd.Wait()
		copyWG.Wait()
		pm.handleProcessExit(proc, waitErr)
	}()

	return nil
}

func copyProcessOutput(wg *sync.WaitGroup, buffer *RecentOutputBuffer, stream string, reader io.Reader) {
	defer wg.Done()
	chunk := make([]byte, 4096)
	for {
		n, err := reader.Read(chunk)
		if n > 0 {
			buffer.Write(stream, chunk[:n])
		}
		if err != nil {
			return
		}
	}
}

func (pm *ProcessManager) Stop(timeout time.Duration, expected bool) error {
	pm.mu.Lock()
	proc := pm.process
	if proc == nil {
		pm.mu.Unlock()
		return nil
	}
	if expected {
		pm.expectedExit = true
	}
	pm.mu.Unlock()

	if proc.cmd.Process != nil {
		if err := signalProcessForStop(proc.cmd.Process); err != nil && !errors.Is(err, os.ErrProcessDone) {
			_ = proc.cmd.Process.Kill()
		}
	}

	if timeout <= 0 {
		<-proc.done
		return nil
	}

	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-proc.done:
		return nil
	case <-timer.C:
		if proc.cmd.Process == nil {
			<-proc.done
			return nil
		}
		if err := proc.cmd.Process.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) {
			return fmt.Errorf("kill v2ray after stop timeout: %w", err)
		}
		<-proc.done
		return nil
	}
}

func (pm *ProcessManager) Restart() error {
	if err := pm.Stop(3*time.Second, true); err != nil {
		return err
	}
	return pm.Start()
}

func (pm *ProcessManager) Running() bool {
	pm.mu.Lock()
	defer pm.mu.Unlock()
	return pm.process != nil
}

func (pm *ProcessManager) LastExitError() error {
	pm.mu.Lock()
	defer pm.mu.Unlock()
	return pm.lastExitError
}

func (pm *ProcessManager) LastCrashLogPath() string {
	pm.mu.Lock()
	defer pm.mu.Unlock()
	return pm.lastCrashLogPath
}

func (pm *ProcessManager) handleProcessExit(proc *managedProcess, waitErr error) {
	pm.mu.Lock()
	if pm.process != proc {
		pm.mu.Unlock()
		close(proc.done)
		return
	}

	expected := pm.expectedExit
	pm.process = nil
	pm.expectedExit = false
	pm.lastExitError = waitErr
	pm.lastCrashLogPath = ""
	pm.mu.Unlock()

	var crashLogPath string
	if expected {
		waitErr = nil
		proc.buffer.Clear()
	} else {
		if waitErr == nil {
			waitErr = errors.New("v2ray exited with status 0")
		}
		crashLogPath = filepath.Join(pm.executableDir, crashLogFileName)
		if err := os.WriteFile(crashLogPath, []byte(proc.buffer.Snapshot()), 0644); err != nil {
			waitErr = fmt.Errorf("%w; write crash log: %v", waitErr, err)
		}
	}

	pm.mu.Lock()
	pm.lastExitError = waitErr
	pm.lastCrashLogPath = crashLogPath
	handler := pm.onExit
	pm.mu.Unlock()

	close(proc.done)

	if handler != nil {
		handler(ProcessExitStatus{
			Err:          waitErr,
			Expected:     expected,
			CrashLogPath: crashLogPath,
		})
	}
}
