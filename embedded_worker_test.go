package main

import (
 "os"
 "os/exec"
 "path/filepath"
 "strings"
 "testing"
)

func TestWorkerArgumentBoundary(t *testing.T) {
 exe:=filepath.Join(t.TempDir(),"SelectiveVPNBypass_GUI.exe")
 dir:=filepath.Dir(exe)
 log:=filepath.Join(os.TempDir(),"svb-0123456789abcdef0123456789abcdef.log")
 if err:=validateWorkerArguments(exe,"apply",dir,log);err!=nil{t.Fatal(err)}
 if err:=validateWorkerArguments(exe,"restore",dir,log);err!=nil{t.Fatal(err)}
 cases:=[]struct{action,config,log string}{
  {"add",dir,log},
  {"status",dir,log},
  {"apply",filepath.Join(dir,"other"),log},
  {"apply",dir,filepath.Join(t.TempDir(),"different.log")},
  {"apply",dir,filepath.Join(t.TempDir(),"svb-0123456789abcdef0123456789abcdef.log")},
 }
 for _,c:=range cases {
  if err:=validateWorkerArguments(exe,c.action,c.config,c.log);err==nil{
   t.Errorf("accepted untrusted worker arguments: action=%s",c.action)
  }
 }
}

func TestElevatedPortableFileBoundary(t *testing.T) {
 dir:=t.TempDir()
 if err:=validatePortableFileBoundary(dir);err!=nil{t.Fatal(err)}
 config:=filepath.Join(dir,"Selective-VPN-Bypass.domains.json")
 if err:=os.WriteFile(config,[]byte("{\"domains\":[]}"),0600);err!=nil{t.Fatal(err)}
 if err:=validatePortableFileBoundary(dir);err!=nil{t.Fatal(err)}
 if err:=os.Remove(config);err!=nil{t.Fatal(err)}
 if err:=os.Mkdir(config,0700);err!=nil{t.Fatal(err)}
 if err:=validatePortableFileBoundary(dir);err==nil{
  t.Fatal("accepted a directory in place of a Portable configuration file")
 }
 if err:=os.Remove(config);err!=nil{t.Fatal(err)}
 journal:=filepath.Join(dir,"Selective-VPN-Bypass_v3.state.json")
 if err:=os.Mkdir(journal,0700);err!=nil{t.Fatal(err)}
 if err:=validatePortableFileBoundary(dir);err==nil{
  t.Fatal("accepted a directory in place of recovery journal")
 }
 if err:=os.Remove(journal);err!=nil{t.Fatal(err)}
 // Creating symbolic links can require developer mode on Windows. Where
 // supported, verify the elevated worker explicitly rejects a redirected file.
 target:=filepath.Join(t.TempDir(),"target.json")
 if err:=os.WriteFile(target,[]byte("preserve"),0600);err!=nil{t.Fatal(err)}
 if err:=os.Symlink(target,config);err==nil{
  if err:=validatePortableFileBoundary(dir);err==nil{
   t.Fatal("accepted redirected configuration file")
  }
  if err:=os.Remove(config);err!=nil{t.Fatal(err)}
 }
 if err:=validatePortableFileBoundary(dir);err!=nil{t.Fatal(err)}
 // A normal final folder nested under a redirected ancestor is also unsafe.
 // Windows without symlink privileges skips only this optional creation.
 realParent:=filepath.Join(t.TempDir(),"real-parent")
 if err:=os.Mkdir(realParent,0700);err!=nil{t.Fatal(err)}
 normalChild:=filepath.Join(realParent,"portable")
 if err:=os.Mkdir(normalChild,0700);err!=nil{t.Fatal(err)}
 linkedParent:=filepath.Join(t.TempDir(),"linked-parent")
 if err:=os.Symlink(realParent,linkedParent);err==nil{
  if err:=validatePortableFileBoundary(filepath.Join(linkedParent,"portable"));err==nil{
   t.Fatal("accepted a regular Portable folder through a redirected ancestor")
  }
  if err:=os.Remove(linkedParent);err!=nil{t.Fatal(err)}
 }
 if err:=validatePortableFileBoundary(normalChild);err!=nil{t.Fatal(err)}
}

func TestWorkerLogExclusive(t *testing.T) {
 dir:=t.TempDir()
 path:=filepath.Join(dir,"svb-test.log")
 original:=[]byte("keep existing log contents")
 if err:=os.WriteFile(path,original,0600);err!=nil{t.Fatal(err)}
 if file,err:=openNewWorkerLog(path);err==nil{
  _=file.Close()
  t.Fatal("helper was allowed to truncate an existing log")
 }
 after,err:=os.ReadFile(path)
 if err!=nil{t.Fatal(err)}
 if string(after)!=string(original){t.Fatal("existing worker log was changed")}
 fresh:=filepath.Join(dir,"svb-new.log")
 file,err:=openNewWorkerLog(fresh)
 if err!=nil{t.Fatal(err)}
 if _,err=file.WriteString("only new output");err!=nil{t.Fatal(err)}
 if err=file.Close();err!=nil{t.Fatal(err)}
 if raw,err:=os.ReadFile(fresh);err!=nil || string(raw)!="only new output"{
  t.Fatalf("exclusive log output missing or damaged: %v",err)
 }
}

func TestPowerShellSingleQuoteEscaping(t *testing.T){
 got:=psLiteral("a'b")
 if got!="'a''b'"{t.Fatalf("unexpected quote encoding: %s",got)}
}

// Runs the same stdin bootstrap as the embedded elevated helper but invokes
// the read-only list action in an isolated folder: no network privileges.
func TestEmbeddedWorkerUnicodeLog(t *testing.T){
 temp:=t.TempDir()
 logPath:=filepath.Join(temp,"svb-unicode.log")
 file,err:=openNewWorkerLog(logPath)
 if err!=nil{t.Fatal(err)}
 script:=[]byte("param([string]$Action,[string]$ConfigDir)\nWrite-Output '진단 완료: 연결 정상'\n")
 p:=filepath.Join(os.Getenv("SystemRoot"),"System32","WindowsPowerShell","v1.0","powershell.exe")
 cmd:=exec.Command(p,"-NoLogo","-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-EncodedCommand",utf16EncodedCommand(workerBootstrap))
 cmd.Stdin=strings.NewReader(embeddedCoreWrapper(script,"list",temp))
 cmd.Stdout=file
 cmd.Stderr=file
 err=cmd.Run()
 _=file.Close()
 if err!=nil{raw,_:=os.ReadFile(logPath);t.Fatalf("unicode worker failed: %v: %s",err,raw)}
 raw,err:=os.ReadFile(logPath)
 if err!=nil{t.Fatal(err)}
 if !strings.Contains(string(raw),"진단 완료: 연결 정상"){
  t.Fatalf("worker log did not preserve UTF-8 output: %q",raw)
 }
}

func TestEmbeddedPowerShellBootstrapList(t *testing.T){
 core,err:=scripts.ReadFile("src/Core.ps1");if err!=nil{t.Fatal(err)}
 tmp:=t.TempDir()
 log:=filepath.Join(tmp,"svb-0123456789abcdef0123456789abcdef.log")
 p:=filepath.Join(os.Getenv("SystemRoot"),"System32","WindowsPowerShell","v1.0","powershell.exe")
 cmd:=exec.Command(p,"-NoLogo","-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-EncodedCommand",utf16EncodedCommand(workerBootstrap))
 cmd.Stdin=strings.NewReader(embeddedCoreWrapper(core,"list",tmp))
 outFile,err:=os.OpenFile(log,os.O_WRONLY|os.O_CREATE|os.O_EXCL,0600)
 if err!=nil{t.Fatal(err)}
 cmd.Stdout=outFile
 cmd.Stderr=outFile
 err=cmd.Run()
 _=outFile.Close()
 if err!=nil{output,_:=os.ReadFile(log);t.Fatalf("embedded list failed: %v output=%s",err,output)}
 if _,err:=os.Stat(log);err!=nil{t.Fatalf("embedded worker failed to write log: %v",err)}
}
