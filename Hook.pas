unit Hook;

interface

uses Windows, SysUtils, Classes, dbisamtb, DB, Logger, HttpClient;

function ApplyHook(Parameter: Pointer): Integer; stdcall;

type
  // DBISAM trigger signature
  TDBISAMServerTrigger = procedure(Sender: TObject; TriggerSession: TDBISAMSession; TriggerDatabase: TDBISAMDatabase; const TableName: string; CurrentRecord: TDBISAMRecord) of object;
  // DBISAM Record data set signature
  TRecordDataSetAccess = class(TDBISAMRecordDataSet)
  public
    property Handle;
  end;
  // hook instance
  TTriggerHook = class
  private
    // table mapper
    FTableKeys: TStringList;
    // table offset mapper
    FTableKeyOffsets: TStringList;
    // getting records, PKs and registering table aux function
    function GetRecordDataSet(CurrentRecord: TDBISAMRecord): TRecordDataSetAccess;
    function GetPrimaryKeyField(const TableName: string): string;
    function GetPrimaryKeyOffset(const TableName: string): Integer;
    procedure RegisterTables;
  public
    // hook procedures from engine
    OriginalAfterInsert: TMethod;
    OriginalAfterUpdate: TMethod;
    // constructor / destructor
    constructor Create;
    destructor Destroy; override;
    // hooks declaration
    procedure FindStringsInRecord(CurrentRecord: TDBISAMRecord);
    procedure HookedAfterInsert(Sender: TObject; TriggerSession: TDBISAMSession;TriggerDatabase: TDBISAMDatabase; const TableName: AnsiString; CurrentRecord: TDBISAMRecord);
    procedure HookedAfterUpdate(Sender: TObject; TriggerSession: TDBISAMSession; TriggerDatabase: TDBISAMDatabase; const TableName: AnsiString; CurrentRecord: TDBISAMRecord);
  end;
implementation

  const
    // memory offsets for a2Server.exe
    MAINFORM_PTR_RVA = $270F34;
    ENGINE_OFFSET_IN_FORM = $0320;
    ON_AFTER_INSERT_OFFSET = $0128;
    ON_AFTER_UPDATE_OFFSET = $0140;

  // reading null terminator (stopping sku detection)  
  function ReadNullTerminatedString(P: PByte): string;
  var
    S: string;
  begin
    S := '';
    while (P^ <> 0) do
    begin
      S := S + Chr(P^);
      Inc(P);
    end;
    Result := S;
  end;
  // table mapper procedure
  procedure TTriggerHook.RegisterTables;
  begin
    FTableKeys := TStringList.Create;
    FTableKeyOffsets := TStringList.Create;
    // adding values
    FTableKeys.Values['Sinventario'] := 'FI_CODIGO';
    FTableKeys.Values['SinvDep'] := 'FT_CODIGOPRODUCTO';
    FTableKeys.Values['a2InvCostosPrecios'] := 'FIC_CODEITEM';
    // offsets
    FTableKeyOffsets.Values['Sinventario'] := '26';
    FTableKeyOffsets.Values['a2InvCostosPrecios'] := '26';
    FTableKeyOffsets.Values['SinvDep'] := '29';
  end;
  // constructor
  constructor TTriggerHook.Create;
  begin
    RegisterTables;
  end;
  // destructor
  destructor TTriggerHook.Destroy;
  begin
    FTableKeys.Free;
    FTableKeyOffsets.Free;
    inherited;
  end;
  // hook instance (get record data set)
  function TTriggerHook.GetRecordDataSet(CurrentRecord: TDBISAMRecord): TRecordDataSetAccess;
  begin
    Result := TRecordDataSetAccess(PPointer(NativeUInt(CurrentRecord) + 4)^);
  end;
  // hook instance (get PK field)
  function TTriggerHook.GetPrimaryKeyField(const TableName: string): string;
  begin
    Result := FTableKeys.Values[TableName];
  end;
  // after insert hook
  procedure TTriggerHook.HookedAfterInsert(Sender: TObject; TriggerSession: TDBISAMSession; TriggerDatabase: TDBISAMDatabase; const TableName: AnsiString; CurrentRecord: TDBISAMRecord);
  var
    OrigMethod: TDBISAMServerTrigger;
    RDS: TRecordDataSetAccess;
    CleanTableName: string;
    RecordBuffer: Pointer;
    KeyOffset: Integer;
    KeyField: string;
    KeyValue: string;
  begin
    WriteLog('*** HookedAfterInsert FIRED ***');
    // trimming tableName from memoru
    CleanTableName := string(PAnsiChar(TableName));
    WriteLog('AfterInsert TableName: ' + CleanTableName);
    // checking existence of original method
    if Assigned(OriginalAfterInsert.Code) then
    begin
      WriteLog('Calling original AfterInsert trigger...');
      // calling the original method if found in a2Server.exe
      TMethod(OrigMethod) := OriginalAfterInsert;
      OrigMethod(Sender, TriggerSession, TriggerDatabase, TableName, CurrentRecord);
    end;
    // then
    try
    // avoid Sfixed and others
    if FTableKeys.IndexOfName(CleanTableName) = -1 then
    begin
      WriteLog('Untracked table: ' + CleanTableName);
      Exit;
    end;
    // getting the PK
    KeyField := GetPrimaryKeyField(CleanTableName);
    WriteLog('Resolved KeyField: ' + KeyField);
    // PK string is found
    if KeyField = '' then
    begin
      WriteLog('AfterInsert: no registered primary key for table.');
      Exit;
    end;
    // evaluating current record
    if CurrentRecord <> nil then
    begin
      // getting the data set
      RDS := GetRecordDataSet(CurrentRecord);
      if RDS = nil then
      begin
        WriteLog('RDS = NIL');
        Exit;
      end;
      // buffer for the record
      RecordBuffer := Pointer(PCardinal(NativeUInt(RDS) + 640)^);
      if RecordBuffer = nil then
      begin
        WriteLog('RecordBuffer = NIL');
        Exit;
      end;
      // 26 positions after the buffer, we found the SKU
      KeyOffset := GetPrimaryKeyOffset(CleanTableName);
      KeyValue := ReadNullTerminatedString(PByte(NativeUInt(RecordBuffer) + KeyOffset));
      // found
      WriteLog('Extracted KeyValue: [' + KeyValue + ']');
      // sending data
      SendEvent(TableName, KeyField, KeyValue, 'INSERT');
    end;
    except
      on E: Exception do
        WriteLog('INSERT ERR: ' + E.ClassName + ': ' + E.Message);
    end;
  end;
  // offsets
  function TTriggerHook.GetPrimaryKeyOffset(const TableName: string): Integer;
  begin
    Result := StrToIntDef(FTableKeyOffsets.Values[TableName], -1);
  end;
  // after update hook
  procedure TTriggerHook.HookedAfterUpdate(Sender: TObject; TriggerSession: TDBISAMSession; TriggerDatabase: TDBISAMDatabase; const TableName: AnsiString; CurrentRecord: TDBISAMRecord);
  var
    OrigMethod: TDBISAMServerTrigger;
    RDS: TRecordDataSetAccess;
    CleanTableName: string;
    RecordBuffer: Pointer;
    KeyOffset: Integer;
    KeyField: string;
    KeyValue: string;
  begin
    WriteLog('*** HookedAfterUpdate FIRED ***');
    // trimming the table name
    CleanTableName := string(PAnsiChar(TableName));
    WriteLog('AfterUpdate TableName: ' + CleanTableName);
    // checking for implemented trigger code
    if Assigned(OriginalAfterUpdate.Code) then
    begin
      WriteLog('Calling original AfterUpdate trigger...');
      TMethod(OrigMethod) := OriginalAfterUpdate;
      OrigMethod(Sender, TriggerSession, TriggerDatabase, TableName, CurrentRecord);
    end;
    // running hook procedure from DLL
    try
      // avoid Sfixed and others
      if FTableKeys.IndexOfName(CleanTableName) = -1 then
      begin
        WriteLog('Untracked table: ' + CleanTableName);
        Exit;
      end;
      // getting the PK
      KeyField := GetPrimaryKeyField(CleanTableName);
      WriteLog('Resolved KeyField: ' + KeyField);
      // key field
      if KeyField = '' then
      begin
        WriteLog('AfterUpdate: no registered primary key for table.');
        Exit;
      end;
      // checking the current record
      if CurrentRecord <> nil then
      begin
        // getting the record set
        RDS := GetRecordDataSet(CurrentRecord);
        if RDS = nil then
        begin
          WriteLog('RDS = NIL');
          Exit;
        end;
        // getting the record buffer
        RecordBuffer := Pointer(PCardinal(NativeUInt(RDS) + 640)^);
        if RecordBuffer = nil then
        begin
          WriteLog('RecordBuffer = NIL');
          Exit;
        end;
        // getting the offset
        KeyOffset := GetPrimaryKeyOffset(CleanTableName);
        // key value found
        KeyValue := ReadNullTerminatedString(PByte(NativeUInt(RecordBuffer) + KeyOffset));
        // extracted SKU
        WriteLog('Extracted KeyValue: [' + KeyValue + ']');
        // sending update scenario
        SendEvent(TableName, KeyField, KeyValue, 'UPDATE');
    end;
    except
      on E: Exception do
        WriteLog('UPDATE ERR: ' + E.ClassName + ': ' + E.Message);
    end;
  end;
  // temporary procedure
  procedure TTriggerHook.FindStringsInRecord(CurrentRecord: TDBISAMRecord);
  var
    RDS: TRecordDataSetAccess;
    RecordBuffer: Pointer;
    RecordSize: Integer;
    I, StartPos, Len: Integer;
    B: Byte;
    S: string;
  begin
    WriteLog('=== STRING SCAN START ===');
    if CurrentRecord = nil then
      Exit;
    // getting the record size
    RecordSize := CurrentRecord.RecordSize;
    RDS := GetRecordDataSet(CurrentRecord);
    if RDS = nil then
    begin
      WriteLog('RDS = NIL');
      Exit;
    end;
    // getting the record buffer
    RecordBuffer := Pointer(PCardinal(NativeUInt(RDS) + 640)^);
    if RecordBuffer = nil then
    begin
      WriteLog('RecordBuffer = NIL');
      Exit;
    end;
    // initiating
    I := 0;
    while I < RecordSize do
    begin
      B := PByte(NativeUInt(RecordBuffer) + I)^;
      { Start of a printable ASCII sequence }
      if (B >= 32) and (B <= 126) then
      begin
        StartPos := I;
        S := '';
        while I < RecordSize do
        begin
          B := PByte(NativeUInt(RecordBuffer) + I)^;
          if (B < 32) or (B > 126) then
            Break;
          S := S + Chr(B);
          Inc(I);
        end;
        // length evaluation
        Len := Length(S);
        if Len >= 2 then
        begin
          WriteLog(Format('String @ %d len=%d: [%s]',[StartPos, Len, S]));
        end;
      end
      else
        Inc(I);
      end;
      WriteLog('=== STRING SCAN END ===');
  end;
  // apply hook internal function
  function ApplyHook(Parameter: Pointer): Integer; stdcall;
  var
    EngineBaseAddress: Pointer;
    EnginePtrAddress: Pointer;
    InsertEventPtr: ^TMethod;
    UpdateEventPtr: ^TMethod;
    ModuleBase: NativeUInt;
    HookInstance: TTriggerHook;
  begin
    Result := 0;
    Sleep(2000);
    // hook instance
    HookInstance := TTriggerHook(Parameter);
    if HookInstance = nil then
    begin
      WriteLog('ERROR: ApplyHook received NIL HookInstance.');
      Exit;
    end;
    // checking the module base
    ModuleBase := GetModuleHandle(nil);
    if ModuleBase = 0 then
    begin
      WriteLog('ERROR: Could not get ModuleBase handle');
      Exit;
    end;
    // checking instance
    WriteLog(Format('ModuleBase: %p', [Pointer(ModuleBase)]));
    // engine ptr address
    EnginePtrAddress := Pointer(ModuleBase + MAINFORM_PTR_RVA);
    WriteLog(Format('MainForm global variable address: %p', [EnginePtrAddress]));
    // engine base address
    EngineBaseAddress := Pointer(PPointer(EnginePtrAddress)^);
    if EngineBaseAddress = nil then
    begin
      WriteLog('ERROR: MainForm global variable contains NIL!');
      Exit;
    end;
    // main form pointer position
    WriteLog(Format('MainForm global variable points to: %p', [EngineBaseAddress]));
    // engine base address
    EngineBaseAddress := Pointer(PPointer(EngineBaseAddress)^);
    if EngineBaseAddress = nil then
    begin
      WriteLog('ERROR: Actual TMainForm instance is NIL!');
      Exit;
    end;
    // TMainForm instance
    WriteLog(Format('Actual TMainForm instance: %p', [EngineBaseAddress]));
    // engine base address
    EngineBaseAddress := Pointer(PPointer(NativeUInt(EngineBaseAddress) + ENGINE_OFFSET_IN_FORM)^);
    if EngineBaseAddress = nil then
    begin
      WriteLog('ERROR: TMainForm.a2Server contains NIL!');
      Exit;
    end;
    // Database engine instance
    WriteLog(Format('TDBISAMEngine instance: %p', [EngineBaseAddress]));
    // Insert event pointer
    InsertEventPtr := Pointer(NativeUInt(EngineBaseAddress) + ON_AFTER_INSERT_OFFSET);
    // update event pointer
    UpdateEventPtr := Pointer(NativeUInt(EngineBaseAddress) + ON_AFTER_UPDATE_OFFSET);
    // assigning code and data of the hooked method to the instance (replacing methods)
    HookInstance.OriginalAfterInsert := InsertEventPtr^;
    InsertEventPtr^.Code := @TTriggerHook.HookedAfterInsert;
    InsertEventPtr^.Data := HookInstance;
    WriteLog('AfterInsert hook applied successfully!');
    // and
    HookInstance.OriginalAfterUpdate := UpdateEventPtr^;
    UpdateEventPtr^.Code := @TTriggerHook.HookedAfterUpdate;
    UpdateEventPtr^.Data := HookInstance;
    WriteLog('AfterUpdate hook applied successfully!');
end;

end.
