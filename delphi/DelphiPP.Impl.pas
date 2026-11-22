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
  override. A sketch, not a compiler: overloads told apart only by their arguments' number and the
  types it can see, no uses-clause order (a name in two units: the first indexed), no `as` or `with`, generic constraints unchecked. A file is read again
  when it is asked from, or (Reindex) saved, or read as an editor has it. }

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
  const TextOf: TFunc<string, string> = nil; WaitMs: Cardinal = 30000): TArray<TImplTarget>; overload;

type
  // how far a find references went: on a time budget it stops between units, and a call from
  // Next goes on (the user, 21 Nov: "a time budget like 0.5sec .. and then just add a list item
  // of '...' to the results, that the user could select to get more results")
  TRefsMore = record
    Next: Integer;                    // the First to go on from; -1 when every unit is read
    Read, Total: Integer;             // units gone through, of all to go through
    Common: Boolean;                  // a name in every unit (Integer, string, TObject ...): not
                                      // looked for ("We shouldn't be spending time on Integer or
                                      // String etc")
  end;

// the same, on a budget (0: none): the units from First (0: the declaration's unit, then the
// file at Path, then the rest), stopping once BudgetMs have gone; the declaration itself only
// when First is 0
function References(const Path, Text: string; Line, Character: Integer; IncludeDeclaration: Boolean;
  const TextOf: TFunc<string, string>; WaitMs, BudgetMs: Cardinal; First: Integer;
  out More: TRefsMore): TArray<TImplTarget>; overload;

// read a file of the index again, in the background: saved (Text '': as on disk), or as an
// editor has it. Each query does the same for its own file first, so the file you ask from is
// never stale
procedure Reindex(const Path: string; const Text: string = '');

implementation

uses
  System.Classes, System.IOUtils, System.Diagnostics, System.SyncObjs, System.Generics.Collections, System.Generics.Defaults, System.Hash,
  TreeSitter.Api;

type
  TBytesA = TArray<Byte>;

  TPos = record
    Line, Col: Integer;               // from 1, from 0
    Name: string;                     // as written
  end;

  // one overload of a method: its parameters' types in full, ';' between ('' none; '?' untyped),
  // how many arguments it takes, where it is declared, and how it dispatches
  TSig = record
    Params: string;
    Res: string;                      // an operator's result type: Implicit's overloads differ only there
    Min, Max: Integer;
    Line, Col: Integer;
    D: Char;
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
    Dispatch: TDictionary<string, Char>;        // a method -> 'v' virtual or dynamic, 'a' abstract,
                                                // 'o' override; none for a static method
                                                // (an overload's first)
    Sigs: TObjectDictionary<string, TList<TSig>>; // a method -> its overloads, as declared
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
  Enums: TDictionary<string, string>; // an enumeration's value -> its type, in full: ntfinally -> tsyntaxnodetype
  Owners: TDictionary<string, Integer>; // 'f:' + a function, 'a:' + an alias, 'e:' + an enum value -> the file that gave it
  Indexed: TDictionary<Integer, Integer>; // a file -> its text's hash, as indexed
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
  Dispatch := TDictionary<string, Char>.Create;
  Sigs := TObjectDictionary<string, TList<TSig>>.Create([doOwnsValues]);
end;

destructor TTypeInfo.Destroy;
begin
  Parents.Free; Methods.Free; Resolutions.Free; Members.Free; Results.Free; TParams.Free; Places.Free;
  Dispatch.Free; Sigs.Free;
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

// a heading's parameters: each name's type in full, and how many need an argument (no default).
// `procedure Put(A, B: Integer; Sep: Char = ',')` is 'integer;integer;char', 2 to 3 arguments
function SigOf(const Src: TBytesA; const Proc: TSNode): TSig;
begin
  Result := Default(TSig);
  const A = FirstOf(Proc, 'declArgs');
  if IsNull(A) then
    Exit;
  var Ts: TArray<string> := nil;
  for var Arg in Kids(A) do
    if KindOf(Arg) = 'declArg' then
    begin
      var Names := 0;
      var Ty: string := '?';          // untyped: `const X`, `var Buffer`
      var HasDefault := False;
      for var C in Kids(Arg) do
      begin
        const K = KindOf(C);
        if K = 'identifier' then
          Inc(Names)
        else if K = 'type' then
          Ty := Full(Txt(Src, C))
        else if K = 'defaultValue' then
          HasDefault := True;
      end;
      for var I := 1 to Names do
      begin
        Ts := Ts + [Ty];
        Inc(Result.Max);
        if not HasDefault then
          Inc(Result.Min);
      end;
    end;
  Result.Params := string.Join(';', Ts);
  if not IsNull(FirstOf(Proc, 'kOperator')) then
  begin
    var R := FirstOf(Proc, 'type');
    if IsNull(R) then
      R := FirstOf(Proc, 'typeref');
    if not IsNull(R) then
      Result.Res := Full(Txt(Src, R));
  end;
end;

// how an overload is keyed: '(integer;string)', an operator's with its result, '(t):integer'
function SigKey(const S: TSig): string;
begin
  Result := '(' + S.Params + ')';
  if S.Res <> '' then
    Result := Result + ':' + S.Res;
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
      // its directives, after the parameters: `virtual; abstract;`, `override;`
      var After := Txt(Src, C).ToLower;
      const Close = After.LastIndexOf(')');
      if Close >= 0 then
        After := After.Substring(Close);
      const Words = After.Split([' ', ';', ':', #9, #10, #13], TStringSplitOptions.ExcludeEmpty);
      var D := #0;
      for var W in Words do
        if (W = 'abstract') then
          D := 'a'
        else if ((W = 'virtual') or (W = 'dynamic')) and (D <> 'a') then
          D := 'v'
        else if (W = 'override') and (D = #0) then
          D := 'o';
      if D <> #0 then
        Info.Dispatch.TryAdd(Txt(Src, Name).ToLower, D);
      var S := SigOf(Src, C);
      S.Line := LineOf(C);
      S.Col := ts_node_start_point(Name).Column;
      S.D := D;
      var L: TList<TSig>;
      if not Info.Sigs.TryGetValue(Txt(Src, Name).ToLower, L) then
      begin
        L := TList<TSig>.Create;
        Info.Sigs.Add(Txt(Src, Name).ToLower, L);
      end;
      L.Add(S);
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
procedure AddAlias(FileIdx: Integer; const Src: TBytesA; const Decl: TSNode);
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
  if Aliases.TryAdd(K, Target) then
    Owners.AddOrSetValue('a:' + K, FileIdx);
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

// a plain function's result type, the first unit's
procedure AddFunc(FileIdx: Integer; const Name, Ty: string);
begin
  if Funcs.TryAdd(Name, Ty) then
    Owners.AddOrSetValue('f:' + Name, FileIdx);
end;

function HashOf(const Src: TBytesA): Integer;
begin
  Result := 0;
  if Length(Src) > 0 then
    Result := THashBobJenkins.GetHashValue(Src[0], Length(Src));
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
    AddAlias(FileIdx, Src, N);
    // `TKind = (kA, kB = 3)`: each value's type, the first unit's
    const T = FirstOf(N, 'type');
    const E = if IsNull(T) then T else FirstOf(T, 'declEnum');
    const Nm = FirstOf(N, 'identifier');
    if not IsNull(E) and not IsNull(Nm) then
      for var V in Kids(E) do
        if KindOf(V) = 'declEnumValue' then
        begin
          const Id = FirstOf(V, 'identifier');
          if not IsNull(Id) and Enums.TryAdd(Txt(Src, Id).ToLower, Full(Txt(Src, Nm))) then
            Owners.AddOrSetValue('e:' + Txt(Src, Id).ToLower, FileIdx);
        end;
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
          // and by its parameters, for an overload's own body: 'tbase.put(integer)'
          Impls.AddOrSetValue(Key(Parts[High(Parts) - 1]) + '.' + BaseKey(Parts[High(Parts)]) +
            SigKey(SigOf(Src, H)), P);
        end;
      end
      else
      begin
        const Id = FirstOf(H, 'identifier');
        const T = FirstOf(H, 'typeref');
        if not IsNull(Id) then
          AddName(FileIdx, Src, Id);  // a routine with no declaration in an interface section
        if not IsNull(Id) and not IsNull(T) and not Funcs.ContainsKey(Txt(Src, Id).ToLower) then
          AddFunc(FileIdx, Txt(Src, Id).ToLower, Full(Txt(Src, T)));
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
      AddFunc(FileIdx, Txt(Src, Id).ToLower, Full(Txt(Src, T)));
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
    // the units, then the programs (the user, 22 Nov: "we have to support .dpr"): a program's
    // own types and routines are found from inside it, and a name a unit also declares stays
    // the unit's, the first read, since no unit can use a program
    var Files: TArray<string> := nil;
    for var Mask in ['*.pas', '*.dpr'] do
      for var I := 0 to High(Deep) + Length(Flat) do
      try
        if I <= High(Deep) then
          Files := Files + TDirectory.GetFiles(Deep[I], Mask, TSearchOption.soAllDirectories)
        else
          Files := Files + TDirectory.GetFiles(Flat[I - Length(Deep)], Mask, TSearchOption.soTopDirectoryOnly);
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
      Indexed.AddOrSetValue(Idx, HashOf(Src));
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
          Paths.Clear; Globals.Clear; Types.Clear; Impls.Clear; Funcs.Clear; ImplCache.Clear; Names.Clear; Aliases.Clear; Enums.Clear; Owners.Clear; Indexed.Clear;
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
      if (K = 'defProc') or (K = 'lambda') then
        Continue;                     // a nested routine's own, an anonymous method's
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

// the file again, if its text isn't what was indexed (the lock held): what it gave out first,
// then read as Text is. A name another unit also declares stays that unit's, as in Build
procedure Refresh(const Path, Text: string);
begin
  const Idx = FileIndexOf(Path);
  if (Idx < 0) or (Text = '') then
    Exit;                             // not the index's: it never was in it
  const Src = Bytes(Text);
  const H = HashOf(Src);
  var Old: Integer;
  if Indexed.TryGetValue(Idx, Old) and (Old = H) then
    Exit;
  Indexed.AddOrSetValue(Idx, H);
  var Gone: TArray<string> := nil;
  for var Pair in Types do
    if Pair.Value.FileIdx = Idx then
      Gone := Gone + [Pair.Key];
  for var K in Gone do
    Types.Remove(K);
  Gone := nil;
  for var Pair in Impls do
    if Pair.Value.FileIdx = Idx then
      Gone := Gone + [Pair.Key];
  for var K in Gone do
    Impls.Remove(K);
  Gone := nil;
  for var Pair in Names do
    if Pair.Value.FileIdx = Idx then
      Gone := Gone + [Pair.Key];
  for var K in Gone do
    Names.Remove(K);
  Gone := nil;
  for var Pair in Owners do
    if Pair.Value = Idx then
      Gone := Gone + [Pair.Key];
  for var K in Gone do
  begin
    Owners.Remove(K);
    if K.StartsWith('f:') then
      Funcs.Remove(K.Substring(2))
    else if K.StartsWith('e:') then
      Enums.Remove(K.Substring(2))
    else
      Aliases.Remove(K.Substring(2));
  end;
  Globals[Idx].Clear;
  ImplCache.Clear;
  const Parser = ts_parser_new;
  try
    ts_parser_set_language(Parser, tree_sitter_delphi13);
    const Tree = ts_parser_parse_string(Parser, nil, PByte(Src), Length(Src));
    try
      IndexNode(Idx, Src, ts_tree_root_node(Tree), False);
    finally
      ts_tree_delete(Tree);
    end;
  finally
    ts_parser_delete(Parser);
  end;
  for var Info in Types.Values do
    for var I := 0 to Info.Parents.Count - 1 do
      Info.Parents[I] := Resolve(Info.Parents[I]);
end;

procedure Reindex(const Path, Text: string);
begin
  TInterlocked.Increment(Running);
  TThread.CreateAnonymousThread(procedure
    begin
      try
        try
          if Ready.WaitFor(60000) <> wrSignaled then
            Exit;
          var S := Text;
          if S = '' then
            S := TextOfFile(Path);
          Lock.Enter;
          try
            if not Stopping then
              Refresh(Path, S);
          finally
            Lock.Leave;
          end;
        except
          // the index as it was
        end;
      finally
        TInterlocked.Decrement(Running);
      end;
    end).Start;
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
    WasLocal: Boolean;                // the last definition found: a routine's local or parameter
    UnitDone, UnitFound: Boolean;     // UnitTarget's answer for UnitName, kept: the tree is the same
    UnitName: string;
    UnitT: TImplTarget;
    // find references: each routine's locals once, all its inline vars (not only those before
    // the name), owned here; nil for a query at a cursor
    LocalCache: TObjectDictionary<NativeUInt, TDictionary<string, string>>;
    Locals: TLocals;
    FileIdx: Integer;
    constructor Create(const Path, Text: string; Line, Character: Integer);  // parsed, and at Line, Character
    constructor CreateParsed(const Path, Text: string);
    destructor Destroy; override;
    procedure Seek(Line, Col: UInt32);  // to the name at Line, Col (from 0; Col in bytes)
    procedure SetAt(const Way: TArray<TSNode>);  // to the last of Way, the root first
    procedure Settle;                 // N and Chain set: Found, Cls, Locals
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
  Settle;
end;

procedure TQuery.SetAt(const Way: TArray<TSNode>);
begin
  Chain.Clear;
  Chain.AddRange(Way);
  N := Way[High(Way)];
  Settle;
end;

procedure TQuery.Settle;
begin
  if LocalCache = nil then
    for var D in Locals do
      D.Free;
  Locals.Clear;
  Cls := '';
  Found := (KindOf(N) = 'identifier') and (Chain.Count >= 2);
  if not Found then
    Exit;
  for var R in Chain do
    if (KindOf(R) = 'defProc') or (KindOf(R) = 'lambda') then
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
      if LocalCache <> nil then
      begin
        var D: TDictionary<string, string>;
        if not LocalCache.TryGetValue(NativeUInt(R.Id), D) then
        begin
          D := TDictionary<string, string>.Create;
          AddLocals(Src, R, High(UInt32), D);
          LocalCache.Add(NativeUInt(R.Id), D);
        end;
        Locals.Add(D);
      end
      else
      begin
        const D = TDictionary<string, string>.Create;
        Locals.Add(D);
        AddLocals(Src, R, ts_node_start_byte(N), D);
      end;
    end;
end;

destructor TQuery.Destroy;
begin
  if LocalCache = nil then
    for var D in Locals do
      D.Free;
  LocalCache.Free;
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
      if (K = 'defProc') or (K = 'lambda') then
        Continue;                     // a nested routine's own, an anonymous method's
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
    if (KindOf(Q.Chain[I]) = 'defProc') or (KindOf(Q.Chain[I]) = 'lambda') then
    begin
      Walk(Q.Chain[I]);
      if Got then
        Break;
    end;
  if Got then
    T := NodeTarget(Path, Q.Src, Hit);
  Q.WasLocal := Got;
  Result := Got;
end;

// the cursor's innermost routine is an anonymous method: there `Result` is its own, declared
// nowhere (not the outer function's `result` variable, as Spring4D's tests have)
function InLambda(Q: TQuery): Boolean;
begin
  for var I := Q.Chain.Count - 1 downto 0 do
  begin
    const K = KindOf(Q.Chain[I]);
    if K = 'lambda' then
      Exit( True );
    if K = 'defProc' then
      Exit( False );
  end;
  Result := False;
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
  if Q.UnitDone and (Q.UnitName = Q.Name) then
  begin
    T := Q.UnitT;
    Exit( Q.UnitFound );              // find references: every use of the name in this file
  end;
  const R = Find(ts_tree_root_node(Q.Tree));
  Result := not IsNull(R);
  if Result then
    T := NodeTarget(Path, Q.Src, R);
  Q.UnitDone  := True;
  Q.UnitName  := Q.Name;
  Q.UnitFound := Result;
  Q.UnitT     := T;
end;

// the cursor in a class's or interface's body, not in a routine: the type's name as declared.
// There a name is first the type's own member: a member's own declaration, a property's
// `read FService`, a method resolution's `= Run`
function TypeBody(Q: TQuery; out Name: string): Boolean;
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
          Name := Txt(Q.Src, C);
          Exit( True );
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
  Q.WasLocal := False;
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
    // TFoo.Bar, as a method's heading writes it, or IFoo.Bar in a method resolution clause: Bar
    // of TFoo (a unit's name before TFoo isn't a type: the name alone, below). The names only:
    // the dot isn't one (taken for TFoo before, so a heading's Bar was found as a member of the
    // routine's class, which is the same class, and a clause's not at all)
    var Prev := '';
    for var C in Kids(Q.Up) do
    begin
      if C.id = Q.N.id then
        Break;
      if (KindOf(C) = 'identifier') or (KindOf(C) = 'genericTpl') then
        Prev := Txt(Q.Src, C);
    end;
    if (Prev <> '') and MemberTarget(Prev, Q.Name, T) then
      Exit( True );
  end;
  var Body: string;
  if TypeBody(Q, Body) and MemberTarget(Body, Q.Name, T) then
    Exit( True );
  if (Q.Name = 'result') and InLambda(Q) then
    Exit( False );
  Result := LocalTarget(Q, Path, T) or MemberTarget(Q.Cls, Q.Name, T) or UnitTarget(Q, Path, T) or
            NameTarget(Q.Name, T);
end;

function Definitions(const Path, Text: string; Line, Character: Integer;
  WaitMs: Cardinal): TArray<TImplTarget>;
begin
  Result := nil;
  if Ready.WaitFor(WaitMs) <> wrSignaled then
    Exit;
  Lock.Enter;
  try
    Refresh(Path, Text);
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
    Refresh(Path, Text);
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

{ go to implementation }

// a method's body: the class's, or (abstract, or a unit not indexed) its declaration
function MethodTarget(const Owner, Method: string): TImplTarget;
begin
  Result := Default(TImplTarget);
  var P: TPlace;
  if Impls.TryGetValue(Owner + '.' + Method, P) then
  begin
    Result.Path := Paths[P.FileIdx];
    Result.Line := P.Line;
    Result.Name := P.Name;
  end
  else
  begin
    const OI = Types[Owner];
    Result.Path := Paths[OI.FileIdx];
    if not OI.Methods.TryGetValue(Method, Result.Line) then
      Result.Line := OI.Line;
    Result.Name := OI.Name + '.' + Method;
  end;
end;

// an overload's body; or, the method overloaded and this one's body not found (abstract, or a
// unit not indexed), its own declaration, not a sibling's body
function SigTarget(const Owner, Method: string; const S: TSig): TImplTarget;
begin
  var P: TPlace;
  if Impls.TryGetValue(Owner + '.' + Method + SigKey(S), P) then
  begin
    Result := Default(TImplTarget);
    Result.Path := Paths[P.FileIdx];
    Result.Line := P.Line;
    Result.Name := P.Name;
    Exit;
  end;
  const OI = Types[Owner];
  var L: TList<TSig>;
  if OI.Sigs.TryGetValue(Method, L) and (L.Count > 1) then
  begin
    Result := Default(TImplTarget);
    Result.Path := Paths[OI.FileIdx];
    Result.Line := S.Line;
    Result.Name := OI.Name + '.' + Method;
    Exit;
  end;
  Result := MethodTarget(Owner, Method);
end;

type
  // what tells a method's overloads apart at the cursor: a heading's or declaration's own
  // parameters (Exact), or a call's arguments, counted, each one's type where it is known
  TSel = record
    Exact: Boolean;
    Key: string;                      // with Exact: the overload's SigKey
    N: Integer;                       // the call's arguments; -1 not known
    Tys: TArray<string>;              // each one's type in full; '' not known
  end;

function NoSel: TSel;
begin
  Result := Default(TSel);
  Result.N := -1;
end;

function Family(const T: string): Char;
const
  Ints: array[0..19] of string = ('integer', 'cardinal', 'shortint', 'smallint', 'longint', 'int64',
    'uint64', 'byte', 'word', 'longword', 'fixedint', 'fixeduint', 'nativeint', 'nativeuint', 'int8',
    'int16', 'int32', 'uint8', 'uint16', 'uint32');
  Floats: array[0..6] of string = ('single', 'double', 'extended', 'real', 'currency', 'comp', 'tdatetime');
  Strs: array[0..6] of string = ('string', 'ansistring', 'widestring', 'unicodestring', 'shortstring',
    'rawbytestring', 'utf8string');
  Chars: array[0..2] of string = ('char', 'ansichar', 'widechar');
  Bools: array[0..3] of string = ('boolean', 'bytebool', 'wordbool', 'longbool');
begin
  for var W in Ints do if W = T then Exit('i');
  for var W in Floats do if W = T then Exit('f');
  for var W in Strs do if W = T then Exit('s');
  for var W in Chars do if W = T then Exit('c');
  for var W in Bools do if W = T then Exit('b');
  if (T = 'variant') or (T = 'olevariant') then Exit('v');
  Result := #0;
end;

// a class or interface A is P or below it
function Descends(const A, P: string; Depth: Integer = 0): Boolean;
begin
  if A = P then
    Exit(True);
  var Info: TTypeInfo;
  if (Depth > 32) or not Types.TryGetValue(A, Info) then
    Exit(False);
  for var Up in Info.Parents do
    if Descends(Key(Up), P, Depth + 1) then
      Exit(True);
  Result := False;
end;

// an argument of type Arg for a parameter of type Param: 2 the same, 1 it converts, 0 can't
// tell, -1 it can't be. '#char' is a one-character literal, '#nil' nil
function Fits(const Arg, Param: string): Integer;
begin
  if (Arg = '') or (Param = '') or (Param = '?') then
    Exit(0);
  if Arg = Param then
    Exit(2);
  const PF = Family(Param);
  if PF = 'v' then
    Exit(0);
  if Arg = '#char' then
    Exit(if PF = 'c' then 2 else if PF = 's' then 1 else if PF = #0 then 0 else -1);
  if Arg = '#nil' then
    Exit(if PF = #0 then 0 else -1);
  const AF = Family(Arg);
  if (AF <> #0) and (PF <> #0) then
  begin
    if AF = PF then Exit(1);
    if (AF = 'i') and (PF = 'f') then Exit(0);
    if (AF = 'c') and (PF = 's') then Exit(0);
    Exit(-1);
  end;
  const AT = Types.ContainsKey(Key(Arg));
  const PT = Types.ContainsKey(Key(Param));
  if AT and PT then
    Exit(if Descends(Key(Arg), Key(Param)) then 1 else -1);
  if ((AF <> #0) and PT) or ((PF <> #0) and AT) then
    Exit(-1);                         // a number or a string for a class, or the other way
  Result := 0;                        // an alias, a record, a type not indexed: can't tell
end;

// Info's overloads of M that Sel can mean: by an exact heading; else by the number of arguments,
// then by their types (none ruled out, the most alike). False: M has no overloads recorded
function Picked(const Info: TTypeInfo; const M: string; const Sel: TSel; out Sigs: TArray<TSig>): Boolean;
begin
  Sigs := nil;
  var L: TList<TSig>;
  if not Info.Sigs.TryGetValue(M, L) or (L.Count = 0) then
    Exit(False);
  Result := True;
  Sigs := L.ToArray;
  if L.Count = 1 then
    Exit;
  if Sel.Exact then
  begin
    var R: TArray<TSig> := nil;
    for var S in Sigs do
      if SigKey(S) = Sel.Key then
        R := R + [S];
    if R <> nil then
      Sigs := R;
    Exit;
  end;
  if Sel.N < 0 then
    Exit;
  var ByCount: TArray<TSig> := nil;
  for var S in Sigs do
    if (Sel.N >= S.Min) and (Sel.N <= S.Max) then
      ByCount := ByCount + [S];
  if ByCount = nil then
    Exit;                             // mid-edit, or arguments misread: all of them
  Sigs := ByCount;
  if Length(Sigs) = 1 then
    Exit;
  var Best := -1;
  var R: TArray<TSig> := nil;
  for var S in Sigs do
  begin
    const Ps = S.Params.Split([';']);
    var Score := 0;
    var Ok := True;
    for var I := 0 to Sel.N - 1 do
    begin
      if (I >= Length(Ps)) or (I >= Length(Sel.Tys)) then
        Break;
      const F = Fits(Sel.Tys[I], Ps[I]);
      if F < 0 then
      begin
        Ok := False;
        Break;
      end;
      Inc(Score, F);
    end;
    if not Ok then
      Continue;
    if Score > Best then
    begin
      Best := Score;
      R := [S];
    end
    else if Score = Best then
      R := R + [S];
  end;
  if R <> nil then
    Sigs := R;
end;

// the classes below C, by their first parent, each once (C not among them)
function Descendants(const C: string): TList<string>;
begin
  const CacheKey = '>' + C;
  if ImplCache.TryGetValue(CacheKey, Result) then
    Exit;
  Result := TList<string>.Create;
  const Below = TDictionary<string, Boolean>.Create;
  try
    Below.Add(C, True);
    var Changed: Boolean;
    repeat
      Changed := False;
      for var Pair in Types do
        if not Pair.Value.IsIntf and not Below.ContainsKey(Pair.Key) then
        begin
          const Up = ClassParent(Pair.Value);
          if (Up <> '') and Below.ContainsKey(Up) then
          begin
            Below.Add(Pair.Key, True);
            Result.Add(Pair.Key);
            Changed := True;
          end;
        end;
    until not Changed;
  finally
    Below.Free;
  end;
  ImplCache.Add(CacheKey, Result);
end;

// a call of M on a C: the method that runs for a C itself (its own or an ancestor's), and if
// that one is virtual (or itself an override), each override below C. An abstract one is left
// out when something overrides it. With overloads, only those Sel can mean, and below C only
// the overrides of those (by their parameters)
function ClassImplementations(const C, M: string; const Sel: TSel): TArray<TImplTarget>; overload;
begin
  Result := nil;
  var Owner, Method: string;
  if not ImplementingMethod(C, '', M, Owner, Method) then
    Exit;
  var Sigs: TArray<TSig>;
  // a heading whose parameters the indexed class lacks (a name in two units: the other unit's
  // class was indexed): the body of exactly that heading, where there is one
  if Sel.Exact then
  begin
    var L0: TList<TSig>;
    var Has := False;
    if Types[Owner].Sigs.TryGetValue(Method, L0) then
      for var S in L0 do
        if SigKey(S) = Sel.Key then
          Has := True;
    var P: TPlace;
    if not Has and Impls.TryGetValue(Owner + '.' + Method + Sel.Key, P) then
    begin
      var T := Default(TImplTarget);
      T.Path := Paths[P.FileIdx];
      T.Line := P.Line;
      T.Name := P.Name;
      Result := [T];
      Exit;
    end;
  end;
  const HasSigs = Picked(Types[Owner], Method, Sel, Sigs);
  if not HasSigs then
  begin
    var S := Default(TSig);
    if not Types[Owner].Dispatch.TryGetValue(Method, S.D) then
      S.D := #0;
    Sigs := [S];
  end;
  var OwnerCount := 1;
  var L: TList<TSig>;
  if Types[Owner].Sigs.TryGetValue(Method, L) then
    OwnerCount := L.Count;
  var Mine: TArray<TImplTarget> := nil;
  var Subs: TArray<TImplTarget> := nil;
  var Abstracts: TArray<TImplTarget> := nil;
  for var S in Sigs do
  begin
    const T = if HasSigs then SigTarget(Owner, Method, S) else MethodTarget(Owner, Method);
    if S.D <> 'a' then
      Mine := Mine + [T]
    else
      Abstracts := Abstracts + [T];
    if S.D = #0 then
      Continue;
    for var Sub in Descendants(C) do
    begin
      var SL: TList<TSig>;
      if not Types[Sub].Sigs.TryGetValue(M, SL) then
        Continue;
      var Os: TArray<TSig> := nil;
      for var O in SL do
        if (O.D = 'o') and (not HasSigs or (O.Params = S.Params)) then
          Os := Os + [O];
      if (Os = nil) and HasSigs and (OwnerCount = 1) then
        for var O in SL do           // one method above, its parameters written differently
          if O.D = 'o' then
            Os := Os + [O];
      for var O in Os do
        Subs := Subs + [SigTarget(Sub, M, O)];
    end;
  end;
  // by unit, then line: the order the units are read in, not a hash's
  TArray.Sort<TImplTarget>(Subs, TComparer<TImplTarget>.Construct(
    function(const A, B: TImplTarget): Integer
    begin
      Result := CompareText(ExtractFileName(A.Path), ExtractFileName(B.Path));
      if Result = 0 then
        Result := A.Line - B.Line;
    end));
  Result := nil;
  for var T in Mine + Subs do
  begin
    var Dup := False;
    for var X in Result do
      if (X.Line = T.Line) and SameText(X.Path, T.Path) then
        Dup := True;
    if not Dup then
      Result := Result + [T];
  end;
  if Result = nil then
    Result := Abstracts;              // abstract, overridden nowhere: its declaration
end;

function ClassImplementations(const C, M: string): TArray<TImplTarget>; overload;
begin
  Result := ClassImplementations(C, M, NoSel);
end;

// an interface method's: each class's method that implements it, of the classes that implement
// the interface (with Recv, its arguments, those that implement it so)
function InterfaceImplementations(const Intf, M: string; const Recv: TArray<string>;
  const Wild: TList<string>; const Sel: TSel): TArray<TImplTarget>;
begin
  Result := nil;
  const DI = DeclaringIntf(Intf, M);
  if DI = '' then
    Exit;
  // the interface's overloads Sel can mean: a class's methods of the same parameters implement them
  var Want: TArray<TSig>;
  if not Picked(Types[DI], M, Sel, Want) then
    Want := nil;
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
      // the interface overloaded: the class's methods of the same parameters; where the class
      // declares none of them, its nearest ancestor that does (TDerived = class(TBase) overriding
      // only Put(Integer) still runs TBase's Put(string))
      var CL: TList<TSig>;
      const IntfOverloaded = (Want <> nil) and Types[DI].Sigs.ContainsKey(M) and (Types[DI].Sigs[M].Count > 1);
      if (Want <> nil) and Types[Owner].Sigs.TryGetValue(Method, CL) and ((CL.Count > 1) or IntfOverloaded) then
      begin
        var Cs: TArray<TSig> := nil;
        var At := Owner;
        var Depth := 0;
        while (At <> '') and (Depth < 64) do
        begin
          var AL: TList<TSig>;
          if Types[At].Sigs.TryGetValue(Method, AL) then
            for var S in AL do
              for var W in Want do
                if S.Params = W.Params then
                begin
                  Cs := Cs + [S];
                  Break;
                end;
          if Cs <> nil then
            Break;
          At := ClassParent(Types[At]);
          Inc(Depth);
        end;
        if Cs = nil then
        begin
          At := Owner;
          Cs := CL.ToArray;           // parameters written differently: all of the class's
        end;
        for var S in Cs do
          if not Seen.ContainsKey(At + '.' + Method + SigKey(S)) then
          begin
            Seen.Add(At + '.' + Method + SigKey(S), True);
            Result := Result + [SigTarget(At, Method, S)];
          end;
        Continue;
      end;
      if Seen.ContainsKey(Owner + '.' + Method) then
        Continue;
      Seen.Add(Owner + '.' + Method, True);
      Result := Result + [MethodTarget(Owner, Method)];
    end;
  finally
    Seen.Free;
  end;
end;

// an argument's type, in full: literals by their kind, anything else as an expression
function ArgType(Q: TQuery; const A: TSNode): string;
begin
  const K = KindOf(A);
  const T = Txt(Q.Src, A).Trim.ToLower;
  if K = 'literalString' then
    Exit(if T.Length = 3 then '#char' else 'string');
  if K = 'literalNumber' then
    Exit(if not T.StartsWith('$') and ((T.IndexOf('.') >= 0) or (T.IndexOf('e') >= 0)) then 'double' else 'integer');
  if (T = 'nil') or (K = 'kNil') then
    Exit('#nil');
  if (T = 'true') or (T = 'false') then
    Exit('boolean');
  Result := Full(Resolve(TypeOfExpr(Q.Src, A, Q.Cls, Q.FileIdx, Q.Locals)));
  if (Result = '') and ((K = 'identifier') or (K = 'exprDot')) then
  begin
    var Ty: string;                   // ntFinally, TSyntaxNodeType.ntFinally
    if Enums.TryGetValue(BaseKey(T), Ty) then
      Result := Ty;
  end;
end;

// what at the cursor tells overloads apart: the name in a heading or a declaration (that
// overload's parameters), or in a call, x.M(a, b) or M(a, b) (its arguments); `x.M;` has none
function CallSel(Q: TQuery): TSel;
begin
  Result := NoSel;
  const C = Q.Chain.Count;
  for var I := C - 2 downto C - 3 do
    if (I >= 0) and (KindOf(Q.Chain[I]) = 'declProc') then
    begin
      Result.Exact := True;
      Result.Key := SigKey(SigOf(Q.Src, Q.Chain[I]));
      Exit;
    end;
  var Callee := Q.N;
  var I := C - 2;
  if Q.IsMember then
  begin
    Callee := Q.Up;
    Dec(I);
  end;
  if I < 0 then
    Exit;
  const P = Q.Chain[I];
  const First = ts_node_child(P, 0);
  if (KindOf(P) = 'exprCall') and (ts_node_start_byte(First) = ts_node_start_byte(Callee)) and
     (ts_node_end_byte(First) = ts_node_end_byte(Callee)) then
  begin
    Result.N := 0;
    const A = FirstOf(P, 'exprArgs');
    if not IsNull(A) then
      for var X in Kids(A) do
        if (KindOf(X) <> ',') and (KindOf(X) <> 'comment') then
        begin
          Inc(Result.N);
          Result.Tys := Result.Tys + [ArgType(Q, X)];
        end;
  end
  else if KindOf(P) <> 'exprUnary' then
    Result.N := 0                     // `x.M;`, `if M then`: called with none
  else if not Txt(Q.Src, P).TrimLeft.StartsWith('@') then
    Result.N := 0;                    // `not M`; `@M` is the method itself, any of them
end;

// x.M: on an interface, its implementing methods; on a class, the method and its overrides. And
// with no x: M called in a method of the class (Self's), M's own declaration in a class's or
// interface's body, or M in a method's heading, TFoo.M
function Implementations(const Path, Text: string; Line, Character: Integer;
  WaitMs: Cardinal): TArray<TImplTarget>;
begin
  Result := nil;
  if Ready.WaitFor(WaitMs) <> wrSignaled then
    Exit;
  Lock.Enter;
  try
    Refresh(Path, Text);
    const Q = TQuery.Create(Path, Text, Line, Character);
    try
      if not Q.Found then
        Exit;
      var TyKey := '';
      var Recv: TArray<string> := nil;
      if Q.IsMember then
      begin
        const Ty = Resolve(TypeOfExpr(Q.Src, ts_node_child(Q.Up, 0), Q.Cls, Q.FileIdx, Q.Locals));
        if Ty <> '' then
          TyKey := Key(Ty);
        Recv := Args(Ty);
      end
      else
      begin
        var Body: string;
        var T: TImplTarget;
        if TypeBody(Q, Body) then
          TyKey := Key(Body)          // a declaration: any arguments go
        else if (KindOf(Q.Up) = 'genericDot') or ((Q.Cls <> '') and not LocalTarget(Q, Path, T)) then
          TyKey := Q.Cls;             // TFoo.M's heading, or M on its own in a method of TFoo
      end;
      var Info: TTypeInfo;
      if (TyKey = '') or not Types.TryGetValue(TyKey, Info) then
        Exit;
      const Sel = CallSel(Q);
      if not Info.IsIntf then
        Exit( ClassImplementations(TyKey, Q.Name, Sel) );
      const Wild: TList<string> = if (Q.Cls <> '') and Types.ContainsKey(Q.Cls) then Types[Q.Cls].TParams else nil;
      Result := InterfaceImplementations(TyKey, Q.Name, Recv, Wild, Sel);
    finally
      Q.Free;
    end;
  finally
    Lock.Leave;
  end;
end;

{ find references }

type
  TMemo = record
    Got: Boolean;
    T: TImplTarget;
  end;

// the name as a whole word in Low (lower case): `add`, not the add of `address`
function HasWord(const Low, Name: string): Boolean;
begin
  var P := Low.IndexOf(Name);
  while P >= 0 do
  begin
    const Before = (P = 0) or not CharInSet(Low.Chars[P - 1], ['a'..'z', '0'..'9', '_']);
    const E = P + Name.Length;
    const After = (E >= Low.Length) or not CharInSet(Low.Chars[E], ['a'..'z', '0'..'9', '_']);
    if Before and After then
      Exit( True );
    P := Low.IndexOf(Name, P + 1);
  end;
  Result := False;
end;

// where a name not after a dot means one thing: its innermost routine, anonymous method or type
// declaration (1: the unit's own level)
function ScopeOf(Q: TQuery): NativeUInt;
begin
  for var I := Q.Chain.Count - 1 downto 0 do
  begin
    const K = KindOf(Q.Chain[I]);
    if (K = 'defProc') or (K = 'lambda') or (K = 'declType') then
      Exit( NativeUInt(Q.Chain[I].Id) );
  end;
  Result := 1;
end;

// the predefined types and a few classes every unit names: their uses are everywhere, and
// listing them helps no one
function IsCommon(const Name: string): Boolean;
const
  Words: array[0..53] of string = (
    'integer', 'cardinal', 'shortint', 'smallint', 'longint', 'int64', 'uint64', 'byte', 'word',
    'longword', 'fixedint', 'fixeduint', 'nativeint', 'nativeuint', 'int8', 'int16', 'int32',
    'uint8', 'uint16', 'uint32', 'boolean', 'bytebool', 'wordbool', 'longbool', 'char',
    'ansichar', 'widechar', 'string', 'ansistring', 'widestring', 'unicodestring', 'shortstring',
    'rawbytestring', 'utf8string', 'pchar', 'pansichar', 'pwidechar', 'pointer', 'single',
    'double', 'extended', 'real', 'currency', 'comp', 'variant', 'olevariant', 'tobject',
    'tclass', 'iinterface', 'iunknown', 'exception', 'tdatetime', 'tbytes', 'tarray');
begin
  for var W in Words do
    if W = Name then
      Exit( True );
  Result := False;
end;

function References(const Path, Text: string; Line, Character: Integer; IncludeDeclaration: Boolean;
  const TextOf: TFunc<string, string>; WaitMs: Cardinal): TArray<TImplTarget>;
begin
  var More: TRefsMore;
  Result := References(Path, Text, Line, Character, IncludeDeclaration, TextOf, WaitMs, 0, 0, More);
end;

function References(const Path, Text: string; Line, Character: Integer; IncludeDeclaration: Boolean;
  const TextOf: TFunc<string, string>; WaitMs, BudgetMs: Cardinal; First: Integer;
  out More: TRefsMore): TArray<TImplTarget>;
var
  Name: string;
  Local: Boolean;
  Size: UInt32;
  Hits: TList<TArray<TSNode>>;
  Way: TList<TSNode>;

  // every identifier of the name (by its bytes' length first), with the way down to it: one
  // walk of the file. Seeking each from the root, and reading its routine's locals again, cost a
  // long routine's length for every use in it (cnwizards: 16 s for one name, 3 s since)
  procedure Collect(const Src: TBytesA; const X: TSNode);
  begin
    Way.Add(X);
    const C = ts_node_child_count(X);
    if C = 0 then
    begin
      if (ts_node_end_byte(X) - ts_node_start_byte(X) = Size) and (KindOf(X) = 'identifier') and
         (Txt(Src, X).ToLower = Name) then
        Hits.Add(Way.ToArray);
    end
    else
      for var Z in Kids(X) do
        Collect(Src, Z);
    Way.Delete(Way.Count - 1);
  end;

begin
  Result := nil;
  More := Default(TRefsMore);
  More.Next := -1;
  if Ready.WaitFor(WaitMs) <> wrSignaled then
    Exit;
  Lock.Enter;
  try
    const Watch = TStopwatch.StartNew;  // from the index's being ready: its building isn't the budget's
    Refresh(Path, Text);
    var Goal: TImplTarget;
    const Q = TQuery.Create(Path, Text, Line, Character);
    try
      if not DefinitionAt(Q, Path, Goal) then
        Exit;
      Name := Q.Name;
      Local := Q.WasLocal;
    finally
      Q.Free;
    end;
    Goal.Len := Length(Name);
    if IsCommon(Name) then
    begin
      More.Common := True;
      if IncludeDeclaration and (First = 0) then
        Result := [Goal];
      Exit;
    end;
    Size := TEncoding.UTF8.GetByteCount(Name);
    // the declaration's unit first, then the one asked from, then the rest in the index's order:
    // the same each time, so that a call from Next goes on where the last stopped
    const Files = TList<string>.Create;
    try
      if Local then
        Files.Add(Path)               // a local or a parameter: its routine's file alone
      else
      begin
        Files.Add(Goal.Path);
        if not SameText(Path, Goal.Path) then
          Files.Add(Path);            // in the index or not: its own uses
        for var F in Paths do
          if not SameText(F, Goal.Path) and not SameText(F, Path) then
            Files.Add(F);
      end;
      More.Total := Files.Count;
      More.Read := Files.Count;
    var GotGoal := False;
    Hits := TList<TArray<TSNode>>.Create;
    Way := TList<TSNode>.Create;
    try
      for var I := (if First > 0 then First else 0) to Files.Count - 1 do
      begin
        if Stopping then
          Break;
        if (BudgetMs > 0) and (I > First) and (Watch.ElapsedMilliseconds >= BudgetMs) then
        begin
          More.Next := I;             // the time's up: the rest another time
          More.Read := I;
          Break;
        end;
        const F = Files[I];
        var S := '';
        if SameText(F, Path) then
          S := Text
        else
        begin
          if Assigned(TextOf) then
            S := TextOf(F);
          if S <> '' then
            Refresh(F, S)             // open in an editor, maybe edited
          else
          try
            S := TextOfFile(F);
          except
            Continue;
          end;
        end;
        if not HasWord(S.ToLower, Name) then
          Continue;                   // not even the word: not parsed
        const Lines = S.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
        const R = TQuery.CreateParsed(F, S);
        R.LocalCache := TObjectDictionary<NativeUInt, TDictionary<string, string>>.Create([doOwnsValues]);
        // a name not after a dot is the same in its whole routine: asked once there (Spring4D's,
        // jvcl's `Integer`, `S`, `Text` in every routine: seconds before)
        const Memo = TDictionary<NativeUInt, TMemo>.Create;
        try
          Hits.Clear;
          Collect(R.Src, ts_tree_root_node(R.Tree));
          for var Hit in Hits do
          begin
            const X = Hit[High(Hit)];
            const P = ts_node_start_point(X);
            R.SetAt(Hit);
            var T: TImplTarget;
            var Got: Boolean;
            if R.Found and not R.IsMember and (KindOf(R.Up) <> 'genericDot') then
            begin
              const K = ScopeOf(R);
              var M: TMemo;
              if Memo.TryGetValue(K, M) then
              begin
                Got := M.Got;
                T := M.T;
              end
              else
              begin
                Got := DefinitionAt(R, F, T);
                M.Got := Got;
                M.T := T;
                Memo.Add(K, M);
              end;
            end
            else
              Got := DefinitionAt(R, F, T);
            if not Got or not SameText(T.Path, Goal.Path) or
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
          Memo.Free;
          R.Free;
        end;
      end;
    finally
      Way.Free;
      Hits.Free;
    end;
    if IncludeDeclaration and not GotGoal and (First = 0) then
      Result := [Goal] + Result;      // declared where no identifier of its own shows it
    finally
      Files.Free;
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
  Enums := TDictionary<string, string>.Create;
  ImplCache := TObjectDictionary<string, TList<string>>.Create([doOwnsValues]);
  Names := TDictionary<string, TPlace>.Create;
  Aliases := TDictionary<string, string>.Create;
  Owners := TDictionary<string, Integer>.Create;
  Indexed := TDictionary<Integer, Integer>.Create;

finalization
  // an index still being built stops at its next file; nothing is freed under it (the IDE
  // package unloading: its thread would run on in freed memory)
  Stopping := True;
  while TInterlocked.CompareExchange(Running, 0, 0) > 0 do
    Sleep(10);
  ImplCache.Free;
  Names.Free;
  Aliases.Free;
  Owners.Free;
  Indexed.Free;
  Funcs.Free;
  Enums.Free;
  Impls.Free;
  Types.Free;
  Globals.Free;
  Paths.Free;
  KindNames.Free;
  Ready.Free;
  Lock.Free;
end.
