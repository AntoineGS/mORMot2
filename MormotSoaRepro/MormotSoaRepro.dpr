program MormotSoaRepro;

{
  Minimal reproduction - mORMot 2 SOA crash on Delphi 13 (RAD Studio 37),
  Linux64 target.

  An interface-based service method that returns a *managed record* as its
  *function Result* makes the server SIGSEGV when the method is invoked over
  SOA. Declaring the very same method with an *out parameter* instead works.

  The identical program compiled for Win64 runs to completion.

    Win64    -> prints both results, then "SUCCESS".
    Linux64  -> prints the ViaOutParam result, then the server worker thread
                SIGSEGVs (Runtime error 217) on the ViaFunctionResult call.

  See README.md for the gdb diagnosis (the implementation method is entered
  with a corrupt Self - the hidden result-pointer and Self are swapped for
  Delphi's Linux64 ABI).

  mORMot 2 must be reachable on the IDE library path.
}

{$APPTYPE CONSOLE}

uses
  SysUtils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.rtti,
  mormot.core.json,
  mormot.core.interfaces,
  mormot.core.log,
  mormot.orm.core,
  mormot.soa.core,
  mormot.rest.core,
  mormot.rest.memserver,
  mormot.rest.http.server,
  mormot.rest.http.client;

type
  // A managed record - it contains a RawUtf8 (ref-counted) field.
  TReproResult = record
    text: RawUtf8;
    number: Integer;
  end;

  IReproService = interface(IInvokable)
    ['{6B1D8E20-9C44-4F7A-AE3D-2F0B6C5147A9}']
    // (A) result delivered as the function Result:
    //     crashes the server on Delphi 13 / Linux64.
    function ViaFunctionResult(const input: RawUtf8): TReproResult;
    // (B) identical, but result delivered through an out parameter:
    //     works on every platform.
    procedure ViaOutParam(const input: RawUtf8; out output: TReproResult);
  end;

  TReproService = class(TInterfacedObject, IReproService)
  public
    function ViaFunctionResult(const input: RawUtf8): TReproResult;
    procedure ViaOutParam(const input: RawUtf8; out output: TReproResult);
  end;

function TReproService.ViaFunctionResult(const input: RawUtf8): TReproResult;
begin
  Result.text := 'hello ' + input;
  Result.number := 42;
end;

procedure TReproService.ViaOutParam(const input: RawUtf8; out output: TReproResult);
begin
  output.text := 'hello ' + input;
  output.number := 42;
end;

const
  PORT = '8888';
  ROOT = 'root';

procedure Run;
var
  Server: TRestServerFullMemory;
  HttpServer: TRestHttpServer;
  Client: TRestHttpClient;
  Service: IReproService;
  res: TReproResult;
begin
  TInterfaceFactory.RegisterInterfaces([TypeInfo(IReproService)]);

  Server := TRestServerFullMemory.Create(TOrmModel.Create([], ROOT));
  try
    // Shared-instance SOA registration (same form as the affected app).
    Server.ServiceRegister(TReproService.Create, [TypeInfo(IReproService)], '');
    HttpServer := TRestHttpServer.Create(PORT, [Server], '+', useHttpAsync);
    try
      SleepHiRes(500); // let the async HTTP server finish binding

      Client := TRestHttpClient.Create('127.0.0.1', PORT, TOrmModel.Create([], ROOT));
      try
        Client.ServiceDefine([IReproService], sicShared);
        Client.Services['ReproService'].Get(Service);

        Writeln('(B) ViaOutParam(...; out output)  -- expected to work everywhere');
        Service.ViaOutParam('world', res);
        Writeln('    OK   text="', res.text, '"  number=', res.number);
        Writeln;

        Writeln('(A) ViaFunctionResult(...): TReproResult  -- server SIGSEGV on Delphi/Linux64');
        res := Service.ViaFunctionResult('world');
        Writeln('    OK   text="', res.text, '"  number=', res.number);
        Writeln;
        Writeln('SUCCESS - both SOA calls returned (this is the Win64 outcome)');
      finally
        Service := nil; // release the interface before freeing its client
        Client.Free;
      end;
    finally
      HttpServer.Free;
    end;
  finally
    Server.Free;
  end;
end;

begin
  try
    Run;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, 'EXCEPTION: ', E.ClassName, ' - ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
