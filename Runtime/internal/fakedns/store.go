// Package fakedns owns stable synthetic addresses. A durable mapping is never
// reassigned, including across core restarts and disconnected sessions.
package fakedns

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"

	"golang.org/x/net/idna"
)

const (
	MaximumDomains      = 65536
	MaximumJournalBytes = 64 << 20
	maximumRecordBytes  = 1024
	journalMagic        = "MVFDNS01"
)

var Pool = netip.MustParsePrefix("198.18.0.0/15")

var (
	ErrTable   = errors.New("fake_dns_table_error")
	ErrUnknown = errors.New("fake_dns_unknown_address")
	ErrClosed  = errors.New("fake_dns_closed")
)

type mapping struct {
	Domain  string `json:"domain"`
	Address string `json:"address"`
}

type Store struct {
	mu        sync.RWMutex
	directory string
	journal   *os.File
	byDomain  map[string]netip.Addr
	byAddress map[netip.Addr]string
	size      int64
	failed    atomic.Bool
	closed    atomic.Bool
	publish   func(string, mapping) error
}

// Open preserves a damaged journal in place. The returned store exposes the
// verified prefix for reverse lookup but Err/Allocate fail closed on damage.
func Open(directory string) (*Store, error) {
	if !filepath.IsAbs(directory) || privateDirectory(directory) != nil {
		return nil, ErrTable
	}
	if privateDirectory(filepath.Join(directory, "records")) != nil {
		return nil, ErrTable
	}
	name := filepath.Join(directory, "journal")
	if info, err := os.Lstat(name); err == nil && (!info.Mode().IsRegular() || info.Mode().Perm() != 0600) {
		return nil, ErrTable
	} else if err != nil && !os.IsNotExist(err) {
		return nil, ErrTable
	}
	f, err := os.OpenFile(name, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, ErrTable
	}
	if syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		_ = f.Close()
		return nil, ErrTable
	}
	s := &Store{directory: directory, journal: f, byDomain: make(map[string]netip.Addr), byAddress: make(map[netip.Addr]string), publish: publishRecord}
	info, err := f.Stat()
	if err != nil {
		_ = s.Close()
		return nil, ErrTable
	}
	s.size = info.Size()
	if s.size == 0 {
		if _, err = f.WriteString(journalMagic); err == nil {
			err = f.Sync()
		}
		if err == nil {
			err = syncDirectory(directory)
		}
		if err != nil {
			_ = s.Close()
			return nil, ErrTable
		}
		s.size = int64(len(journalMagic))
	}
	if s.size > MaximumJournalBytes {
		s.failed.Store(true)
		return s, nil
	}
	if _, err = f.Seek(0, io.SeekStart); err != nil {
		_ = s.Close()
		return nil, ErrTable
	}
	magic := make([]byte, len(journalMagic))
	if _, err = io.ReadFull(f, magic); err != nil || string(magic) != journalMagic {
		s.failed.Store(true)
		return s, nil
	}
	for {
		record, done, err := readRecord(f)
		if done {
			break
		}
		if err != nil || len(s.byDomain) == MaximumDomains || s.accept(record) != nil {
			s.failed.Store(true)
			break
		}
		if err := s.publish(directory, record); err != nil {
			s.failed.Store(true)
			break
		}
	}
	return s, nil
}

func privateDirectory(directory string) error {
	err := os.Mkdir(directory, 0700)
	created := err == nil
	if err != nil && !os.IsExist(err) {
		return ErrTable
	}
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode().Perm() != 0700 {
		return ErrTable
	}
	if created {
		return syncDirectory(filepath.Dir(directory))
	}
	return nil
}

func normalizeDomain(domain string) (string, error) {
	domain = strings.TrimSuffix(strings.ToLower(domain), ".")
	name, err := idna.Lookup.ToASCII(domain)
	if err != nil || len(name) == 0 || len(name) > 253 {
		return "", ErrTable
	}
	for _, label := range strings.Split(name, ".") {
		if len(label) == 0 || len(label) > 63 {
			return "", ErrTable
		}
		for _, c := range label {
			if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_') {
				return "", ErrTable
			}
		}
	}
	return name, nil
}

func (s *Store) accept(record mapping) error {
	name, err := normalizeDomain(record.Domain)
	addr, parseErr := netip.ParseAddr(record.Address)
	if err != nil || parseErr != nil || name != record.Domain || !Pool.Contains(addr) || record.Address != addr.String() {
		return ErrTable
	}
	if _, ok := s.byDomain[name]; ok {
		return ErrTable
	}
	if _, ok := s.byAddress[addr]; ok {
		return ErrTable
	}
	// Requiring contiguous addresses makes the allocation high-water mark derive
	// from the durable records. A damaged tail disables allocation instead.
	if addr != addressFor(len(s.byDomain)+1) {
		return ErrTable
	}
	s.byDomain[name], s.byAddress[addr] = addr, name
	return nil
}

func addressFor(index int) netip.Addr {
	var bytes [4]byte
	binary.BigEndian.PutUint32(bytes[:], uint32(0xc6120000+index))
	return netip.AddrFrom4(bytes)
}

func (s *Store) Directory() string { return s.directory }

func (s *Store) Allocate(domain string) (netip.Addr, error) {
	name, err := normalizeDomain(domain)
	if err != nil {
		return netip.Addr{}, ErrTable
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed.Load() {
		return netip.Addr{}, ErrClosed
	}
	if s.failed.Load() {
		return netip.Addr{}, ErrTable
	}
	if addr, ok := s.byDomain[name]; ok {
		return addr, nil
	}
	if len(s.byDomain) >= MaximumDomains {
		s.failed.Store(true)
		return netip.Addr{}, ErrTable
	}
	addr := addressFor(len(s.byDomain) + 1)
	record := mapping{Domain: name, Address: addr.String()}
	encoded := encodeRecord(record)
	if s.size+int64(len(encoded)) > MaximumJournalBytes {
		s.failed.Store(true)
		return netip.Addr{}, ErrTable
	}
	// Journal fsync precedes publication; publication fsync precedes DNS answers.
	// Any failure permanently freezes this writer until a verified reopen.
	if _, err = s.journal.Write(encoded); err == nil {
		err = s.journal.Sync()
	}
	if err != nil {
		s.failed.Store(true)
		return netip.Addr{}, ErrTable
	}
	s.size += int64(len(encoded))
	if s.accept(record) != nil || s.publish(s.directory, record) != nil {
		s.failed.Store(true)
		return netip.Addr{}, ErrTable
	}
	return addr, nil
}

func (s *Store) Lookup(addr netip.Addr) (string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.closed.Load() {
		return "", ErrClosed
	}
	if domain, ok := s.byAddress[addr]; ok {
		return domain, nil
	}
	return "", ErrUnknown
}

func (s *Store) Err() error {
	// DNS deadlines and Suspend must not wait for an allocation's fsync.
	if s.closed.Load() {
		return ErrClosed
	}
	if s.failed.Load() {
		return ErrTable
	}
	return nil
}

func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed.Load() {
		return nil
	}
	s.closed.Store(true)
	return s.journal.Close()
}

func encodeRecord(record mapping) []byte {
	payload, _ := json.Marshal(record)
	checksum := sha256.Sum256(payload)
	encoded := make([]byte, 4+len(payload)+sha256.Size)
	binary.BigEndian.PutUint32(encoded, uint32(len(payload)))
	copy(encoded[4:], payload)
	copy(encoded[4+len(payload):], checksum[:])
	return encoded
}

func readRecord(reader io.Reader) (mapping, bool, error) {
	var record mapping
	var length [4]byte
	n, err := io.ReadFull(reader, length[:])
	if err == io.EOF && n == 0 {
		return record, true, nil
	}
	if err != nil {
		return record, false, ErrTable
	}
	size := binary.BigEndian.Uint32(length[:])
	if size == 0 || size > maximumRecordBytes {
		return record, false, ErrTable
	}
	payload := make([]byte, int(size))
	var checksum [sha256.Size]byte
	if _, err = io.ReadFull(reader, payload); err != nil {
		return record, false, ErrTable
	}
	if _, err = io.ReadFull(reader, checksum[:]); err != nil || sha256.Sum256(payload) != checksum {
		return record, false, ErrTable
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&record) != nil {
		return record, false, ErrTable
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return record, false, ErrTable
	}
	return record, false, nil
}

func publishRecord(directory string, record mapping) error {
	addr, err := netip.ParseAddr(record.Address)
	if err != nil {
		return ErrTable
	}
	name := filepath.Join(directory, "records", addr.String())
	if _, err = os.Lstat(name); err == nil {
		stored, err := LookupRecord(directory, addr)
		if err != nil || stored != record.Domain {
			return ErrTable
		}
		return nil
	} else if !os.IsNotExist(err) {
		return ErrTable
	}
	f, err := os.CreateTemp(filepath.Join(directory, "records"), ".publish-")
	if err != nil {
		return ErrTable
	}
	temporary := f.Name()
	defer os.Remove(temporary)
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(encodeRecord(record))
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(temporary, name)
	}
	if err == nil {
		err = syncDirectory(filepath.Join(directory, "records"))
	}
	return err
}

// LookupRecord performs fresh immutable-record reads, including previously
// unknown addresses. There is deliberately no negative cache in the worker.
func LookupRecord(directory string, addr netip.Addr) (string, error) {
	if !filepath.IsAbs(directory) {
		return "", ErrTable
	}
	if !addr.Is4() || !Pool.Contains(addr) {
		return "", ErrUnknown
	}
	for _, dir := range []string{directory, filepath.Join(directory, "records")} {
		info, err := os.Lstat(dir)
		if err != nil || !info.IsDir() || info.Mode().Perm() != 0700 {
			return "", ErrTable
		}
	}
	name := filepath.Join(directory, "records", addr.String())
	info, err := os.Lstat(name)
	if os.IsNotExist(err) {
		return "", ErrUnknown
	}
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0600 || info.Size() > maximumRecordBytes+4+sha256.Size {
		return "", ErrTable
	}
	f, err := os.OpenFile(name, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return "", ErrTable
	}
	defer f.Close()
	record, done, err := readRecord(f)
	if err != nil || done || record.Address != addr.String() {
		return "", ErrTable
	}
	var extra [1]byte
	if n, _ := f.Read(extra[:]); n != 0 {
		return "", ErrTable
	}
	name, err = normalizeDomain(record.Domain)
	if err != nil || name != record.Domain {
		return "", ErrTable
	}
	return name, nil
}

func syncDirectory(directory string) error {
	f, err := os.Open(directory)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}
