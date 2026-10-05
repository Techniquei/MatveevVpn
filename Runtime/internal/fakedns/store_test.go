package fakedns

import (
	"bytes"
	"errors"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
)

func openTestStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "private"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func TestMappingDurableAcrossRestarts(t *testing.T) {
	s := openTestStore(t)
	addr, err := s.Allocate("Example.COM.")
	if err != nil {
		t.Fatal(err)
	}
	if !Pool.Contains(addr) {
		t.Fatal("address outside pool")
	}
	if domain, err := LookupRecord(s.Directory(), addr); err != nil || domain != "example.com" {
		t.Fatalf("record not published before allocation: %q %v", domain, err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := Open(s.Directory())
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	same, err := reopened.Allocate("example.com")
	if err != nil || same != addr {
		t.Fatal("mapping changed on restart")
	}
	other, err := reopened.Allocate("other.example.com")
	if err != nil || other == addr {
		t.Fatal("address reused")
	}
	for _, name := range []string{s.Directory(), filepath.Join(s.Directory(), "records")} {
		info, err := os.Stat(name)
		if err != nil || info.Mode().Perm() != 0700 {
			t.Fatal("directory not private")
		}
	}
	for _, name := range []string{filepath.Join(s.Directory(), "journal"), filepath.Join(s.Directory(), "records", addr.String())} {
		info, err := os.Stat(name)
		if err != nil || info.Mode().Perm() != 0600 {
			t.Fatal("file not private")
		}
	}
}

func TestReverseLookupDoesNotNegativelyCache(t *testing.T) {
	s := openTestStore(t)
	addr := addressFor(1)
	if _, err := LookupRecord(s.Directory(), addr); !errors.Is(err, ErrUnknown) {
		t.Fatal(err)
	}
	allocated, err := s.Allocate("late.example")
	if err != nil || allocated != addr {
		t.Fatal(err)
	}
	if name, err := LookupRecord(s.Directory(), addr); err != nil || name != "late.example" {
		t.Fatal("new mapping hidden by old miss")
	}
	if _, err := LookupRecord(s.Directory(), netip.MustParseAddr("1.1.1.1")); !errors.Is(err, ErrUnknown) {
		t.Fatal(err)
	}
}

func TestCorruptTailPreservesPrefixAndFreezesAllocation(t *testing.T) {
	for _, tail := range [][]byte{{0}, {0, 0, 0, 12, 'x'}, bytes.Repeat([]byte{255}, 32)} {
		t.Run(string(tail), func(t *testing.T) {
			s := openTestStore(t)
			addr, err := s.Allocate("before.example")
			if err != nil {
				t.Fatal(err)
			}
			_ = s.Close()
			journal := filepath.Join(s.Directory(), "journal")
			f, err := os.OpenFile(journal, os.O_APPEND|os.O_WRONLY, 0600)
			if err != nil {
				t.Fatal(err)
			}
			_, _ = f.Write(tail)
			_ = f.Close()
			before, _ := os.ReadFile(journal)
			reopened, err := Open(s.Directory())
			if err != nil {
				t.Fatal(err)
			}
			defer reopened.Close()
			if reopened.Err() == nil {
				t.Fatal("corruption was ignored")
			}
			if name, err := reopened.Lookup(addr); err != nil || name != "before.example" {
				t.Fatal("verified prefix lost")
			}
			if _, err := reopened.Allocate("after.example"); err == nil {
				t.Fatal("corrupt tail reused")
			}
			after, _ := os.ReadFile(journal)
			if !bytes.Equal(before, after) {
				t.Fatal("journal silently truncated or changed")
			}
		})
	}
}

func TestChecksumCorruptionCannotPublishMapping(t *testing.T) {
	s := openTestStore(t)
	_ = s.Close()
	record := encodeRecord(mapping{Domain: "bad.example", Address: addressFor(1).String()})
	record[len(record)-1] ^= 1
	f, _ := os.OpenFile(filepath.Join(s.Directory(), "journal"), os.O_APPEND|os.O_WRONLY, 0600)
	_, _ = f.Write(record)
	_ = f.Close()
	reopened, err := Open(s.Directory())
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if reopened.Err() == nil {
		t.Fatal("bad checksum accepted")
	}
	if _, err := LookupRecord(s.Directory(), addressFor(1)); err == nil {
		t.Fatal("bad mapping published")
	}
}

func TestPublicationFailureNeverAnswersOrReusesAddress(t *testing.T) {
	s := openTestStore(t)
	s.publish = func(string, mapping) error { return errors.New("private failure") }
	if _, err := s.Allocate("durable.example"); err == nil {
		t.Fatal("publication failure accepted")
	}
	if _, err := s.Allocate("other.example"); err == nil {
		t.Fatal("writer not frozen")
	}
	if _, err := LookupRecord(s.Directory(), addressFor(1)); err == nil {
		t.Fatal("unpublished mapping visible")
	}
	_ = s.Close()
	reopened, err := Open(s.Directory())
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	addr, err := reopened.Allocate("durable.example")
	if err != nil || addr != addressFor(1) {
		t.Fatal("durable mapping not recovered")
	}
	if name, err := LookupRecord(s.Directory(), addr); err != nil || name != "durable.example" {
		t.Fatal("derived publication not recovered")
	}
	other, err := reopened.Allocate("other.example")
	if err != nil || other != addressFor(2) {
		t.Fatal("persisted address reused")
	}
}

func TestSingleWriterAndPrivateAdmission(t *testing.T) {
	s := openTestStore(t)
	if second, err := Open(s.Directory()); err == nil {
		_ = second.Close()
		t.Fatal("second writer admitted")
	}
	addr, err := s.Allocate("private.example")
	if err != nil {
		t.Fatal(err)
	}
	name := filepath.Join(s.Directory(), "records", addr.String())
	if err := os.Chmod(name, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := LookupRecord(s.Directory(), addr); err == nil {
		t.Fatal("public mapping file accepted")
	}
	parent := t.TempDir()
	if err := os.Symlink(s.Directory(), filepath.Join(parent, "link")); err != nil {
		t.Fatal(err)
	}
	if linked, err := Open(filepath.Join(parent, "link")); err == nil {
		_ = linked.Close()
		t.Fatal("symlink store accepted")
	}
}

func TestQuotaFailsClosedWithoutFallback(t *testing.T) {
	for _, limit := range []string{"domains", "bytes"} {
		t.Run(limit, func(t *testing.T) {
			s := openTestStore(t)
			if limit == "domains" {
				for i := 0; i < MaximumDomains; i++ {
					s.byDomain[strconv.Itoa(i)] = addressFor(i + 1)
				}
			} else {
				s.size = MaximumJournalBytes
			}
			before, _ := os.ReadFile(filepath.Join(s.Directory(), "journal"))
			if _, err := s.Allocate("over.example"); err == nil || s.Err() == nil {
				t.Fatal("quota ignored")
			}
			after, _ := os.ReadFile(filepath.Join(s.Directory(), "journal"))
			if !bytes.Equal(before, after) {
				t.Fatal("quota appended a record")
			}
		})
	}
}

func TestConcurrentSameDomainHasOneAddress(t *testing.T) {
	s := openTestStore(t)
	var wg sync.WaitGroup
	addresses := make(chan netip.Addr, 24)
	for i := 0; i < cap(addresses); i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			addr, err := s.Allocate("same.example")
			if err == nil {
				addresses <- addr
			}
		}()
	}
	wg.Wait()
	close(addresses)
	count := 0
	for addr := range addresses {
		if addr != addressFor(1) {
			t.Fatal("parallel allocation diverged")
		}
		count++
	}
	if count != cap(addresses) || len(s.byDomain) != 1 {
		t.Fatal("parallel allocation lost or duplicated mappings")
	}
}
