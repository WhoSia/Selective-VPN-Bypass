package main

import (
 "encoding/base64"
 "encoding/binary"
 "errors"
 "flag"
 "fmt"
 "os"
 "os/exec"
 "path/filepath"
 "regexp"
 "strings"
 "unicode/utf16"
)

// The elevated worker reads trusted PowerShell source directly from the Go
// executable's embed.FS. It never executes a user-writable runtime-v4 *.ps1.
const workerBootstrap = "$ErrorActionPreference='Stop'; [Console]::InputEncoding=[Text.UTF8Encoding]::new($false); [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $OutputEncoding=[Text.UTF8Encoding]::new($false); $s=[Console]::In.ReadToEnd(); & ([ScriptBlock]::Create($s))"

var workerLogName=regexp.MustCompile(`^svb-[0-9a-f]{32}\.log$`)

func psLiteral(value string) string {
 return "'" + strings.ReplaceAll(value,"'","''") + "'"
}

func utf16EncodedCommand(s string) string {
 units:=utf16.Encode([]rune(s))
 data:=make([]byte,len(units)*2)
 for i,u:=range units {binary.LittleEndian.PutUint16(data[i*2:],u)}
 return base64.StdEncoding.EncodeToString(data)
}

func validateWorkerArguments(executable,action,configDir,logPath string) error {
 if action!="apply" && action!="restore" {return errors.New("privileged helper permits only apply or restore")}
 if !filepath.IsAbs(configDir) || !filepath.IsAbs(logPath) {return errors.New("absolute config and log paths are required")}
 if !strings.EqualFold(filepath.Clean(configDir),filepath.Clean(filepath.Dir(executable))) {
  return errors.New("config folder must match the portable executable folder")
 }
 if !workerLogName.MatchString(filepath.Base(logPath)) {return errors.New("invalid worker log name")}
 // The privileged helper may create only a fresh log directly in its
 // configured temporary directory; a caller must not supply a protected path.
 if !strings.EqualFold(filepath.Clean(filepath.Dir(logPath)),filepath.Clean(os.TempDir())) {
  return errors.New("worker log must reside directly in the process temporary directory")
 }
 return nil
}

// Reject obvious filesystem redirection before crossing the elevation
// boundary. This is a fail-closed *preflight*, not a handle-bound ACL proof:
// an attacker can still race path replacement, and hardlinks need separate
// Windows file-ID validation before a privileged journal can be trusted.
func validatePortableFileBoundary(dir string) error {
 // Inspect each ancestor as well as the final Portable folder. A junction
 // above the folder must not hide behind a perfectly regular final directory.
 // This is still path-based preflight, not a handle-bound identity guarantee.
 current:=filepath.Clean(dir)
 for {
  info,err:=os.Lstat(current)
  if err!=nil{return fmt.Errorf("cannot inspect portable folder ancestor: %w",err)}
  if !info.IsDir() || info.Mode()&os.ModeSymlink!=0 {
   return errors.New("portable folder path contains a redirected or non-directory component; refusing elevated operation")
  }
  parent:=filepath.Dir(current)
  if parent==current {break}
  current=parent
 }
 for _,name:=range []string{"Selective-VPN-Bypass.domains.json","Selective-VPN-Bypass_v3.state.json"} {
  path:=filepath.Join(dir,name)
  stat,err:=os.Lstat(path)
  if errors.Is(err,os.ErrNotExist){continue}
  if err!=nil{return fmt.Errorf("cannot inspect portable data file %s: %w",name,err)}
  if !stat.Mode().IsRegular() || stat.Mode()&os.ModeSymlink!=0 {
   return fmt.Errorf("portable data file %s is redirected or not a regular file",name)
  }
 }
 return nil
}

func embeddedCoreWrapper(core []byte,action,dir string) string {
 encoded:=base64.StdEncoding.EncodeToString(core)
 return "$ErrorActionPreference='Stop'\n"+
  "$core=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"+encoded+"'))\n"+
  "try {\n"+
  " & ([ScriptBlock]::Create($core)) -Action "+psLiteral(action)+" -ConfigDir "+psLiteral(dir)+" *>&1 | Out-String -Width 200 | Write-Output\n"+
  " exit 0\n"+
  "} catch {\n"+
  " $_ | Out-String -Width 200 | Write-Output\n"+
  " exit 1\n"+
  "}\n"
}

func openNewWorkerLog(path string) (*os.File,error) {
 // No truncation and no following a pre-existing file or symlink.
 return os.OpenFile(path,os.O_WRONLY|os.O_CREATE|os.O_EXCL,0600)
}

func runEmbeddedWorker(args []string) error {
 fs:=flag.NewFlagSet("embedded-worker",flag.ContinueOnError)
 fs.SetOutput(os.Stderr)
 action:=fs.String("Action","","only apply or restore")
 dir:=fs.String("ConfigDir","","configuration folder")
 logPath:=fs.String("LogPath","","worker log")
 if err:=fs.Parse(args);err!=nil{return err}
 if fs.NArg()!=0 {return errors.New("unexpected worker arguments")}
 exe,err:=os.Executable();if err!=nil{return err}
 if err=validateWorkerArguments(exe,*action,*dir,*logPath);err!=nil{return err}
 if err=validatePortableFileBoundary(*dir);err!=nil{return err}
 core,err:=scripts.ReadFile("src/Core.ps1");if err!=nil{return err}
 root:=os.Getenv("SystemRoot")
 if root==""{return errors.New("Windows system root unavailable")}
 powershell:=filepath.Join(root,"System32","WindowsPowerShell","v1.0","powershell.exe")
 // A short trusted bootstrap reads the full embedded script from stdin; no
 // high-privilege script is loaded from a writable file or placed in argv.
 cmd:=exec.Command(powershell,"-NoLogo","-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-EncodedCommand",utf16EncodedCommand(workerBootstrap))
 // O_EXCL refuses existing files, including pre-planted links. Keep the
 // handle open across child execution so privileged PowerShell never resolves
 // or writes the caller-controlled pathname itself.
 log,err:=openNewWorkerLog(*logPath)
 if err!=nil{return fmt.Errorf("cannot create a fresh worker log: %w",err)}
 defer log.Close()
 cmd.Stdin=strings.NewReader(embeddedCoreWrapper(core,*action,*dir))
 cmd.Stdout=log
 cmd.Stderr=log
 if err=cmd.Run();err!=nil{
  _,_=fmt.Fprintf(log,"Privileged worker failed: %v\n",err)
 }
 return err
}
