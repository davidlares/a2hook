unit HttpClient;

interface

uses SysUtils, Classes, IdHTTP, Logger;

procedure SendEventAsync(const TableName, KeyField, KeyValue, Operation: string);
procedure SendEvent(const TableName, KeyField, KeyValue, Operation: string);
function JsonEscape(const S: string): string;

implementation

type
  TSendEventThread = class(TThread)
  private
    FTableName: string;
    FKeyField: string;
    FKeyValue: string;
    FOperation: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const TableName, KeyField, KeyValue, Operation: string);
  end;

// adding the constructor
constructor TSendEventThread.Create(const TableName, KeyField, KeyValue, Operation: string);
begin
  inherited Create(True); // Start suspended
  FTableName := TableName;
  FKeyField := KeyField;
  FKeyValue := KeyValue;
  FOperation := Operation;
end;

procedure TSendEventThread.Execute;
begin
  try
    WriteLog('Async HTTP worker started: ' + FOperation + ' ' + FTableName + ' ' + FKeyValue);
    SendEvent(FTableName, FKeyField, FKeyValue,FOperation);
  except
    on E: Exception do
      WriteLog('Async HTTP worker error: ' + E.ClassName + ': ' + E.Message);
  end;
end;

// JSON formatter
function JsonEscape(const S: string): string;
begin
  Result := S;
  Result := StringReplace(Result, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
  Result := StringReplace(Result, #8, '\b', [rfReplaceAll]);
  Result := StringReplace(Result, #9, '\t', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
  Result := StringReplace(Result, #12, '\f', [rfReplaceAll]);
  Result := StringReplace(Result, #13, '\r', [rfReplaceAll]);
end;

// Sending to server async mode
procedure SendEventAsync(const TableName, KeyField, KeyValue, Operation: string);
var
  Worker: TSendEventThread;
begin
  Worker := TSendEventThread.Create(TableName, KeyField, KeyValue,Operation);
  Worker.FreeOnTerminate := True;
  Worker.Resume;
end;

// Sending to server sync mode
procedure SendEvent(const TableName, KeyField, KeyValue, Operation: string);
var
  Body: TStringStream;
  HTTP: TIdHTTP;
  Json: string;
begin
  Json := '{' +
    '"timestamp":"' + JsonEscape(FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now)) + '",' +
    '"operation":"' + JsonEscape(Operation) + '",' +
    '"table":"' + JsonEscape(TableName) + '",' +
    '"keyField":"' + JsonEscape(KeyField) + '",' +
    '"keyValue":"' + JsonEscape(KeyValue) + '"' +
  '}';
  // writing JSON to log
  WriteLog('JSON: ' + Json);
  // HTTP  client                        
  HTTP := TIdHTTP.Create(nil);
  try
    HTTP.Request.ContentType := 'application/json';
    HTTP.ConnectTimeout := 3000;
    HTTP.ReadTimeout := 3000;
    // stream body
    Body := TStringStream.Create(UTF8Encode(Json));
    try
      HTTP.Post('http://10.0.0.10:3000/api/db-trigger', Body);
    finally
      Body.Free;
    end;
  except
    on E: EIdHTTPProtocolException do
    begin
      // there's a problem with HTTP Tidy client, all values are handled in the exceptions
      // it works and I don't give a shit
      if E.ErrorMessage <> '' then
        WriteLog('API REPLY: ' + E.ErrorMessage)
      else
        WriteLog('HTTP ERROR: ' + E.Message);
    end;
    on E: Exception do
    begin
      WriteLog('HTTP ERROR: ' + E.ClassName + ': ' + E.Message);
    end;
  end;
  // freeing HTTP instance
  HTTP.Free;
end;

end.
