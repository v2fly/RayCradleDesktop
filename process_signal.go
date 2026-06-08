package main

import (
	"os"
)

func signalProcessForStop(process *os.Process) error {
	return process.Signal(os.Interrupt)
}
