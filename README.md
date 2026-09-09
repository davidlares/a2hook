## A2hook

A Reverse-engineered DLL injection and in-process DBISAM trigger interception for `a2Softway` a2Server.exe / dbsrvr

The project was created for a very specific compatibility target:

- a2Softway's `a2Server.exe` / DBISAM's `dbsrvr`
- 32-bit Win32 process
- DBISAM `4.29 Build 1`
- Delphi 2007 for the final DLL
- Windows XP 32-bit

The DLL observes selected `DBISAM` trigger events, extracts the affected record key directly from the in-memory record buffer, and sends an event to an HTTP endpoint as JSON.

#### Development lab

1. Delphi 2007 Win32
2. DBISAM 4.29 sources/runtime matching the target
3. Indy TIdHTTP

#### Important note

The hook works against the target build for which the addresses and object layouts were reverse-engineered. It is not a generic `DBISAM` hook and should not be expected to survive changes to the target executable, `DBISAM` version, compiler/runtime, or internal object layout without re-validation.

### What it does

At runtime, the DLL performs this flow:

                         a2Server.exe / dbsrvr
                                  |
                                  | DLL injection
                                  v
                           +--------------+
                           |   a2Hook.dll |
                           +--------------+
                                  |
                                  v
                       TDBISAMEngine event fields
                                  |
                    +-------------+-------------+
                    |                           |
                    v                           v
              AfterInsert                 AfterUpdate
                    |                           |
                    +-------------+-------------+
                                  |
                                  v
                         TDBISAM CurrentRecord
                                  |
                                  v
                         internal RDS object
                                  |
                                  v
                          raw record buffer
                                  |
                                  v
                         key at known offset
                                  |
                                  v
                            JSON payload
                                  |
                                  v
                       HTTP POST /api/db-trigger

The current implementation sends a compact event such as:

```
{
  "timestamp": "2026-08-31T08:13:00",
  "operation": "UPDATE",
  "table": "Sinventario",
  "keyField": "FI_CODIGO",
  "keyValue": "Y-002"
}
```

The JSON/HTTP implementation lives in `HttpClient.pas` file

## Why a2hook

The original goal was to know when records changed in the `a2Softway` database without polling the database continuously.

The initial idea began by building an external DBISAM listener and using the normal DBISAM trigger API, at least for the 4.52 version of it. That approach was useful for learning the API and confirming how `TDBISAMEngine` and trigger callbacks behaved, but it exposed an important limitation: the external client did not reliably observe every operation performed by the target application, and some application workflows created difficult DBISAM session/runtime conditions and, most importantly, broken database connections for certain forms (DBISAM 11308 error), especially with UNC paths.

At first, the dbsrvr with the engine was built here: [DBISAM](https://github.com/davidlares/dbsrvr)

When I decided to create the DLL it goal moved from external observation to in-process interception. Instead of replacing the ERP's original `a2Server.exe` program (originally for client-server communication), the DLL is loaded into the same address space as `a2Server.exe` and replaces the callback pointers already stored in the server's `TDBISAMEngine` instance.

## Delphi 2007

The final DLL was built with `Delphi 2007 Win32`.

This choice was project-specific. `Delphi 7` is also a Win32-era Delphi compiler and could, in principle, be used for many DLL injection and low-level `Win32` tasks. The reason `Delphi 2007` was selected was compatibility and practicality with the exact codebase and `DBISAM 4.29` environment being used during the investigation. Actually, `Delphi 2007` is the latest version that meets the `DBISAM 4.29 VCL` libraries, according to the `ElevateDB` website.

The toolchain evolved through several Delphi versions during the investigation. A newer Delphi/RAD Studio environment introduced a DBISAM package/runtime combination that did not match the target's `DBISAM 4.29` environment. The project therefore moved back to an older `Win32` Delphi toolchain rather than attempting to force newer DBISAM runtime assumptions into the injected process.

Delphi 2007 was the final compromise:

- Old enough to stay in the Win32/ANSI Delphi generation.
- New enough to provide a practical Win32 development environment.
- Suitable for the DBISAM 4.29 sources being used, and appropriate for generating a DLL that could share the target's general Delphi-era object model.

This does not mean that Delphi 2007 is universally required for Delphi DLL injection, or that Delphi 7 cannot inject a DLL. It means that Delphi 2007 was the toolchain selected for this particular target after compatibility testing.

## Why injecting a DLL

The DLL injection approach provides three main benefits:

1. It executes inside a2Server.exe's address space, which is legitimate software for the sake of A2 PoV.
2. It can access objects already created by the target application.
3. It can replace callback pointers in those objects directly.

The DLL does not need to start another DBISAM engine. It reuses the existing engine instance created by a2Server.

Since it performs injection, this is not creating a parallel DBISAM environment. It is attaching to the DBISAM environment that a2Server is already using.

## The DLL architecture

We can diagram it like this

```
a2Hook.dpr
      |
      +---- Hook.pas
      |
      +---- HttpClient.pas
      |
      +---- Logger.pas
```

#### a2Hook.dpr

This is the DLL entry point.

It simply register the DLL entry procedure; it handles `DLL_PROCESS_ATTACH` and `DLL_PROCESS_DETACH` procedures, creates the `TTriggerHook` and start the background thread that performs the actual hook installation.

The current implementation deliberately avoids doing all reverse-engineering work directly inside `DllMain` and starts `ApplyHook` in a separate thread.

So, it creates the hook instance and calls CreateThread during process attach.

#### Hook.pas

The main objective is to perform the hook installation;it does a lot at runtime.

Let's summarize it:

1. The `TDBISAMServerTrigger` callback definition
2. `TRecordDataSetAccess` helper type
3. The `TTriggerHook` instance
4. Table-to-primary-key mapping (aux function for JSON processing based on tables)
5. Record-buffer extraction
6. The `AfterInsert` hook and `AfterUpdate` hook detection
7. Original callback preservation and forwarding
8. Runtime discovery of the target's TDBISAMEngine instance

#### HttpClient.pas

This unit is deliberately independent of the DBISAM hook logic. It contains:

1. The `JsonEscape` function.
2. JSON serialization for the event envelope.
3. TIdHTTP POST logic.
4. Timeout configuration.
5. HTTP Error logging.

The current implementation posts to: `http://127.0.0.1:3000/api/db-trigger`

#### Logger.pas

This unit contains the simple file logger used during reverse engineering and runtime debugging. Keeping logging separate was useful because the logger is used by both the hook and HTTP code.

## Finding the engine instance

If you aren't familiar with Reverse engineering, we can quickly say that it is the process of learning how a compiled program works when you do not have its source code or when the source code is incomplete.

The tool I used to interact with and inspect the target executable `a2Server.exe` is `IDR` (Interactive Delphi Reconstructor). This is helpful for getting and understanding Delphi classes, methods, forms, fields, DBISAM-related stuff, and more. This is extremely helpful because you can find recognizable runtime structure, including a VMT (Virtual Method Table) at the beginning of the object.

### Let's recap

1. The `PTR/pointer`: A pointer is simply a value that contains the address of something else.
2. The `RVA / relative virtual address` (sometimes informally called a module-relative address): is an address as seen inside the process's virtual address space. An RVA is an address expressed relative to the module's base address, so since's is relatively to the module base, you can perform operations from it and get memory values more easily
3. The `VMT / Virtual Method Table`: Relative Virtual Address, useful for Delphi. A Delphi object normally begins with a pointer to its Virtual Method Table. This was useful because it helped distinguish a plausible Delphi object from a random or corrupted pointer.

#### Why VMTs matter in RE

If you know a program is Delphi and you find a pointer that looks like: `object address -> VMT address -> methods/data`, with that in mind, you can begin reconstructing the object's class structure. This is one of the reasons Delphi applications can be particularly approachable for reverse engineering compared with a completely unstructured native binary.

During the RE process, I found the following addresses that meet the precise offsets of the target (`a2Server.exe`); the most important is the `TDBISAMEngine` offset address. This is the main one

The current constants in `Hook.pas` are:

1. MAINFORM_PTR_RVA = $270F34;
2. ENGINE_OFFSET_IN_FORM = $0320;
3. ON_AFTER_INSERT_OFFSET = $0128;
4. ON_AFTER_UPDATE_OFFSET = $0140;

These values are reverse-engineered addresses/offsets for the target build.

The `MAINFORM_PTR_RVA` is the ModuleBase offset, and `ENGINE_OFFSET_IN_FORM` is the DBISAMEngine instance ready to be used when called by the `TMainForm` in `a2Server`

So, why offsets?

If reverse engineering shows that the DBISAM engine is stored at byte offset `0320`, then `TMainForm address + $0320` points to that field. The `+ $0320` value is an object field offset. These offsets are useful because the actual object address changes between executions, while its internal layout for the same compiled build remains stable.

So instead of: `02143000 = engine` we work with: `engine_object + $0128 = AfterInsert` and `engine_object + $0140 = AfterUpdate`

You can see both represented like this:

```
ModuleBase
   |
   +-- MAINFORM_PTR_RVA
            |
            v
       global pointer
            |
            v
       TMainForm instance
            |
            +-- ENGINE_OFFSET_IN_FORM
                        |
                        v
                 TDBISAMEngine
```

However, the actual code performs these pointer dereferences in `ApplyHook`.                

#### Why the ModuleBase

Because it's an absolute addresses inside a PE executable can move when the image is loaded at a different base address. An RVA is relative to the module image, so the code first obtains the module base and then adds the discovered RVA.

Conceptually, you can see it as: `runtime address = module base + reverse-engineered RVA.`

This is a classic PE reverse-engineering technique and is one reason the constant is called `MAINFORM_PTR_RVA` rather than simply being treated as a universal absolute address.

#### Then, the triggers

Once the `TDBISAMEngine` instance is located, the next problem is intercepting its existing callbacks.

Delphi event properties are stored as method references. A method reference can be represented as a `TMethod` containing two pieces:

Code -> address of executable method
Data -> object instance (`Self`)

The project uses this representation to preserve the original callback and replace it with the DLL's callback.

So, the original definition is something like this 

```
TDBISAMEngine.AfterUpdate
    Code -> original handler
    Data -> original object
```

Now, we changed the execution to this

```
TDBISAMEngine.AfterUpdate
    Code -> TTriggerHook.HookedAfterUpdate
    Data -> HookInstance
```

The original pair is stored in `OriginalAfterUpdate,`, so the hook can call the application's original handler first. The same pattern is used for `AfterInsert`. This is a form of function/event detouring at the object-data level rather than patching a machine-code `CALL` instruction.

That distinction makes the technique especially useful when the target stores the callback as a Delphi event field.

The code first checks `OriginalAfterInsert.Code` or `OriginalAfterUpdate.Code`, restores the TMethod locally into a callable trigger type, and invokes it with the original parameters. This reduces the risk of breaking the target's original trigger behavior.

### CurrentRecord

The trigger gives the DLL a `TDBISAMRecord` pointer. Initially, the obvious approach was to use high-level `DBISAM` APIs such as `CurrentRecord.Fields[I]Value`, but it didn't work at first because of I'm think there was an API mismatch, so the API-based approach was useful during investigation but proved unreliable inside the injected process. The Fields object could be obtained, but even basic collection operations could generate access violations.

Instead of moving in that direction, I went for the RecordBuffer.

### Reconstructing the record buffer

The working path is:

```
TDBISAMRecord
      |
      +-- offset +4
             |
             v
     TDBISAMRecordDataSet
             |
             +-- offset +640
                    |
                    v
             raw record buffer
```

The current source reflects this explicitly:

`Result := TRecordDataSetAccess(PPointer(NativeUInt(CurrentRecord) + 4)^);`

and

`RecordBuffer := Pointer(PCardinal(NativeUInt(RDS) + 640)^);`

There were hardcoded scenarios: simply reverse-engineered offsets for the target's `DBISAM 4.29` object layout, not documented DBISAM public API contracts

### With the record buffer in place

After obtaining the raw buffer, the investigation used memory dumps to locate the actual key bytes. For the `Sinventario` test record, the key `Y-002` appeared at offset 26 from the record buffer. The working extraction is therefore:

`KeyValue := ReadNullTerminatedString(PByte(NativeUInt(RecordBuffer) + 26));`

This is a format-specific binary extraction technique. It works because the target database record layout was empirically reconstructed for the relevant table/build. It should not be generalized to every DBISAM table.

Actually, this was luck, and it gracefully met the other scenarios as well

## The working scenario

I needed real-time changes from A2Softway's `a2Server.exe` to a middleware for third-party integrations

So, I only extracted the PK values and later proceeded to query them afterwards; the main goal was the whole tuple, which was possible in principle, but it substantially increased dependence on undocumented internal structure.

For the `a2Server.exe` business scenario, I mapped table names and PK keys like this

```
FTableKeys.Values['Sinventario'] := 'FI_CODIGO';
FTableKeys.Values['SinvDep'] := 'FT_CODIGOPRODUCTO';
FTableKeys.Values['a2InvCostosPrecios'] := 'FIC_CODEITEM';
```

The mapping converts an observed DBISAM table name into the key-field name that should be sent to the external system

#### The big headache

Delphi types and calling conventions must agree with the code already running inside the target process.

So, there were scenarios in which I needed to perform a cast from `string` to `AnsiString` to avoid getting encoded information

For that reason, you'll see something like

```
TDBISAMServerTrigger = procedure(
    Sender: TObject; 
    TriggerSession: TDBISAMSession; 
    TriggerDatabase: TDBISAMDatabase; 
    const TableName: string CurrentRecord: TDBISAMRecord
) of object;
```

The above is the original implementation of the trigger

The hook methods use `AnsiString` for the incoming table name and then normalize it with:

`CleanTableName := string(PAnsiChar(TableName));`

That behavior was established experimentally during the investigation because incorrect string assumptions produced corrupted table names.

### The DLL lifecycle

The DLL entry point currently performs the following lifecycle:

```
LoadLibrary / injection
        |
        v
DLL_PROCESS_ATTACH
        |
        +-- disable thread notifications
        +-- create TTriggerHook
        +-- start ApplyHook thread
                         |
                         +-- wait for target initialization
                         +-- locate main form
                         +-- locate TDBISAMEngine
                         +-- capture original event handlers
                         +-- replace event handlers

Normal execution
        |
        +-- AfterInsert
        +-- AfterUpdate

DLL unload
        |
        v
DLL_PROCESS_DETACH
        |
        +-- free TTriggerHook
```


The current `a2Hook.dpr` implements the attach/detach lifecycle and starts ApplyHook after the DLL is loaded

The two-second delay inside ApplyHook is a synchronization workaround used to give the target application time to initialize the objects whose addresses are being followed.

### Event delivery

The notification layer is intentionally simple.

The `HttpClient.pas` builds a JSON envelope containing:

1. timestamp
2. operation
3. table
4. keyField
5. keyValue

and sends it to the local HTTP service using Indy `TIdHTTP`.

The JSON is built manually because the final DLL targets Delphi 2007 rather than a newer Delphi runtime with the newer JSON APIs used during the early prototype. The body is UTF-8 encoded with UTF8Encode before it is posted.

### Further notes

Do not casually substitute another `DBISAM` version.

This project directly depends on reverse-engineered object layouts and callback storage. A new `DBISAM` build can change assumptions that are invisible at the source-code level. Likewise, changing the target executable can invalidate:


### Build it

Open the Delphi project: `a2Hook.groupproj`

The source is organized into:

1. a2Hook.dpr
2. Hook.pas
3. HttpClient.pas
4. Logger.pas

Build the Win32 DLL project.

The project produces: `a2Hook.dll`

The `.pas` files are compilation units; they are not separate DLLs. So, you'll need to make sure you have the right `DBISAM` dependencies installed in your environment.

### Runtime configuration

Since the data is sent to a local HTTP server on a port, at least create one, but you can see the logs in a hardcoded path: `C:\a2hook\debug.txt`

### The event flow

1. Suppose a DBISAM update affects: Table: `Sinventario` and  Key: `FI_CODIGO` with the value of `Y-002`.
2. The runtime sequence starts with DBISAM hitting AfterUpdate, and then the hook receives something like this: a2Hook.HookedAfterUpdate receives: Sender, TriggerSession, TriggerDatabase, TableName, CurrentRecord.
3. The original AfterUpdate handler is called.
4. The DLL normalizes the table name.
5. The table mapper resolves: `Sinventario` → `FI_CODIGO`
6. CurrentRecord is followed to the internal record-data-set object.
7. The raw record buffer is obtained.
8. Offset +26 is read as a null-terminated key
9. The extracted key is `Y-002`.
10. HttpClient builds JSON.
11. JSON is POSTed to the external endpoint.

### Log extract

```
2026-08-31 11:59 - === DLL_PROCESS_ATTACH: a2Hook loaded into process memory ===
2026-08-31 11:59 - ModuleBase: 00400000
2026-08-31 11:59 - MainForm global variable address: 00670F34
2026-08-31 11:59 - MainForm global variable points to: 00675F90
2026-08-31 11:59 - Actual TMainForm instance: 00C3B048
2026-08-31 11:59 - TDBISAMEngine instance: 00C117C0
2026-08-31 11:59 - AfterInsert hook applied successfully!
2026-08-31 11:59 - AfterUpdate hook applied successfully!
2026-08-31 11:59 - *** HookedAfterUpdate FIRED ***
2026-08-31 11:59 - AfterUpdate TableName: Sinventario
2026-08-31 11:59 - Resolved KeyField: FI_CODIGO
2026-08-31 11:59 - Extracted KeyValue: [Y-002]
2026-08-31 11:59 - JSON: {"timestamp":"2026-08-31T11:59:43","operation":"UPDATE","table":"Sinventario","keyField":"FI_CODIGO","keyValue":"Y-002"}
2026-08-31 11:59 - SendEvent HTTP ERROR: EIdSocketError: Socket Error # 10061
Connection refused.
```

## Credits
[David Lares S](https://davidlares.com)

## License
[MIT](https://opensource.org/licenses/MIT)