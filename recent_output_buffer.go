package main

import (
	"fmt"
	"strings"
	"sync"
	"time"
)

type outputEntry struct {
	at     time.Time
	stream string
	text   string
}

type RecentOutputBuffer struct {
	mu        sync.Mutex
	retention time.Duration
	now       func() time.Time
	entries   []outputEntry
}

func NewRecentOutputBuffer(retention time.Duration, now func() time.Time) *RecentOutputBuffer {
	if retention <= 0 {
		retention = 8 * time.Second
	}
	if now == nil {
		now = time.Now
	}
	return &RecentOutputBuffer{
		retention: retention,
		now:       now,
	}
}

func (b *RecentOutputBuffer) Write(stream string, p []byte) {
	if len(p) == 0 {
		return
	}

	b.mu.Lock()
	defer b.mu.Unlock()

	now := b.now()
	b.entries = append(b.entries, outputEntry{
		at:     now,
		stream: stream,
		text:   string(p),
	})
	b.pruneLocked(now)
}

func (b *RecentOutputBuffer) Snapshot() string {
	b.mu.Lock()
	defer b.mu.Unlock()

	now := b.now()
	b.pruneLocked(now)

	var out strings.Builder
	for _, entry := range b.entries {
		text := strings.TrimRight(entry.text, "\n")
		if text == "" {
			continue
		}
		for _, line := range strings.Split(text, "\n") {
			fmt.Fprintf(&out, "%s [%s] %s\n", entry.at.Format(time.RFC3339Nano), entry.stream, line)
		}
	}
	return out.String()
}

func (b *RecentOutputBuffer) Clear() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.entries = nil
}

func (b *RecentOutputBuffer) pruneLocked(now time.Time) {
	cutoff := now.Add(-b.retention)
	first := 0
	for first < len(b.entries) && b.entries[first].at.Before(cutoff) {
		first++
	}
	if first > 0 {
		copy(b.entries, b.entries[first:])
		b.entries = b.entries[:len(b.entries)-first]
	}
}
