{
        File: uPacker.pas
        License: GPLv2
        This unit is a part of Free Manga Downloader
}

unit uPacker;

{$mode delphi}

interface

uses
  Classes, Zipper, zstream, SysUtils, uBaseUnit, Img2Pdf, FileUtil,
  LazFileUtils, SimpleException, uEpub, FMDOptions, process, MultiLog;

type
  TPackerFormat = (pfZIP, pfCBZ, pfPDF, pfEPUB);

  { TPacker }

  TPacker = class
  protected
    FSavedFileName, FExt: String;
    FFileList: TStringList;
    procedure FileFound(FileIterator: TFileIterator);
    function DoZipCbz: Boolean;
    function Do7Zip: Boolean;
    function DoPdf: Boolean;
    function DoEpub: Boolean;
    procedure DeletePartialFile;
  public
    Path,
    FileName: String;
    Format: TPackerFormat;
    CompressionQuality: Cardinal;
    function Execute: Boolean;
    property FileList: TStringList read FFileList;
    property SavedFileName: String read FSavedFileName;
    property Ext: String read FExt;
  public
    constructor Create;
    destructor Destroy; override;
  end;

implementation

uses
  frmMain;

// Zipper only auto-prefixes in its TFileStream (> MAX_PATH); its FindFirst doesn't, and
// "Enable long name paths" may be off. So prefix here.
function ToLongPath(const S: String): String;
begin
  Result := S;
  {$IFDEF WINDOWS}
  if (Length(S) < MAX_PATHDIR) or (Pos('\\?\', S) = 1) then
  begin
    Exit;
  end;

  if Pos('\\', S) = 1 then
  begin
    Result := '\\?\UNC\' + Copy(S, 3, MaxInt);
  end
  else if (Length(S) > 2) and (S[2] = ':') and (S[3] = '\') then
  begin
    Result := '\\?\' + S;
  end;
  {$ENDIF}
end;

procedure TPacker.FileFound(FileIterator: TFileIterator);
begin
  FFileList.Add(FileIterator.Filename);
end;

// A failed pack can leave a truncated archive; Execute treats an existing file as success and
// deletes the source images, so it must not survive.
procedure TPacker.DeletePartialFile;
begin
  if FileExists(FSavedFileName) and not DeleteFile(FSavedFileName) then
  begin
    Logger.SendError(Self.ClassName + '.DeletePartialFile Error: failed to delete ' + FSavedFileName);
  end;
end;

function TPacker.DoZipCbz: Boolean;
var
  i: Integer;
begin
  Result := False;

  with TZipper.Create do
  begin
    try
      try
        FileName := FSavedFileName;
        // Entries above InMemSize (default 256 KB) go through "<archive name>00000.tmp", which
        // overflows NTFS's 255-char name limit for long titles (\\?\ doesn't lift it). Stored
        // entries (clnone) cost one image of memory each, so keep them all in memory.
        InMemSize := High(Int64);
        for i := 0 to FFileList.Count - 1 do
        begin
          with Entries.AddFileEntry(FFileList[i]) do
          begin
            CompressionLevel := clnone;
            ArchiveFileName := ExtractFileName(FFileList[i]);
          end;
        end;

        ZipAllFiles;
        Result := True;
      except
        on E: Exception do
        begin
          E.Message := 'DoZipCbz.Exception'#13#10 + E.Message;
          SimpleException.ExceptionHandleSaveLogOnly(Self, E);
        end;
      end;
    finally
      Free;
    end;
  end;

  // After Free, so the zipper's output stream is closed and the file can be deleted.
  if not Result then
  begin
    DeletePartialFile;
  end;
end;

Function MaybeQuoteIfNotQuoted(Const S : TProcessString) : TProcessString;

begin
  If (Pos(' ', S) <> 0) and (pos('"', S) = 0) then
  begin
    Result := '"' + S + '"';
  end
  else
  begin
     Result := S;
  end;
end;

function TPacker.Do7Zip: Boolean;
var
  p: TProcess;
  exit_status, i: Integer;
  s, sout, serr, fFileName: String;
begin
  Result := False;
  p := TProcess.Create(nil);
  try
    if FileExists(FSavedFileName) then
    begin
      if not DeleteFile(FSavedFileName) then
      begin
        Logger.SendError(Self.ClassName + '.Do7Zip Error: failed to delete existing file ' + FSavedFileName);
        Exit;
      end;
    end;

    fFileName := CreateFQDNList(Self, FSavedFileName, FFileList);

    p.Executable := CURRENT_ZIP_EXE;
    with p.Parameters do begin
      Add('a');
      Add('-tzip');
      Add('-mx0');
      Add('-mmt' + IntToStr(CPUCount));
      Add('-sccUTF-8');
      Add('-scsUTF-8');
      Add('-stl');
      Add('-spd');
      Add('-slt');
      Add('-sse');
      Add('-sdel');
      Add(FSavedFileName);
      Add('@' + fFileName);
    end;

    sout := '';
    serr := '';
    p.ShowWindow := swoHIDE;
    p.RunCommandLoop(sout, serr, exit_status);
    Result := exit_status = 0;

    if FileExists(fFileName) then
    begin
      DeleteFile(fFileName);
    end;

    if not Result then
    begin
      serr := '';
      s := IntToStr(exit_status) + ' ';
      case exit_status of
        1: s += 'Warning';
        2: s += 'Fatal error';
        7: s += 'Command line error';
        8: s += 'Not enough memory operation';
        255: s += 'User stopped the process';
        else
          s := 'Unknown';
      end;

      s += ' ' + MaybeQuoteIfNotQuoted(p.Executable);
      for i := 0 to p.Parameters.Count-1 do
      begin
        s += ' ' + MaybeQuoteIfNotQuoted(p.Parameters[i]);
      end;

      Logger.SendError(Self.ClassName + '.Do7zip Error: ' + s);
    end;
  finally
    p.Free;
  end;
end;

function TPacker.DoPdf: Boolean;
var
  pdf: TImg2Pdf;
  i: Cardinal;
  fstream: TFileStream;
begin
  Result := False;
  try
    pdf := TImg2Pdf.Create;
    try
      pdf.CompressionQuality := CompressionQuality;
      pdf.Infos.Title := GetLastDir(Path);
      pdf.Infos.Creator := ApplicationName;

      for i := 0 to FFileList.Count - 1 do
      begin
        try
          pdf.AddImage(FFileList[i]);
        except
        end;
      end;

      fstream := TFileStream.Create(FSavedFileName, fmCreate);
      try
        pdf.SaveToStream(fstream);
      finally
        fstream.Free;
      end;
      Result := True;
    finally
      pdf.Free;
    end;
  except
    on E: Exception do
    begin
      E.Message := 'DoPdf.Exception'#13#10 + E.Message;
      SimpleException.ExceptionHandleSaveLogOnly(Self, E);
    end;
  end;

  if not Result then
  begin
    DeletePartialFile;
  end;
end;

function TPacker.DoEpub: Boolean;
var
  epub: TEpubBuilder;
  i: Integer;
  fstream: TFileStream;
begin
  Result := False;
  try
    epub := TEpubBuilder.Create;
    try
      epub.Title := GetLastDir(Path);

      for i := 0 to FFileList.Count - 1 do
      begin
        try
          epub.AddImage(FFileList[i]);
        except
        end;
      end;

      fstream := TFileStream.Create(FSavedFileName, fmCreate);
      try
        epub.SaveToStream(fstream);
      finally
        fstream.Free;
      end;
      Result := True;
    finally
      epub.Free;
    end;
  except
    on E: Exception do
    begin
      E.Message := 'DoEpub.Exception'#13#10 + E.Message;
      SimpleException.ExceptionHandleSaveLogOnly(Self, E);
    end;
  end;

  if not Result then
  begin
    DeletePartialFile;
  end;
end;

function TPacker.Execute: Boolean;
var
  i: Integer;
  packResult: Boolean;
begin
  Result := False;
  Path := CorrectPathSys(Path);

  if FFileList.Count = 0 then
  begin
    if not DirectoryExists(Path) then
    begin
      Exit;
    end;

    with TFileSearcher.Create do
      try
        OnFileFound := FileFound;
        Search(Self.Path, '*.jpg;*.png;*.gif;*.webp', False, False);
      finally
        Free;
      end;
  end;

  Path := ToLongPath(Path);
  for i := 0 to FFileList.Count - 1 do
  begin
    FFileList[i] := ToLongPath(FFileList[i]);
  end;

  FFileList.CustomSort(NaturalCustomSort);
  case Format of
    pfZIP: FExt := '.zip';
    pfCBZ: FExt := '.cbz';
    pfPDF: FExt := '.pdf';
    pfEPUB: FExt := '.epub';
  end;

  // New tasks get names cut by FitChapterName where the task is built; don't cut here, or lookups
  // by name in uFavoritesManager/frmMain miss the archive. Tasks saved before that keep long names,
  // and "<name><ext>" over NTFS's 255-char limit fails here safely (images kept, task failed).
  if FileName <> '' then
  begin
    FSavedFileName := FileName + FExt;
  end
  else
  begin
    FSavedFileName := TrimAndExpandFilename(Path) + FExt;
  end;
  FSavedFileName := ToLongPath(FSavedFileName);

  if FFileList.Count = 0 then
  begin
    if FileExists(FSavedFileName) then
    begin
      Exit(True);
    end;

    Exit;
  end;

  if FileExists(FSavedFileName) then
  begin
    if not DeleteFile(FSavedFileName) then
    begin
      Exit;
    end;
  end;

  packResult:=True;
  case Format of
    pfZIP, pfCBZ: packResult:=DoZipCbz;
    pfPDF: packResult:=DoPdf;
    pfEPUB: packResult:=DoEpub;
  end;

  if not packResult then
  begin
    Exit(False);
  end;

  Result := FileExists(FSavedFileName);
  if Result then
  begin
    for i := 0 to FFileList.Count - 1 do
    begin
      DeleteFile(FFileList[i]);
    end;

    if IsDirectoryEmpty(Path) then
    begin
      RemoveDir(Path);
    end;
  end;
end;

constructor TPacker.Create;
begin
  FFileList := TStringList.Create;
  FSavedFileName := '';
  FExt := '';
  Path := '';
  FileName := '';
  Format := pfZIP;
end;

destructor TPacker.Destroy;
begin
  FFileList.Free;
  inherited Destroy;
end;

end.
