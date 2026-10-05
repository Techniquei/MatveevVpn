package service

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"

	"matveevvpn/runtime/internal/policy"
)

var ErrPersistence = errors.New("persistence_failed")
var digestPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

type Accepted struct {
	Schema int `json:"schema"`
	Revision uint64 `json:"revision"`
	SnapshotID string `json:"snapshotID"`
	PreviousSnapshotID string `json:"previousSnapshotID,omitempty"`
	DesiredOn bool `json:"desiredOn"`
	LastRequestID string `json:"lastRequestID,omitempty"`
	LastRequestPayloadHash string `json:"lastRequestPayloadHash,omitempty"`
}
type StateStore struct { Directory string; write func(string,[]byte) error }

func OpenState(directory string)(*StateStore,Accepted,*policy.Policy,error) {
	if err:=privateDirectory(directory);err!=nil { return nil,Accepted{},nil,ErrPersistence }
	if err:=privateDirectory(filepath.Join(directory,"snapshots"));err!=nil { return nil,Accepted{},nil,ErrPersistence }
	s:=&StateStore{Directory:directory,write:atomicPrivateWrite}
	a:=Accepted{Schema:1}
	data,err:=readPrivate(filepath.Join(directory,"accepted.json"),4096)
	if os.IsNotExist(err) { return s,a,nil,nil }
	if err!=nil || strictJSON(data,&a)!=nil || a.Schema!=1 || (a.SnapshotID!="" && !digestPattern.MatchString(a.SnapshotID)) || (a.PreviousSnapshotID!="" && !digestPattern.MatchString(a.PreviousSnapshotID)) { return nil,a,nil,ErrPersistence }
	if a.SnapshotID==""{if a.DesiredOn{return nil,a,nil,ErrPersistence};return s,a,nil,nil}
	data,err=s.readSnapshot(a.SnapshotID); if err!=nil { return nil,a,nil,ErrPersistence }
	var snapshot policy.Snapshot
	if strictJSON(data,&snapshot)!=nil { return nil,a,nil,ErrPersistence }
	p,err:=policy.Compile(snapshot); if err!=nil { return nil,a,nil,ErrPersistence }
	return s,a,p,nil
}

func (s *StateStore) SaveSnapshot(snapshot policy.Snapshot)(string,error) {
	data,err:=json.Marshal(snapshot);if err!=nil { return "",ErrPersistence }
	id:=hash(data)
	if err=s.write(filepath.Join(s.Directory,"snapshots",id+".json"),data);err!=nil {return "",ErrPersistence}
	return id,nil
}
func (s *StateStore) Commit(a Accepted)error {
	if a.Schema!=1 || (a.SnapshotID!="" && !digestPattern.MatchString(a.SnapshotID)) { return ErrPersistence }
	data,err:=json.Marshal(a);if err!=nil{return ErrPersistence}
	if err=s.write(filepath.Join(s.Directory,"accepted.json"),data);err!=nil{return ErrPersistence}
	return nil
}
func(s *StateStore) Prune(a Accepted)error {
	entries,err:=os.ReadDir(filepath.Join(s.Directory,"snapshots"));if err!=nil{return ErrPersistence}
	for _,entry:=range entries { name:=entry.Name(); if entry.IsDir() || name==a.SnapshotID+".json" || name==a.PreviousSnapshotID+".json" {continue}; if len(name)==69 && digestPattern.MatchString(name[:64]) {if os.Remove(filepath.Join(s.Directory,"snapshots",name))!=nil{return ErrPersistence}} }
	return nil
}
func(s *StateStore)readSnapshot(id string)([]byte,error){
	if !digestPattern.MatchString(id){return nil,ErrPersistence}
	data,err:=readPrivate(filepath.Join(s.Directory,"snapshots",id+".json"),policy.MaxSnapshotBytes)
	if err!=nil || hash(data)!=id{return nil,ErrPersistence};return data,nil
}
func hash(data []byte)string{sum:=sha256.Sum256(data);return hex.EncodeToString(sum[:])}
func strictJSON(data []byte,value any)error{
	d:=json.NewDecoder(bytes.NewReader(data));d.DisallowUnknownFields()
	if err:=d.Decode(value);err!=nil{return err}; var trailing any; if err:=d.Decode(&trailing);err!=io.EOF{return errors.New("invalid_json")};return nil
}
func privateDirectory(directory string)error{
	if err:=os.MkdirAll(directory,0700);err!=nil{return err}
	info,err:=os.Lstat(directory);if err!=nil || !info.IsDir() || info.Mode().Perm()!=0700{return ErrPersistence};return nil
}
func readPrivate(path string,limit int)([]byte,error){
	info,err:=os.Lstat(path);if err!=nil{return nil,err}
	if !info.Mode().IsRegular() || info.Mode().Perm()!=0600 || info.Size()>int64(limit){return nil,ErrPersistence}
	f,err:=os.Open(path);if err!=nil{return nil,err};defer f.Close()
	data,err:=io.ReadAll(io.LimitReader(f,int64(limit)+1));if err!=nil || len(data)>limit{return nil,ErrPersistence};return data,nil
}
func atomicPrivateWrite(path string,data []byte)error{
	if info,err:=os.Lstat(path);err==nil && (!info.Mode().IsRegular() || info.Mode().Perm()!=0600){return ErrPersistence}else if err!=nil && !os.IsNotExist(err){return err}
	f,err:=os.CreateTemp(filepath.Dir(path),".stage-");if err!=nil{return err};temp:=f.Name();defer os.Remove(temp)
	if err=f.Chmod(0600);err==nil{_,err=f.Write(data)};if err==nil{err=f.Sync()};closeErr:=f.Close();if err==nil{err=closeErr};if err!=nil{return err}
	if err=os.Rename(temp,path);err!=nil{return err};dir,err:=os.Open(filepath.Dir(path));if err!=nil{return err};defer dir.Close();return dir.Sync()
}
