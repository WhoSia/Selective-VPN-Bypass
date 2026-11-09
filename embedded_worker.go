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
 return nil
}

func embeddedCoreWrapper(core []byte,action,dir,logPath string) string {
 encoded:=base64.StdEncoding.EncodeToString(core)
 return "$ErrorActionPreference='Stop'\n"+
  "$core=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"+encoded+"'))\n"+
  "try {\n"+
  " & ([ScriptBlock]::Create($core)) -Action "+psLiteral(action)+" -ConfigDir "+psLiteral(dir)+" *>&1 | Out-String -Width 200 | Set-Content -LiteralPath "+psLiteral(logPath)+" -Encoding UTF8\n"+
  " exit 0\n"+
  "} catch {\n"+
  " $_ | Out-String -Width 200 | Add-Content -LiteralPath "+psLiteral(logPath)+" -Encoding UTF8\n"+
  " exit 1\n"+
  "}\n"
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
 core,err:=scripts.ReadFile("src/Core.ps1");if err!=nil{return err}
 root:=os.Getenv("SystemRoot")
 if root==""{return errors.New("Windows system root unavailable")}
 powershell:=filepath.Join(root,"System32","WindowsPowerShell","v1.0","powershell.exe")
 // A short trusted bootstrap reads the full embedded script from stdin; no
 // high-privilege script is loaded from a writable file or placed in argv.
 bootstrap:="$ErrorActionPreference='Stop'; [Console]::InputEncoding=[Text.UTF8Encoding]::new($false); $s=[Console]::In.ReadToEnd(); & ([ScriptBlock]::Create($s))"
 cmd:=exec.Command(powershell,"-NoLogo","-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-EncodedCommand",utf16EncodedCommand(bootstrap))
 cmd.Stdin=strings.NewReader(embeddedCoreWrapper(core,*action,*dir,*logPath))
 output,err:=cmd.CombinedOutput()
 if err!=nil {
  // The PowerShell wrapper normally writes structured errors to the log.
  if _,statErr:=os.Stat(*logPath);statErr!=nil {
   _=os.WriteFile(*logPath,[]byte(fmt.Sprintf("Privileged worker execution failed: %v\n%s",err,output)),0600)
  }
 }
 return err
}
