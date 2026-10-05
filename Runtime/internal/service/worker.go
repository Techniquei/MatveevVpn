package service

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

var ErrWorker=errors.New("worker_failed")
type WorkerReply struct { Version int `json:"version"`; ID string `json:"id"`; Success bool `json:"success"`; Running bool `json:"running"`; Core string `json:"core"`; Error string `json:"error,omitempty"` }
type workerRequest struct{ Version int `json:"version"`;ID string `json:"id"`;Action string `json:"action"`;Config json.RawMessage `json:"config,omitempty"`;FakeDNSDirectory string `json:"fakeDNSDirectory,omitempty"` }
type Worker struct {command *exec.Cmd; input io.WriteCloser; scanner *bufio.Scanner; finished chan struct{};mu sync.Mutex;once sync.Once;sequence uint64; directory string}
type identity struct { PID int `json:"pid"`; StartSeconds int64 `json:"startSeconds"`; StartMicroseconds int64 `json:"startMicroseconds"`; BinaryHash string `json:"binaryHash"` }

func LaunchWorker(binary,assets,directory string)(*Worker,error){
	cmd:=exec.Command(binary)
	cmd.Env=[]string{"PATH=/usr/bin:/bin","XRAY_LOCATION_ASSET="+assets}
	cmd.SysProcAttr=&syscall.SysProcAttr{Setpgid:true}
	input,err:=cmd.StdinPipe();if err!=nil{return nil,ErrWorker}
	output,err:=cmd.StdoutPipe();if err!=nil{input.Close();return nil,ErrWorker}
	// Protocol stdout is bounded; native diagnostics cannot leak configuration.
	cmd.Stderr=io.Discard
	if err=cmd.Start();err!=nil{input.Close();return nil,ErrWorker}
	w:=&Worker{command:cmd,input:input,scanner:bufio.NewScanner(output),finished:make(chan struct{}),directory:directory}
	w.scanner.Buffer(make([]byte,4096),1<<20)
	go func(){_ = cmd.Wait();close(w.finished)}()
	if directory!="" {id,err:=processIdentity(cmd.Process.Pid,binary);if err!=nil{w.Close();return nil,ErrWorker};data,_:=json.Marshal(id);if atomicPrivateWrite(filepath.Join(directory,"worker.json"),data)!=nil{w.Close();return nil,ErrWorker}}
	return w,nil
}
func(w *Worker) Call(ctx context.Context,action string,config []byte,table string)(WorkerReply,error){
	w.mu.Lock();defer w.mu.Unlock();w.sequence++
	id:=time.Now().Format("150405.000000000")
	request:=workerRequest{Version:1,ID:id,Action:action,Config:config,FakeDNSDirectory:table}
	data,err:=json.Marshal(request);if err!=nil || len(data)>1<<20{return WorkerReply{},ErrWorker}
	result:=make(chan struct{reply WorkerReply;err error},1)
	go func(){
		var reply WorkerReply
		_,err:=w.input.Write(append(data,'\n'))
		if err==nil {if !w.scanner.Scan(){err=ErrWorker}else{err=strictJSON(w.scanner.Bytes(),&reply)}}
		if err==nil && (reply.Version!=1 || reply.ID!=id || !reply.Success){err=ErrWorker}
		result<-struct{reply WorkerReply;err error}{reply,err}
	}()
	select{case value:=<-result:return value.reply,value.err;case <-ctx.Done():_ = w.command.Process.Kill();return WorkerReply{},ctx.Err();case <-w.finished:return WorkerReply{},ErrWorker}
}
func(w *Worker) Done()<-chan struct{}{return w.finished}
func (w *Worker) Close() error {
	var err error
	w.once.Do(func() {
		_ = w.input.Close()
		_ = w.command.Process.Signal(syscall.SIGTERM)
		select {
		case <-w.finished:
		case <-time.After(5 * time.Second):
			_ = w.command.Process.Kill()
			<-w.finished
			err = ErrWorker
		}
		if w.directory != "" {
			if removeErr := os.Remove(filepath.Join(w.directory, "worker.json")); removeErr != nil && !os.IsNotExist(removeErr) && err == nil {
				err = ErrWorker
			}
		}
	})
	return err
}
func ValidateWorker(ctx context.Context,binary,assets,table string,config []byte)error{w,err:=LaunchWorker(binary,assets,"");if err!=nil{return err};defer w.Close();_,err=w.Call(ctx,"validate",config,table);return err}

func processIdentity(pid int,binary string)(identity,error){
	info,err:=unix.SysctlKinfoProc("kern.proc.pid",pid);if err!=nil || int(info.Proc.P_pid)!=pid{return identity{},ErrWorker}
	data,err:=os.ReadFile(binary);if err!=nil{return identity{},ErrWorker}
	return identity{PID:pid,StartSeconds:info.Proc.P_starttime.Sec,StartMicroseconds:int64(info.Proc.P_starttime.Usec),BinaryHash:hash(data)},nil
}
// The start identity prevents killing an unrelated process that reused its PID.
func ReapWorker(directory,binary string)error{
	path:=filepath.Join(directory,"worker.json");data,err:=readPrivate(path,4096);if os.IsNotExist(err){return nil};if err!=nil{return ErrWorker}
	var recorded identity;if strictJSON(data,&recorded)!=nil || recorded.PID<2 || !digestPattern.MatchString(recorded.BinaryHash){return ErrWorker}
	current,err:=processIdentity(recorded.PID,binary)
	if err==nil && current==recorded {
		_ = syscall.Kill(recorded.PID,syscall.SIGTERM)
		deadline:=time.Now().Add(5*time.Second)
		for time.Now().Before(deadline){info,e:=unix.SysctlKinfoProc("kern.proc.pid",recorded.PID);if e!=nil || int(info.Proc.P_pid)!=recorded.PID || info.Proc.P_starttime.Sec!=recorded.StartSeconds || int64(info.Proc.P_starttime.Usec)!=recorded.StartMicroseconds{break};time.Sleep(20*time.Millisecond)}
		info,e:=unix.SysctlKinfoProc("kern.proc.pid",recorded.PID);if e==nil && info.Proc.P_starttime.Sec==recorded.StartSeconds && int64(info.Proc.P_starttime.Usec)==recorded.StartMicroseconds{_ = syscall.Kill(recorded.PID,syscall.SIGKILL)}
	}
	return os.Remove(path)
}
