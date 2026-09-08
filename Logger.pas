unit Logger;

interface

uses SysUtils;

procedure WriteLog(const Msg: string);

implementation

// central log procedure
procedure WriteLog(const Msg: string);
var
  F: TextFile;
begin
  try
    // target file
    AssignFile(F, 'C:\a2hook\debug.txt');
    if FileExists('C:\a2hook\debug.txt') then
      Append(F)
    else
      Rewrite(F);
    // formatting
    Writeln(F, FormatDateTime('yyyy-mm-dd hh:nn', Now) + ' - ' + Msg);
    // closing
    CloseFile(F);
  except
  end;
end;

end.
