unit DelphiPP.Impl;

{ Go to implementation: from a call on an interface, `x.DoSomething()`, to each class's method
  that implements it, across the workspace's units. Delf's experiments 125 and 125b
  (experiments/ag/native/TsImpl.dpr), behind the language server (DelphiPP.Lsp's
  textDocument/implementation): Ctrl+click goes to the interface, this goes to the classes, a
  list when there is more than one. Wished for by a Delphi developer, passed on by the user:
  "In delphi it's so much harder to navigate to the implementation of an interface, and it's one
  of the reasons people don't use them as much as they could/should."

  The index: every .pas under the workspace folder, read once in the background: interfaces
  (parents, methods), classes (parents, fields, properties, methods, resolution clauses
  `procedure IFoo.Bar = Baz`), function results, unit globals, and where each TClass.Method's body
  is. A query: the open file's text as the editor has it, the name under the cursor; its receiver
  typed through the routine's locals and parameters, inline vars, the class's and its ancestors'
  fields and properties, globals, a function's result; then each class implementing the
  receiver's interface (or one inheriting from it) with arguments that can be the receiver's: its
  method (a resolution clause's, else its own or its nearest ancestor's), and each descendant's
  override. A sketch, not a compiler: no overloads, no uses-clause order (a name in two units:
  the first indexed), no `as` or `with`, generic constraints unchecked. Files saved after the
  index was built are not re-read until the server restarts. }

interface

uses
  System.SysUtils;

type
  TImplTarget = record
    Path: string;
    Line: Integer;                    // from 1: the body's first line
    Name: string;                     // TClass.Method as its heading writes it; a reference's line
    Col: Integer;                     // from 0: where the name is (0 for an implementation)
    Len: Integer;                     // the name's length, for a reference's range (0: a point)
  end;

// start indexing the folder's units in the background (again: a fresh index)
procedure IndexFolder(const Folder: string);

// the same for a project: the .pas under each of Deep, with their subfolders, and those directly
// in each of Flat (a search path, read as the compiler reads it); each file once
procedure IndexFolders(const Deep, Flat: TArray<string>);

// the files in the index, once it is built (0 while building)
function IndexedCount: Integer;

// the implementations for the name at Line, Character (LSP's: from 0, UTF-16 units) in Text,
// the file at Path as the editor has it; waits for the index up to WaitMs
function Implementations(const Path, Text: string; Line, Character: Integer;
  WaitMs: Cardinal = 30000): TArray<TImplTarget>;

// where the name at Line, Character is declared: a local or parameter, a member of the class
// (or of the receiver's type, in x.M) or an ancestor's, a declaration of the unit's, then of the
// workspace's; none, or one
function Definitions(const Path, Text: string; Line, Character: Integer;
  WaitMs: Cardinal = 30000): TArray<TImplTarget>;

// where the type of the name (or of x.M) at Line, Character is declared
function TypeDefinitions(const Path, Text: string; Line, Character: Integer;
  WaitMs: Cardinal = 30000): TArray<TImplTarget>;

// every use of the name at Line, Character across the index: each identifier of that name whose
// definition (as Definitions finds it) is the same place; the declaration itself too if
// IncludeDeclaration. TextOf gives an editor's text for a file it has open ('' for none: the
// file as saved); the file at Path is Text
function References(const Path, Text: string; Line, Character: Integer; IncludeDeclaration: Boolean;
  const TextOf: TFunc<string, string> = nil; WaitMs: Cardinal = 30000): TArray<TImplTarget>;

implementation

uses
  System.Classes, System.IOUtils, System.SyncObjs, System.Generics.Collections,
  TreeSitter.Api;

type
  TBytesA = TArray<Byte>;

  TPos = record
    Line, Col: Integer;               // from 1, from 0
    Name: string;                     // as written
  end;

  TTypeInfo = class
    Name: string;
    IsIntf: Boolean;
    Forward: Boolean;                 // `TFoo = class;`: until the full declaration is read
    FileIdx, Line: Integer;
    Col: Integer;                     // the name's, from 0
    Parents: TList<string>;                     // in full: lower case, no spaces
    Methods: TDictionary<string, Integer>;
    Resolutions: TDictionary<string, string>;   // 'ifoo.bar' -> 'baz'
    Members: TDictionary<string, string>;       // field or property -> its type, in full
    Results: TDictionary<string, string>;       // a function method -> its result type
    TParams: TList<string>;
    Places: TDictionary<string, TPos>;          // a member -> where its name is declared;
                                                // an overload's first
    constructor Create;
    destructor Destroy; override;
  end;

  TPlace = record
    FileIdx, Line: Integer;
    Name: string;
    Col: Integer;                     // from 0
  end;

  TLocals = TList<TDictionary<string, string>>;

var
  Lock: TCriticalSection;
  Ready: TEvent;
  KindNames: TDictionary<PAnsiChar, string>;
  Paths: TList<string>;
  Globals: TObjectList<TDictionary<string, string>>;
  Types: TObjectDictionary<string, TTypeInfo>;
  Impls: TDictionary<string, TPlace>;
  Funcs: TDictionary<string, string>;
  ImplCache: TObjectDictionary<string, TList<string>>;
  Names: TDictionary<string, TPlace>; // a unit's type, routine, var or const: where it is declared
  Aliases: TDictionary<string, string>; // `IRowMapper = IRowMapper<TObject>;`: irowmapper -> irowmapper<tobject>
                                      // (the first unit's, for a name in two)
  Stopping: Boolean;                 // the unit finalizing (the IDE unloading its package)
  Built: Boolean;
  Running: Integer;                   // indexing threads not yet finished

constructor TTypeInfo.Create;
begin
  Parents := TList<string>.Create;
  Methods := TDictionary<string, Integer>.Create;
  Resolutions := TDictionary<string, string>.Create;
  Members := TDictionary<string, string>.Create;
  Results := TDictionary<string, string>.Create;
  TParams := TList<string>.Create;
  Places := TDictionary<string, TPos>.Create;
end;

destructor TTypeInfo.Destroy;
begin
  Parents.Free; Methods.Free; Resolutions.Free; Members.Free; Results.Free; TParams.Free; Places.Free;
  inherited;
end;

{ text and nodes }

function ValidUtf8(const B: TBytesA; From: Integer): Boolean;
begin
  var I := From;
  const N = Length(B);
  while I < N do
  begin
    const C = B[I];
    var K: Integer;
    if C < $80 then K := 0
    else if (C and $E0) = $C0 then begin if C < $C2 then Exit(False); K := 1 end
    else if (C and $F0) = $E0 then K := 2
    else if (C and $F8) = $F0 then begin if C > $F4 then Exit(False); K := 3 end
    else Exit(False);
    if I + K > N - 1 then Exit(False);
    Inc(I);
    while K > 0 do
    begin
      if (B[I] and $C0) <> $80 then Exit(False);
      Inc(I);
      Dec(K);
    end;
  end;
  Result := True;
end;

function TextOfFile(const Path: string): string;
begin
  const Raw = TFile.ReadAllBytes(Path);
  var From := 0;
  if (Length(Raw) >= 3) and (Raw[0] = $EF) and (Raw[1] = $BB) and (Raw[2] = $BF) then
    From := 3;
  if ValidUtf8(Raw, From) then
    Result := TEncoding.UTF8.GetString(Raw, From, Length(Raw) - From)
  else
  begin
    const E = TEncoding.GetEncoding(1252);
    try
      Result := E.GetString(Raw);
    finally
      E.Free;
    end;
  end;
end;

function Bytes(const Text: string): TBytesA;
begin
  Result := TEncoding.UTF8.GetBytes(Text.Replace(#13#10, #10).Replace(#13, #10));
end;

function KindOf(const N: TSNode): string;
begin
  const P = ts_node_type(N);
  if not KindNames.TryGetValue(P, Result) then
  begin
    Result := string(AnsiString(P));
    KindNames.Add(P, Result);
  end;
end;

function Txt(const Src: TBytesA; const N: TSNode): string;
begin
  Result := TEncoding.UTF8.GetString(Src, ts_node_start_byte(N), ts_node_end_byte(N) - ts_node_start_byte(N));
end;

function Kids(const N: TSNode): TArray<TSNode>;
begin
  SetLength(Result, ts_node_child_count(N));
  for var I := 0 to High(Result) do
    Result[I] := ts_node_child(N, I);
end;

function IsNull(const N: TSNode): Boolean; inline;
begin
  Result := ts_node_is_null(N);
end;

function FirstOf(const N: TSNode; const Kind: string): TSNode;
begin
  for var C in Kids(N) do
    if KindOf(C) = Kind then
      Exit(C);
  Result := Default(TSNode);
  Result := ts_node_child(N, ts_node_child_count(N));     // a null node
end;

function LineOf(const N: TSNode): Integer;
begin
  Result := ts_node_start_point(N).Row + 1;
end;

// a name with no unit and no generic arguments, lower case: a method's, or the base of a type's Key
function BaseKey(const S: string): string;
begin
  var T := S.Trim;
  var I := T.IndexOf('<');
  if I >= 0 then
    T := T.Substring(0, I);
  I := T.LastIndexOf('.');
  if I >= 0 then
    T := T.Substring(I + 1);
  Result := T.Trim.TrimLeft(['&']).ToLower;
end;

function Full(const S: string): string;
begin
  Result := S.Replace(' ', '').Replace(#10, '').Replace(#9, '').Replace('&', '').ToLower;
end;

function Args(const S: string): TArray<string>;
begin
  Result := nil;
  var From := S.IndexOf('<');
  if From < 0 then
    Exit;
  var Depth := 0;
  Inc(From);
  for var I := From to S.Length - 1 do
    case S.Chars[I] of
      '<': Inc(Depth);
      '>': if Depth = 0 then
           begin
             Result := Result + [S.Substring(From, I - From)];
             Break;
           end
           else Dec(Depth);
      ',': if Depth = 0 then
           begin
             Result := Result + [S.Substring(From, I - From)];
             From := I + 1;
           end;
    end;
end;

// a type as written (IList<IBuilderInspector>, Spring.Collections.ICollection<T>): its name and how
// many generic arguments, `icollection`1`, as .NET writes it. ICollection and ICollection<T> are
// two types (Spring.Collections declares both); with one key, the first read stood for both, and
// IList<T>'s Remove, ICollection<T>'s alone, was found nowhere (user, 20 Nov: "add has
// implementations ... what about remove?")
function Key(const S: string): string;
begin
  Result := BaseKey(S);
  const N = Length(Args(S.Trim));
  if N > 0 then
    Result := Result + '`' + IntToStr(N);
end;

// a declaration's type parameters: `<T: class, constructor; TID>` is T and TID (groups by ';',
// names before a ':', constraints after it)
function TypeParams(const NameText: string): TArray<string>;
begin
  Result := nil;
  var TP := Full(NameText);
  if TP.IndexOf('<') < 0 then
    Exit;
  TP := TP.Substring(TP.IndexOf('<') + 1).TrimRight(['>']);
  for var G in TP.Split([';']) do
    for var Nm in (if G.IndexOf(':') >= 0 then G.Substring(0, G.IndexOf(':')) else G).Split([',']) do
      if Nm <> '' then
        Result := Result + [Nm];
end;

// a declared type's Key: its parameters counted as declared, constraints and all
function DeclKey(const NameText: string): string;
begin
  Result := BaseKey(NameText);
  const N = Length(TypeParams(NameText));
  if N > 0 then
    Result := Result + '`' + IntToStr(N);
end;

function Norm(const S: string): string;
begin
  Result := BaseKey(S);
  const A = Args(S);
  if Length(A) > 0 then
  begin
    Result := Result + '<';
    for var I := 0 to High(A) do
      Result := Result + (if I > 0 then ',' else '') + Norm(A[I]);
    Result := Result + '>';
  end;
end;

function TypeChild(const N: TSNode): TSNode;
begin
  for var C in Kids(N) do
    if (KindOf(C) = 'type') or (KindOf(C) = 'typeref') then
      Exit(C);
  Result := ts_node_child(N, ts_node_child_count(N));
end;

{ the index }

function PosOf(const Src: TBytesA; const N: TSNode): TPos;
begin
  Result.Line := LineOf(N);
  Result.Col  := ts_node_start_point(N).Column;
  Result.Name := Txt(Src, N);
end;

// a unit-level name (Key: no generic arguments, no unit), the first unit's
procedure AddName(FileIdx: Integer; const Src: TBytesA; const N: TSNode);
begin
  var P: TPlace;
  P.FileIdx := FileIdx;
  P.Line    := LineOf(N);
  P.Col     := ts_node_start_point(N).Column;
  P.Name    := Txt(Src, N);
  Names.TryAdd(DeclKey(P.Name), P);
end;

procedure AddMembers(Info: TTypeInfo; const Src: TBytesA; const N: TSNode);
begin
  for var C in Kids(N) do
  begin
    const K = KindOf(C);
    if K = 'declSection' then
      AddMembers(Info, Src, C)
    else if (K = 'declField') or (K = 'declProp') then
    begin
      const T = TypeChild(C);
      const Ty = if IsNull(T) then '' else Full(Txt(Src, T));
      for var D in Kids(C) do
        if KindOf(D) = 'identifier' then
        begin
          Info.Members.AddOrSetValue(Txt(Src, D).ToLower, Ty);
          Info.Places.TryAdd(Txt(Src, D).ToLower, PosOf(Src, D));
          if K = 'declProp' then
            Break;
        end
        else if (KindOf(D) = 'type') or (KindOf(D) = 'typeref') then
          Break;
    end
    else if K = 'declProc' then
    begin
      var Name := ts_node_child(C, ts_node_child_count(C));
      for var D in Kids(C) do
        if (KindOf(D) = 'identifier') or (KindOf(D) = 'genericDot') then
        begin
          Name := D;
          Break;
        end;
      if IsNull(Name) then
        Continue;
      if KindOf(Name) = 'genericDot' then
      begin
        const Def = FirstOf(C, 'defaultValue');
        if not IsNull(Def) then
        begin
          const D = FirstOf(Def, 'identifier');
          if not IsNull(D) then
            Info.Resolutions.AddOrSetValue(Txt(Src, Name).Replace(' ', '').ToLower, Txt(Src, D).ToLower);
        end;
        Continue;
      end;
      Info.Methods.AddOrSetValue(Txt(Src, Name).ToLower, LineOf(C));
      Info.Places.TryAdd(Txt(Src, Name).ToLower, PosOf(Src, Name));
      const T = FirstOf(C, 'typeref');
      if not IsNull(T) then
        Info.Results.AddOrSetValue(Txt(Src, Name).ToLower, Full(Txt(Src, T)));
    end;
  end;
end;

procedure IndexType(FileIdx: Integer; const Src: TBytesA; const Decl: TSNode);
begin
  var NameN := ts_node_child(Decl, ts_node_child_count(Decl));
  for var C in Kids(Decl) do
    if (KindOf(C) = 'identifier') or (KindOf(C) = 'genericTpl') then
    begin
      NameN := C;
      Break;
    end;
  var Body := FirstOf(Decl, 'declIntf');
  if IsNull(Body) then
  begin
    const C = FirstOf(Decl, 'type');
    if not IsNull(C) then
    begin
      Body := FirstOf(C, 'declClass');
      if IsNull(Body) then
        Body := FirstOf(C, 'declIntf');
    end;
  end;
  if IsNull(NameN) or IsNull(Body) then
    Exit;
  const K = DeclKey(Txt(Src, NameN));
  // `IFoo = interface;`, `TFoo = class;`: a forward declaration, no parents and no members; the
  // full one, later, takes its place (until 20 Nov the forward one stayed, and the interface
  // seemed to have no methods)
  const BodyText = Full(Txt(Src, Body));
  const Forward = (BodyText = 'class') or (BodyText = 'interface') or (BodyText = 'dispinterface');
  var Old: TTypeInfo;
  if Types.TryGetValue(K, Old) and (Forward or not Old.Forward) then
    Exit;                             // a name in two units: the first's
  const Info = TTypeInfo.Create;
  Info.Forward := Forward;
  Info.Name := Txt(Src, NameN);
  Info.IsIntf := KindOf(Body) = 'declIntf';
  Info.FileIdx := FileIdx;
  Info.Line := LineOf(Decl);
  Info.Col := ts_node_start_point(NameN).Column;
  Info.TParams.AddRange(TypeParams(Txt(Src, NameN)));
  for var C in Kids(Body) do
    if KindOf(C) = 'typeref' then
      Info.Parents.Add(Full(Txt(Src, C)));
  AddMembers(Info, Src, Body);
  Types.AddOrSetValue(K, Info);       // over a forward declaration (freeing it)
end;

// `IRowMapper = IRowMapper<TObject>;`: another name for a type. Once IRowMapper<T> had a key of its
// own, rowMapper: IRowMapper found nothing (Delf's 125e, 20 Nov): the alias is followed instead
procedure AddAlias(const Src: TBytesA; const Decl: TSNode);
begin
  var NameN := Default(TSNode);
  for var C in Kids(Decl) do
    if (KindOf(C) = 'identifier') or (KindOf(C) = 'genericTpl') then
    begin
      NameN := C;
      Break;
    end;
  const T = TypeChild(Decl);
  if IsNull(NameN) or IsNull(T) then
    Exit;
  // a type's name, maybe a unit's and with arguments: not a class, a record, a set, a range ...
  const Target = Full(Txt(Src, T));
  if Target = '' then
    Exit;
  for var Ch in Target do
    if not CharInSet(Ch, ['a'..'z', '0'..'9', '_', '.', '<', '>', ',']) then
      Exit;
  const K = DeclKey(Txt(Src, NameN));
  if Key(Target) = K then
    Exit;                             // the same name from another unit: IEnumerator = Spring.IEnumerator
  Aliases.TryAdd(K, Target);
end;

// a type through its aliases, in full: irowmapper -> irowmapper<tobject>; a class or interface
// of that name first
function Resolve(const Ty: string): string;
begin
  Result := Ty;
  var Target: string;
  for var I := 1 to 8 do
  begin
    if (Result = '') or Types.ContainsKey(Key(Result)) or not Aliases.TryGetValue(Key(Result), Target) then
      Exit;
    Result := Target;
  end;
end;

procedure IndexNode(FileIdx: Integer; const Src: TBytesA; const N: TSNode; InType: Boolean);
begin
  const K = KindOf(N);
  if K = 'declType' then
  begin
    // any type: a record, an enumeration, an alias too; not a forward declaration's name
    const Decl = Full(Txt(Src, N)).TrimRight([';']);
    if not (Decl.EndsWith('=class') or Decl.EndsWith('=interface') or Decl.EndsWith('=dispinterface')) then
      for var C in Kids(N) do
        if (KindOf(C) = 'identifier') or (KindOf(C) = 'genericTpl') then
        begin
          AddName(FileIdx, Src, C);
          Break;
        end;
    IndexType(FileIdx, Src, N);
    AddAlias(Src, N);
    InType := True;
  end
  else if K = 'defProc' then
  begin
    const H = FirstOf(N, 'declProc');
    if not IsNull(H) then
    begin
      const Nm = FirstOf(H, 'genericDot');
      if not IsNull(Nm) then
      begin
        const Parts = Txt(Src, Nm).Replace(' ', '').Split(['.']);
        if Length(Parts) >= 2 then
        begin
          var P: TPlace;
          P.FileIdx := FileIdx;
          P.Line := LineOf(N);
          P.Name := Parts[High(Parts) - 1] + '.' + Parts[High(Parts)];
          Impls.AddOrSetValue(Key(Parts[High(Parts) - 1]) + '.' + BaseKey(Parts[High(Parts)]), P);
        end;
      end
      else
      begin
        const Id = FirstOf(H, 'identifier');
        const T = FirstOf(H, 'typeref');
        if not IsNull(Id) then
          AddName(FileIdx, Src, Id);  // a routine with no declaration in an interface section
        if not IsNull(Id) and not IsNull(T) and not Funcs.ContainsKey(Txt(Src, Id).ToLower) then
          Funcs.Add(Txt(Src, Id).ToLower, Full(Txt(Src, T)));
      end;
    end;
    Exit;
  end
  else if (K = 'declProc') and not InType then
  begin
    const Id = FirstOf(N, 'identifier');
    const T = FirstOf(N, 'typeref');
    if not IsNull(Id) then
      AddName(FileIdx, Src, Id);
    if not IsNull(Id) and not IsNull(T) and not Funcs.ContainsKey(Txt(Src, Id).ToLower) then
      Funcs.Add(Txt(Src, Id).ToLower, Full(Txt(Src, T)));
  end
  else if ((K = 'declVar') or (K = 'declConst')) and not InType then
  begin
    for var C in Kids(N) do
      if KindOf(C) = 'identifier' then
        AddName(FileIdx, Src, C);
    const T = TypeChild(N);
    if not IsNull(T) then
      for var C in Kids(N) do
        if KindOf(C) = 'identifier' then
          Globals[FileIdx].AddOrSetValue(Txt(Src, C).ToLower, Full(Txt(Src, T)));
  end;
  for var C in Kids(N) do
    IndexNode(FileIdx, Src, C, InType);
end;

procedure Build(const Deep, Flat: TArray<string>);
begin
  const Parser = ts_parser_new;
  const Seen = TDictionary<string, Boolean>.Create;
  try
    ts_parser_set_language(Parser, tree_sitter_delphi13);
    var Files: TArray<string> := nil;
    for var I := 0 to High(Deep) + Length(Flat) do
    try
      if I <= High(Deep) then
        Files := Files + TDirectory.GetFiles(Deep[I], '*.pas', TSearchOption.soAllDirectories)
      else
        Files := Files + TDirectory.GetFiles(Flat[I - Length(Deep)], '*.pas', TSearchOption.soTopDirectoryOnly);
    except
      // a folder we can't read, or one that isn't there: the others
    end;
    for var F in Files do
    begin
      if Stopping or (Paths.Count >= 20000) then
        Break;                        // unloading; or a whole drive opened as a workspace: enough
      const FK = TPath.GetFullPath(F).ToLower;
      if Seen.ContainsKey(FK) then
        Continue;                     // the project's folder is on its search path too
      Seen.Add(FK, True);
      var Src: TBytesA;
      try
        Src := Bytes(TextOfFile(F));
      except
        Continue;
      end;
      const Idx = Paths.Add(F);
      Globals.Add(TDictionary<string, string>.Create);
      const Tree = ts_parser_parse_string(Parser, nil, PByte(Src), Length(Src));
      try
        IndexNode(Idx, Src, ts_tree_root_node(Tree), False);
      finally
        ts_tree_delete(Tree);
      end;
    end;
    // every unit read: each heritage through its aliases (class(TInterfacedObject, IRowMapper))
    for var Info in Types.Values do
      for var I := 0 to Info.Parents.Count - 1 do
        Info.Parents[I] := Resolve(Info.Parents[I]);
  finally
    Seen.Free;
    ts_parser_delete(Parser);
  end;
end;

procedure IndexFolders(const Deep, Flat: TArray<string>);
begin
  Ready.ResetEvent;
  TInterlocked.Increment(Running);
  Built := False;
  TThread.CreateAnonymousThread(procedure
    begin
      try
        Lock.Enter;
        try
          Paths.Clear; Globals.Clear; Types.Clear; Impls.Clear; Funcs.Clear; ImplCache.Clear; Names.Clear; Aliases.Clear;
          try
            Build(Deep, Flat);
          except
            // what was indexed before the failure stays
          end;
        finally
          Built := True;
          Lock.Leave;
          Ready.SetEvent;
        end;
      finally
        TInterlocked.Decrement(Running);
      end;
    end).Start;
end;

procedure IndexFolder(const Folder: string);
begin
  IndexFolders([Folder], nil);
end;

function IndexedCount: Integer;
begin
  Result := 0;
  if Built and Lock.TryEnter then
  try
    Result := Paths.Count;
  finally
    Lock.Leave;
  end;
end;

{ queries }

function ClassParent(const Info: TTypeInfo): string;
begin
  Result := '';
  if (Info.Parents.Count > 0) and Types.ContainsKey(Key(Info.Parents[0])) and
     not Types[Key(Info.Parents[0])].IsIntf then
    Result := Key(Info.Parents[0]);
end;

function Implementers(const Intf: string): TList<string>;
begin
  if not ImplCache.TryGetValue(Intf, Result) then
  begin
    Result := TList<string>.Create;
    const Wanted = TDictionary<string, Boolean>.Create;
    try
      Wanted.Add(Intf, True);
      var Changed: Boolean;
      repeat
        Changed := False;
        for var Pair in Types do
          if not Wanted.ContainsKey(Pair.Key) then
            for var P in Pair.Value.Parents do
              if Wanted.ContainsKey(Key(P)) then
              begin
                Wanted.Add(Pair.Key, True);
                Changed := True;
                Break;
              end;
      until not Changed;
      for var Pair in Types do
        if not Pair.Value.IsIntf and Wanted.ContainsKey(Pair.Key) then
          Result.Add(Pair.Key);
    finally
      Wanted.Free;
    end;
    ImplCache.Add(Intf, Result);
  end;
end;

function ImplementingMethod(const Cls, Intf, M: string; out Owner, Method: string): Boolean;
begin
  var C := Cls;
  var Depth := 0;
  var Info: TTypeInfo;
  while (C <> '') and Types.TryGetValue(C, Info) and (Depth < 64) do
  begin
    if Info.Resolutions.ContainsKey(Intf + '.' + M) then
    begin
      Owner := C;
      Method := Info.Resolutions[Intf + '.' + M];
      Exit(True);
    end;
    if Info.Methods.ContainsKey(M) then
    begin
      Owner := C;
      Method := M;
      Exit(True);
    end;
    C := ClassParent(Info);
    Inc(Depth);
  end;
  Result := False;
end;

function DeclaringIntf(const Intf, M: string; Depth: Integer = 0): string;
begin
  var Info: TTypeInfo;
  if (Depth > 32) or not Types.TryGetValue(Intf, Info) then
    Exit('');
  if Info.Methods.ContainsKey(M) then
    Exit(Intf);
  for var P in Info.Parents do
  begin
    Result := DeclaringIntf(Key(P), M, Depth + 1);
    if Result <> '' then
      Exit;
  end;
  Result := '';
end;

function Reaches(const T, Intf: string; const Recv: TArray<string>; const Wild: TList<string>;
  Depth: Integer): Boolean;
begin
  Result := False;
  var Info: TTypeInfo;
  if (Depth > 32) or not Types.TryGetValue(T, Info) then
    Exit;
  for var P in Info.Parents do
    if Key(P) = Intf then
    begin
      const A = Args(P);
      if Length(A) <> Length(Recv) then
        Exit(True);
      var Ok := True;
      for var I := 0 to High(A) do
        if not (Info.TParams.Contains(Key(A[I])) or ((Wild <> nil) and Wild.Contains(Key(Recv[I])))
                or (Norm(A[I]) = Norm(Recv[I]))) then
          Ok := False;
      if Ok then
        Exit(True);
    end
    else if Reaches(Key(P), Intf, Recv, Wild, Depth + 1) then
      Exit(True);
end;

function TypeOfName(const Name, Cls: string; FileIdx: Integer; Locals: TLocals): string;
begin
  for var I := Locals.Count - 1 downto 0 do
    if Locals[I].TryGetValue(Name, Result) then
      Exit;
  var C := Cls;
  var Depth := 0;
  var Info: TTypeInfo;
  while (C <> '') and Types.TryGetValue(C, Info) and (Depth < 64) do
  begin
    if Info.Members.TryGetValue(Name, Result) or Info.Results.TryGetValue(Name, Result) then
      Exit;
    C := ClassParent(Info);
    Inc(Depth);
  end;
  if (FileIdx >= 0) and Globals[FileIdx].TryGetValue(Name, Result) then
    Exit;
  if Funcs.TryGetValue(Name, Result) then
    Exit;
  Result := '';
end;

function TypeOfExpr(const Src: TBytesA; const N: TSNode; const Cls: string; FileIdx: Integer;
  Locals: TLocals): string;
begin
  const K = KindOf(N);
  if K = 'identifier' then
  begin
    const L = Txt(Src, N).ToLower;
    if L = 'self' then
      Exit(Cls);
    Exit(TypeOfName(L, Cls, FileIdx, Locals));
  end;
  if K = 'exprParens' then
    for var E in Kids(N) do
      if (KindOf(E) <> '(') and (KindOf(E) <> ')') then
        Exit(TypeOfExpr(Src, E, Cls, FileIdx, Locals));
  if K = 'exprCall' then
    Exit(TypeOfExpr(Src, ts_node_child(N, 0), Cls, FileIdx, Locals));
  if K = 'exprDot' then
  begin
    var L := Resolve(TypeOfExpr(Src, ts_node_child(N, 0), Cls, FileIdx, Locals));
    const M = Txt(Src, ts_node_child(N, ts_node_child_count(N) - 1)).ToLower;
    var Info: TTypeInfo;
    var Depth := 0;
    while (L <> '') and Types.TryGetValue(Key(L), Info) and (Depth < 64) do
    begin
      if Info.Members.TryGetValue(M, Result) or Info.Results.TryGetValue(M, Result) then
        Exit;
      if Info.IsIntf then
      begin
        if Info.Parents.Count = 0 then
          Break;
        L := Info.Parents[0];
      end
      else
        L := ClassParent(Info);
      Inc(Depth);
    end;
  end;
  Result := '';
end;

procedure AddDecl(const Src: TBytesA; const N: TSNode; D: TDictionary<string, string>);
begin
  const T = TypeChild(N);
  if IsNull(T) then
    Exit;
  for var Y in Kids(N) do
    if KindOf(Y) = 'identifier' then
      D.AddOrSetValue(Txt(Src, Y).ToLower, Full(Txt(Src, T)));
end;

// a routine's parameters, its var sections, and its body's typed inline vars before Before
procedure AddLocals(const Src: TBytesA; const Def: TSNode; Before: UInt32; D: TDictionary<string, string>);

  procedure Walk(const N: TSNode; InBody: Boolean);
  begin
    for var Z in Kids(N) do
    begin
      const K = KindOf(Z);
      if K = 'defProc' then
        Continue;                     // a nested routine's own
      if (K = 'declArg') or (K = 'declVar') or (K = 'declConst') then
        AddDecl(Src, Z, D)
      else if (K = 'varAssignDef') and (ts_node_start_byte(Z) < Before) then
        AddDecl(Src, Z, D)
      else
        Walk(Z, InBody or (K = 'block'));
    end;
  end;

begin
  Walk(Def, False);
end;

function FileIndexOf(const Path: string): Integer;
begin
  for var I := 0 to Paths.Count - 1 do
    if SameText(Paths[I], Path) then
      Exit(I);
  Result := -1;
end;

{ a query: the file as the editor has it, parsed; the identifier under the cursor, the way down
  to it, the class its routine belongs to, and the locals of each routine around it }

type
  TQuery = class
    Src: TBytesA;
    Parser: TSParser;
    Tree: TSTree;
    Chain: TList<TSNode>;             // from the root to N
    N: TSNode;
    Found: Boolean;                   // N is an identifier
    Cls: string;                      // the class of the method around the cursor, by Key
    Locals: TLocals;
    FileIdx: Integer;
    constructor Create(const Path, Text: string; Line, Character: Integer);  // parsed, and at Line, Character
    constructor CreateParsed(const Path, Text: string);
    destructor Destroy; override;
    procedure Seek(Line, Col: UInt32);  // to the name at Line, Col (from 0; Col in bytes)
    function Up: TSNode;              // N's parent
    function IsMember: Boolean;       // N is M in x.M
    function Name: string;            // N's text, lower case
  end;

constructor TQuery.CreateParsed(const Path, Text: string);
begin
  Chain := TList<TSNode>.Create;
  Locals := TLocals.Create;
  FileIdx := FileIndexOf(Path);
  Src := Bytes(Text);
  Parser := ts_parser_new;
  ts_parser_set_language(Parser, tree_sitter_delphi13);
  Tree := ts_parser_parse_string(Parser, nil, PByte(Src), Length(Src));
end;

constructor TQuery.Create(const Path, Text: string; Line, Character: Integer);
begin
  CreateParsed(Path, Text);
  const Lines = Text.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
  if (Line < 0) or (Line > High(Lines)) then
    Exit;
  // LSP's UTF-16 column, as a byte column of the line
  Seek(Line, TEncoding.UTF8.GetByteCount(Lines[Line].Substring(0, Character)));
end;

procedure TQuery.Seek(Line, Col: UInt32);
begin
  Chain.Clear;
  for var D in Locals do
    D.Free;
  Locals.Clear;
  Cls := '';
  // down from the root to the identifier under the cursor, keeping the way
  N := ts_tree_root_node(Tree);
  while True do
  begin
    Chain.Add(N);
    var Next := Default(TSNode);
    for var C in Kids(N) do
    begin
      const S = ts_node_start_point(C);
      const E = ts_node_end_point(C);
      if ((S.Row < Line) or ((S.Row = Line) and (S.Column <= Col))) and
         ((E.Row > Line) or ((E.Row = Line) and (E.Column >= Col))) then
      begin
        Next := C;
        if KindOf(C) = 'identifier' then
          Break;                      // at a boundary, the name over the punctuation
      end;
    end;
    if IsNull(Next) then
      Break;
    N := Next;
  end;
  Found := (KindOf(N) = 'identifier') and (Chain.Count >= 2);
  if not Found then
    Exit;
  for var R in Chain do
    if KindOf(R) = 'defProc' then
    begin
      const H = FirstOf(R, 'declProc');
      if not IsNull(H) then
      begin
        const Nm = FirstOf(H, 'genericDot');
        if not IsNull(Nm) then
        begin
          const Parts = Txt(Src, Nm).Replace(' ', '').Split(['.']);
          if Length(Parts) >= 2 then
            Cls := Key(Parts[High(Parts) - 1]);
        end;
      end;
      const D = TDictionary<string, string>.Create;
      Locals.Add(D);
      AddLocals(Src, R, ts_node_start_byte(N), D);
    end;
end;

destructor TQuery.Destroy;
begin
  for var D in Locals do
    D.Free;
  Locals.Free;
  Chain.Free;
  if Tree <> nil then
    ts_tree_delete(Tree);
  if Parser <> nil then
    ts_parser_delete(Parser);
  inherited;
end;

function TQuery.Up: TSNode;
begin
  Result := Chain[Chain.Count - 2];
end;

function TQuery.IsMember: Boolean;
begin
  Result := Found and (KindOf(Up) = 'exprDot') and
            (ts_node_child(Up, ts_node_child_count(Up) - 1).id = N.id);
end;

function TQuery.Name: string;
begin
  Result := Txt(Src, N).ToLower;
end;

function Implementations(const Path, Text: string; Line, Character: Integer;
  WaitMs: Cardinal): TArray<TImplTarget>;
begin
  Result := nil;
  if Ready.WaitFor(WaitMs) <> wrSignaled then
    Exit;
  Lock.Enter;
  try
    const Q = TQuery.Create(Path, Text, Line, Character);
    try
      if not Q.IsMember then
        Exit;                         // a member's name: x.M with the cursor on M
      const Cls = Q.Cls;
      const Ty = Resolve(TypeOfExpr(Q.Src, ts_node_child(Q.Up, 0), Cls, Q.FileIdx, Q.Locals));
      var Info: TTypeInfo;
      if (Ty = '') or not Types.TryGetValue(Key(Ty), Info) or not Info.IsIntf then
        Exit;
      const Intf = Key(Ty);
      const M = Q.Name;
      var DI := DeclaringIntf(Intf, M);
      if DI = '' then
        Exit;
      const Recv = Args(Ty);
      const Wild: TList<string> = if (Cls <> '') and Types.ContainsKey(Cls) then Types[Cls].TParams else nil;
      const Seen = TDictionary<string, Boolean>.Create;
      try
        for var C in Implementers(Intf) do
        begin
          if (Length(Recv) > 0) and not Reaches(C, Intf, Recv, Wild, 0) then
            Continue;
          var Owner, Method: string;
          if not ImplementingMethod(C, DI, M, Owner, Method) and
             not ImplementingMethod(C, Intf, M, Owner, Method) then
            Continue;
          const KeyS = Owner + '.' + Method;
          if Seen.ContainsKey(KeyS) then
            Continue;
          Seen.Add(KeyS, True);
          var T := Default(TImplTarget);
          var P: TPlace;
          if Impls.TryGetValue(KeyS, P) then
          begin
            T.Path := Paths[P.FileIdx];
            T.Line := P.Line;
            T.Name := P.Name;
          end
          else
          begin
            // declared, no body found (abstract, or a unit not indexed): its declaration
            const OI = Types[Owner];
            T.Path := Paths[OI.FileIdx];
            if not OI.Methods.TryGetValue(Method, T.Line) then
              T.Line := OI.Line;
            T.Name := OI.Name + '.' + Method;
          end;
          Result := Result + [T];
        end;
      finally
        Seen.Free;
      end;
    finally
      Q.Free;
    end;
  finally
    Lock.Leave;
  end;
end;

{ go to definition, go to type definition }

function TargetOf(const Path: string; Line, Col: Integer; const Name: string): TImplTarget;
begin
  Result.Path := Path;
  Result.Line := Line;
  Result.Col  := Col;
  Result.Name := Name;
end;

// a type by a name as written: with its arguments (IList<T>: ilist`1), or bare, as at a cursor on
// IList in IList<T> (ilist, or failing that the generic one with the fewest parameters)
function FindType(const Name: string; out Info: TTypeInfo): Boolean;
begin
  const K = Key(Resolve(Name));
  if Types.TryGetValue(K, Info) then
    Exit( True );
  if Name.IndexOf('<') < 0 then
    for var N := 1 to 4 do
      if Types.TryGetValue(K + '`' + IntToStr(N), Info) then
        Exit( True );
  Result := False;
end;

// a unit-level name, the same way
function FindName(const Name: string; out P: TPlace): Boolean;
begin
  const K = Key(Name);
  if Names.TryGetValue(K, P) then
    Exit( True );
  if Name.IndexOf('<') < 0 then
    for var N := 1 to 4 do
      if Names.TryGetValue(K + '`' + IntToStr(N), P) then
        Exit( True );
  Result := False;
end;

// member M of Ty, or of an ancestor: a class's parent, each of an interface's
function MemberTarget(const Ty, M: string; out T: TImplTarget; Depth: Integer = 0): Boolean;
begin
  var Info: TTypeInfo;
  if (Depth > 32) or (Ty = '') or not FindType(Ty, Info) then
    Exit( False );
  var P: TPos;
  if Info.Places.TryGetValue(M, P) then
  begin
    T := TargetOf(Paths[Info.FileIdx], P.Line, P.Col, Info.Name + '.' + P.Name);
    Exit( True );
  end;
  if not Info.IsIntf then
    Exit( MemberTarget(ClassParent(Info), M, T, Depth + 1) );
  for var Pa in Info.Parents do
    if MemberTarget(Pa, M, T, Depth + 1) then
      Exit( True );
  Result := False;
end;

// a unit-level name of the workspace's: a class or interface, then any type, routine, var, const
function NameTarget(const Name: string; out T: TImplTarget): Boolean;
begin
  var Info: TTypeInfo;
  if FindType(Name, Info) then
  begin
    T := TargetOf(Paths[Info.FileIdx], Info.Line, Info.Col, Info.Name);
    Exit( True );
  end;
  var P: TPlace;
  if FindName(Name, P) then
  begin
    T := TargetOf(Paths[P.FileIdx], P.Line, P.Col, P.Name);
    Exit( True );
  end;
  Result := False;
end;

function NodeTarget(const Path: string; const Src: TBytesA; const N: TSNode): TImplTarget;
begin
  Result := TargetOf(Path, LineOf(N), ts_node_start_point(N).Column, Txt(Src, N));
end;

// where the routines around the cursor declare the name: a parameter, a var or const, an inline
// var before the cursor; the innermost routine's first
function LocalTarget(Q: TQuery; const Path: string; out T: TImplTarget): Boolean;
var
  Hit: TSNode;
  Got: Boolean;

  procedure Walk(const X: TSNode);
  begin
    for var Z in Kids(X) do
    begin
      if Got then
        Exit;
      const K = KindOf(Z);
      if K = 'defProc' then
        Continue;                     // a nested routine's own
      if (K = 'declArg') or (K = 'declVar') or (K = 'declConst') or
         ((K = 'varAssignDef') and (ts_node_start_byte(Z) < ts_node_start_byte(Q.N))) then
      begin
        for var Y in Kids(Z) do
          if (KindOf(Y) = 'identifier') and (Txt(Q.Src, Y).ToLower = Q.Name) then
          begin
            Hit := Y;
            Got := True;
            Exit;
          end;
      end
      else
        Walk(Z);
    end;
  end;

begin
  Got := False;
  for var I := Q.Chain.Count - 1 downto 0 do
    if KindOf(Q.Chain[I]) = 'defProc' then
    begin
      Walk(Q.Chain[I]);
      if Got then
        Break;
    end;
  if Got then
    T := NodeTarget(Path, Q.Src, Hit);
  Result := Got;
end;

// a type, routine, var or const the open file declares, outside routines and types: the
// editor's text, which may be newer than the index's
function UnitTarget(Q: TQuery; const Path: string; out T: TImplTarget): Boolean;

  function Find(const X: TSNode): TSNode;
  begin
    for var Z in Kids(X) do
    begin
      const K = KindOf(Z);
      if K = 'declType' then
      begin
        for var C in Kids(Z) do
          if (KindOf(C) = 'identifier') or (KindOf(C) = 'genericTpl') then
          begin
            if BaseKey(Txt(Q.Src, C)) = Q.Name then
              Exit( C );
            Break;
          end;
      end
      else if K = 'defProc' then
      begin
        const H = FirstOf(Z, 'declProc');
        if not IsNull(H) then
        begin
          const Id = FirstOf(H, 'identifier');
          if not IsNull(Id) and (Txt(Q.Src, Id).ToLower = Q.Name) then
            Exit( Id );
        end;
      end
      else if (K = 'declProc') or (K = 'declVar') or (K = 'declConst') then
      begin
        for var C in Kids(Z) do
          if (KindOf(C) = 'identifier') and (Txt(Q.Src, C).ToLower = Q.Name) then
            Exit( C );
      end
      else
      begin
        const R = Find(Z);
        if not IsNull(R) then
          Exit( R );
      end;
    end;
    Result := Default(TSNode);
  end;

begin
  const R = Find(ts_tree_root_node(Q.Tree));
  Result := not IsNull(R);
  if Result then
    T := NodeTarget(Path, Q.Src, R);
end;

// the cursor on a member's own declaration, in a class's or interface's body: that member
function DeclaredHere(Q: TQuery; const Path: string; out T: TImplTarget): Boolean;
begin
  for var I := Q.Chain.Count - 1 downto 0 do
  begin
    const K = KindOf(Q.Chain[I]);
    if K = 'defProc' then
      Exit( False );
    if K = 'declType' then
    begin
      for var C in Kids(Q.Chain[I]) do
        if (KindOf(C) = 'identifier') or (KindOf(C) = 'genericTpl') then
        begin
          Result := MemberTarget(Txt(Q.Src, C), Q.Name, T) and SameText(T.Path, Path) and
                    (T.Line = LineOf(Q.N)) and (T.Col = Integer(ts_node_start_point(Q.N).Column));
          Exit;
        end;
      Exit( False );
    end;
  end;
  Result := False;
end;

// where the name at the query's cursor is declared (the index's lock held)
function DefinitionAt(Q: TQuery; const Path: string; out T: TImplTarget): Boolean;
begin
  T := Default(TImplTarget);
  if not Q.Found then
    Exit( False );
  if Q.IsMember then
  begin
    // x.M: M of x's type; or of a type named, as TCollections.CreateList
    const L = ts_node_child(Q.Up, 0);
    var Ty := TypeOfExpr(Q.Src, L, Q.Cls, Q.FileIdx, Q.Locals);
    var Info: TTypeInfo;
    if (Ty = '') and FindType(Txt(Q.Src, L), Info) then
      Ty := Txt(Q.Src, L);
    Exit( MemberTarget(Ty, Q.Name, T) );
  end;
  if KindOf(Q.Up) = 'genericDot' then
  begin
    // TFoo.Bar, as a method's heading writes it: Bar of TFoo (a unit's name before TFoo
    // isn't a type: the name alone, below)
    var Prev := '';
    for var C in Kids(Q.Up) do
    begin
      if C.id = Q.N.id then
        Break;
      if KindOf(C) <> '.' then
        Prev := Txt(Q.Src, C);
    end;
    if (Prev <> '') and MemberTarget(Prev, Q.Name, T) then
      Exit( True );
  end;
  Result := DeclaredHere(Q, Path, T) or LocalTarget(Q, Path, T) or MemberTarget(Q.Cls, Q.Name, T) or
            UnitTarget(Q, Path, T) or NameTarget(Q.Name, T);
end;

function Definitions(const Path, Text: string; Line, Character: Integer;
  WaitMs: Cardinal): TArray<TImplTarget>;
begin
  Result := nil;
  if Ready.WaitFor(WaitMs) <> wrSignaled then
    Exit;
  Lock.Enter;
  try
    const Q = TQuery.Create(Path, Text, Line, Character);
    try
      var T: TImplTarget;
      if DefinitionAt(Q, Path, T) then
        Result := [T];
    finally
      Q.Free;
    end;
  finally
    Lock.Leave;
  end;
end;

function TypeDefinitions(const Path, Text: string; Line, Character: Integer;
  WaitMs: Cardinal): TArray<TImplTarget>;
begin
  Result := nil;
  if Ready.WaitFor(WaitMs) <> wrSignaled then
    Exit;
  Lock.Enter;
  try
    const Q = TQuery.Create(Path, Text, Line, Character);
    try
      if not Q.Found then
        Exit;
      var Ty := TypeOfExpr(Q.Src, if Q.IsMember then Q.Up else Q.N, Q.Cls, Q.FileIdx, Q.Locals);
      var Info: TTypeInfo;
      if (Ty = '') and FindType(Q.Name, Info) then
        Ty := Q.Name;                 // a type's own name
      var T := Default(TImplTarget);
      if (Ty <> '') and NameTarget(Ty, T) then
        Result := [T];
    finally
      Q.Free;
    end;
  finally
    Lock.Leave;
  end;
end;

{ find references }

function References(const Path, Text: string; Line, Character: Integer; IncludeDeclaration: Boolean;
  const TextOf: TFunc<string, string>; WaitMs: Cardinal): TArray<TImplTarget>;
var
  Name: string;
  Size: UInt32;
  Hits: TList<TSNode>;

  // every identifier of the name, by its bytes' length first
  procedure Collect(const Src: TBytesA; const X: TSNode);
  begin
    const C = ts_node_child_count(X);
    if C = 0 then
    begin
      if (ts_node_end_byte(X) - ts_node_start_byte(X) = Size) and (KindOf(X) = 'identifier') and
         (Txt(Src, X).ToLower = Name) then
        Hits.Add(X);
      Exit;
    end;
    for var I := 0 to C - 1 do
      Collect(Src, ts_node_child(X, I));
  end;

begin
  Result := nil;
  if Ready.WaitFor(WaitMs) <> wrSignaled then
    Exit;
  Lock.Enter;
  try
    var Goal: TImplTarget;
    const Q = TQuery.Create(Path, Text, Line, Character);
    try
      if not DefinitionAt(Q, Path, Goal) then
        Exit;
      Name := Q.Name;
    finally
      Q.Free;
    end;
    Size := TEncoding.UTF8.GetByteCount(Name);
    var Files := Paths.ToArray;
    if FileIndexOf(Path) < 0 then
      Files := Files + [Path];        // a file outside the index: its own uses
    var GotGoal := False;
    Hits := TList<TSNode>.Create;
    try
      for var F in Files do
      begin
        if Stopping then
          Break;
        var S := '';
        if SameText(F, Path) then
          S := Text
        else
        begin
          if Assigned(TextOf) then
            S := TextOf(F);
          if S = '' then
          try
            S := TextOfFile(F);
          except
            Continue;
          end;
        end;
        if S.ToLower.IndexOf(Name) < 0 then
          Continue;                   // not even the letters: not parsed
        const Lines = S.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
        const R = TQuery.CreateParsed(F, S);
        try
          Hits.Clear;
          Collect(R.Src, ts_tree_root_node(R.Tree));
          for var X in Hits do
          begin
            const P = ts_node_start_point(X);
            R.Seek(P.Row, P.Column);
            var T: TImplTarget;
            if not DefinitionAt(R, F, T) or not SameText(T.Path, Goal.Path) or
               (T.Line <> Goal.Line) or (T.Col <> Goal.Col) then
              Continue;
            const IsGoal = SameText(F, Goal.Path) and (Integer(P.Row) + 1 = Goal.Line) and
                           (Integer(P.Column) = Goal.Col);
            if IsGoal then
            begin
              GotGoal := True;
              if not IncludeDeclaration then
                Continue;
            end;
            var U := TargetOf(F, P.Row + 1, P.Column, '');
            if Integer(P.Row) <= High(Lines) then
              U.Name := Lines[P.Row].Trim;
            U.Len := Length(Txt(R.Src, X));
            Result := Result + [U];
          end;
        finally
          R.Free;
        end;
      end;
    finally
      Hits.Free;
    end;
    if IncludeDeclaration and not GotGoal then
    begin
      Goal.Len := Length(Name);
      Result := [Goal] + Result;      // declared where no identifier of its own shows it
    end;
  finally
    Lock.Leave;
  end;
end;

initialization
  Lock := TCriticalSection.Create;
  Ready := TEvent.Create(nil, True, True, '');     // manual reset; nothing to wait for yet
  KindNames := TDictionary<PAnsiChar, string>.Create;
  Paths := TList<string>.Create;
  Globals := TObjectList<TDictionary<string, string>>.Create;
  Types := TObjectDictionary<string, TTypeInfo>.Create([doOwnsValues]);
  Impls := TDictionary<string, TPlace>.Create;
  Funcs := TDictionary<string, string>.Create;
  ImplCache := TObjectDictionary<string, TList<string>>.Create([doOwnsValues]);
  Names := TDictionary<string, TPlace>.Create;
  Aliases := TDictionary<string, string>.Create;

finalization
  // an index still being built stops at its next file; nothing is freed under it (the IDE
  // package unloading: its thread would run on in freed memory)
  Stopping := True;
  while TInterlocked.CompareExchange(Running, 0, 0) > 0 do
    Sleep(10);
  ImplCache.Free;
  Names.Free;
  Aliases.Free;
  Funcs.Free;
  Impls.Free;
  Types.Free;
  Globals.Free;
  Paths.Free;
  KindNames.Free;
  Ready.Free;
  Lock.Free;
end.
