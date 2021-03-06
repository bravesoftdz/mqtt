unit mqttpackets;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Buffers, MQTTConsts;

type

  { TMQTTPacket }

  TMQTTPacket = class(TObject)
    private
      FRemainingLength: DWORD;
      function GetPacketTypeName: String;
    protected
      function Validate: Boolean; virtual;
      function ReadFromBuffer(ABuffer: TBuffer): Word; virtual; abstract;
      function GetPacketType: TMQTTPacketType; virtual; abstract;
    public
      destructor Destroy; override;
      procedure WriteToBuffer(ABuffer: TBuffer); virtual; abstract;
      //
      property PacketType: TMQTTPacketType read GetPacketType;
      property PacketTypeName: String read GetPacketTypeName;
      property RemainingLength: DWORD read FRemainingLength write FRemainingLength;
  end;

  TMQTTPacketIDPacket = class(TMQTTPacket)
    protected
      FPacketID: Word;
    public
      property PacketID: Word read FPacketID write FPacketID;
  end;

  { TMQTTQueuedPacket }

  TMQTTQueuedPacket = class(TMQTTPacketIDPacket)
    private
      FSecondsInQueue: DWORD;
      FResendCount: Byte;
    public
      property SecondsInQueue: DWORD read FSecondsInQueue write FSecondsInQueue;
      property ResendCount: Byte read FResendCount write FResendCount;
  end;

  { TMQTTPacketQueue }

  TMQTTPacketQueue = class(TObject)
    private
      FList: TList;
      function GetCount: Integer;
      function GetPacket(Index: Integer): TMQTTQueuedPacket;
    public
      constructor Create;
      destructor Destroy; override;
      //
      procedure Add(Packet: TMQTTQueuedPacket);
      function Find(PacketType: TMQTTPacketType; PacketID: Word): TMQTTQueuedPacket;
      procedure Remove(APacket: TMQTTQueuedPacket); overload;
      procedure Remove(PacketType: TMQTTPacketType; PacketID: Word); overload;
      procedure Delete(Index: Integer);
      procedure Clear;
      //
      property Items[Index: Integer]: TMQTTQueuedPacket read GetPacket; default;
      property Count: Integer read GetCount;
  end;

  { TMQTTPacketIDManager }

  TMQTTPacketIDManager = class(TObject)
    private
      FList: TList;
      function GetCount: Integer;
      function GetItem(Index: Integer): Word;
      function CheckIDExists(PacketID: Word): Boolean;
    public
      constructor Create;
      destructor Destroy; override;
      //
      function GenerateID: Word;
      procedure ReleaseID(PacketID: Word);
      procedure Reset;
      //
      property Count: Integer read GetCount;
      property Items[Index: Integer]: Word read GetItem;
  end;

function ReadWordFromBuffer(ABuffer: TBuffer; out Value: Word): Boolean;
procedure WriteWordToBuffer(ABuffer: TBuffer; const Value: Word);
function ReadUTF8StringFromBuffer(ABuffer: TBuffer; out Str: UTF8String): Boolean;
procedure WriteUTF8StringToBuffer(ABuffer: TBuffer; Str: UTF8String);
function ReadBinaryDataFromBuffer(ABuffer: TBuffer; out Data: AnsiString): Boolean;
procedure WriteBinaryDataToBuffer(ABuffer: TBuffer; Data: AnsiString);
function ReadRemainingLengthFromBuffer(ABuffer: TBuffer; out Value: DWORD): Boolean;
procedure WriteRemainingLengthToBuffer(ABuffer: TBuffer; const Value: DWORD);
function ReadMQTTPacketFromBuffer(ABuffer: TBuffer; out Packet: TMQTTPacket; Connected: Boolean = True): Word;

implementation

uses
  Sockets, LazUTF8, MQTTPacketDefs;

{ TMQTTPacketQueue }

function TMQTTPacketQueue.GetCount: Integer;
begin
  Result := FList.Count;
end;

function TMQTTPacketQueue.GetPacket(Index: Integer): TMQTTQueuedPacket;
begin
  Result := TMQTTQueuedPacket(FList[Index]);
end;

constructor TMQTTPacketQueue.Create;
begin
  inherited Create;
  FList := TList.Create;
end;

destructor TMQTTPacketQueue.Destroy;
begin
  Clear;
  FList.Destroy;
  inherited Destroy;
end;

procedure TMQTTPacketQueue.Add(Packet: TMQTTQueuedPacket);
begin
  FList.Add(Packet);
end;

function TMQTTPacketQueue.Find(PacketType: TMQTTPacketType; PacketID: Word): TMQTTQueuedPacket;
var
  I: Integer;
begin
  for I := Count - 1 downto 0 do
    begin
      Result := Items[I];
      if (Result.PacketType = PacketType) and (Result.PacketID = PacketID) then
        Exit;
    end;
  Result := nil;
end;

procedure TMQTTPacketQueue.Remove(APacket: TMQTTQueuedPacket);
begin
  FList.Remove(APacket);
end;

procedure TMQTTPacketQueue.Remove(PacketType: TMQTTPacketType; PacketID: Word);
var
  I: Integer;
  P: TMQTTQueuedPacket;
begin
  for I := Count - 1 downto 0 do
    begin
      P := Items[I];
      if (P.PacketType = PacketType) and (P.PacketID = PacketID) then
        begin
          Delete(I);
          P.Destroy;
        end;
    end;
end;

procedure TMQTTPacketQueue.Delete(Index: Integer);
begin
  FList.Delete(Index);
end;

procedure TMQTTPacketQueue.Clear;
var
  I: Integer;
begin
  for I := Count - 1 downto 0 do
    Items[I].Free;
  FList.Clear;
end;

{ TMQTTPacket }

function TMQTTPacket.GetPacketTypeName: String;
begin
  Result := MQTTPacketTypeNames[PacketType];
end;

function TMQTTPacket.Validate: Boolean;
begin
  Result := not (PacketType in [ptBROKERCONNECT,ptReserved15]);
end;

destructor TMQTTPacket.Destroy;
begin
  inherited Destroy;
end;

{ TMQTTPacketIDManager }

function TMQTTPacketIDManager.GetCount: Integer;
begin
  Result := FList.Count;
end;

function TMQTTPacketIDManager.GetItem(Index: Integer): Word;
begin
  Result := PtrUInt(FList[Index]);
end;

constructor TMQTTPacketIDManager.Create;
begin
  inherited Create;
  FList := TList.Create;
  FList.Capacity := 16;
end;

destructor TMQTTPacketIDManager.Destroy;
begin
  Reset;
  FList.Free;
  inherited Destroy;
end;

function TMQTTPacketIDManager.GenerateID: Word;
var
  P: PtrUInt;
begin
  repeat
    Result := Random($FFFE) + 1;
  until not CheckIDExists(Result);
  P := Result;
  FList.Add(Pointer(P));
end;

function TMQTTPacketIDManager.CheckIDExists(PacketID: Word): Boolean;
var
  X: Integer;
begin
  Result := False;
  for X := 0 to FList.Count - 1 do
    begin
      if Items[X] = PacketID then
        begin
          Result := True;
          Exit;
        end;
    end;
end;

procedure TMQTTPacketIDManager.ReleaseID(PacketID: Word);
var
  X: Integer;
begin
  for X := 0 to FList.Count - 1 do
    begin
      if Items[X] = PacketID then
        begin
          FList.Delete(X);
          Exit;
        end;
    end;
end;

procedure TMQTTPacketIDManager.Reset;
begin
  FList.Clear;
end;

{ Functions }

function ReadWordFromBuffer(ABuffer: TBuffer; out Value: Word): Boolean;
begin
  if ABuffer.Size >= 2 then
    begin
      ABuffer.Read(@Value,2);
      Value := htons(Value);
      Result := True;
    end
  else
    Result := False;
end;

procedure WriteWordToBuffer(ABuffer: TBuffer; const Value: Word);
var
  W: Word;
begin
  W := htons(Value);
  ABuffer.Write(@W,2);
end;

function ReadBinaryDataFromBuffer(ABuffer: TBuffer; out Data: AnsiString): Boolean;
var
  Size: Word;
begin
  if ReadWordFromBuffer(ABuffer,Size) then
    if (Size > 0) then
      if (ABuffer.Size >= Size) then
        begin
          SetLength(Data,Size);
          if ABuffer.Read(PChar(Data),Size) = Size then
            Result := True
          else
            Result := False;
        end
      else
        Result := False
    else
      Result := True
  else
    Result := False;
end;

procedure WriteBinaryDataToBuffer(ABuffer: TBuffer; Data: AnsiString);
var
  Len: Word;
begin
  Len := Length(Data);
  WriteWordToBuffer(ABuffer,Len);
  ABuffer.Write(PChar(Data),Len);
end;

function ValidateUTF8CodePoint(CP: UTF8String): Boolean;
var
  P: PChar;
  Len: Integer;
  WC: Cardinal;
begin
  P := PChar(CP);
  WC := UTF8CharacterToUnicode(P,Len);
  Result := True;
  if (WC = 0) or ((WC >= $D899) and (WC <= $DFFF)) or (WC = $FFFF) then
    Result := False;
end;

function ValidateUTF8String(Str: UTF8String): Boolean;
var
  CurP, EndP: PChar;
  Len: Integer;
  ACodePoint: String;
begin
  Result := False;
  if Str = '' then
    Result := True
  else
    begin
      CurP := PChar(Str);        // if S='' then PChar(S) returns a pointer to #0
      EndP := CurP + length(Str);
      while CurP < EndP do
        begin
          Len := UTF8CharacterLength(CurP);
          SetLength(ACodePoint, Len);
          Move(CurP^, ACodePoint[1], Len);
          if not ValidateUTF8CodePoint(ACodePoint) then Exit;
          inc(CurP, Len);
        end;
      Result := True;
    end;
end;

function ReadUTF8StringFromBuffer(ABuffer: TBuffer; out Str: UTF8String): Boolean;
var
  Size: Word;
begin
  if ReadWordFromBuffer(ABuffer,Size) then
    if (Size > 0) then
      if (ABuffer.Size >= Size) then
        begin
          SetLength(Str,Size);
          if ABuffer.Read(PChar(Str),Size) = Size then
            Result := ValidateUTF8String(Str)
          else
            Result := False;
        end
      else
        Result := False
    else
      Result := True
  else
    Result := False;
end;

procedure WriteUTF8StringToBuffer(ABuffer: TBuffer; Str: UTF8String);
var
  Len: Word;
begin
  Len := Length(Str);
  WriteWordToBuffer(ABuffer,Len);
  ABuffer.Write(PChar(Str),Len);
end;

function ReadRemainingLengthFromBuffer(ABuffer: TBuffer; out Value: DWORD): Boolean;
var
  Multiplier: DWORD;
  EncodedByte: Byte;
begin
  Multiplier := 1;
  Value := 0;
  Result := True;
  repeat
    if ABuffer.Size > 0 then
      begin
        ABuffer.Read(@EncodedByte,1);
        Value := Value + ((EncodedByte and 127) * Multiplier);
        Multiplier := Multiplier * 128;
        if (Multiplier > 128*128*128) then
          Result := False;
      end
    else
      Result := False;
  until (not Result) or ((EncodedByte and 128) = 0);
end;

procedure WriteRemainingLengthToBuffer(ABuffer: TBuffer; const Value: DWORD);
var
  EncodedByte: Byte;
  LValue: DWORD;
begin
  LValue := Value;
  repeat
    EncodedByte := LValue mod 128;
    LValue := LValue div 128;
    if LValue > 0 then
      EncodedByte := EncodedByte or 128;
    ABuffer.Write(@EncodedByte,1);
  until LValue = 0;
end;

function ValidateFlags(MT: TMQTTPacketType; Flags: Byte): Boolean;
begin
  if MT in [ptCONNECT,ptCONNACK,ptPUBACK,ptPUBREC,ptPUBCOMP,ptSUBACK,ptUNSUBACK,
            ptPINGREQ,ptPINGRESP,ptDISCONNECT] then
    Result := Flags = 0
  else
  if MT in [ptPUBREL,ptSUBSCRIBE,ptUNSUBSCRIBE] then
    Result := Flags = 2
  else
  if MT = ptPUBLISH then
    Result := True
  else
    Result := False;
end;

function PacketFactory(MT: TMQTTPacketType; Flags: Byte; RemainingLength: DWORD): TMQTTPacket;
begin
  case MT of
    ptCONNECT     : Result := TMQTTCONNECTPacket.Create;
    ptCONNACK     : Result := TMQTTCONNACKPacket.Create;
    ptPUBLISH     : Result := TMQTTPUBLISHPacket.Create;
    ptPUBACK      : Result := TMQTTPUBACKPacket.Create;
    ptPUBREC      : Result := TMQTTPUBRECPacket.Create;
    ptPUBREL      : Result := TMQTTPUBRELPacket.Create;
    ptPUBCOMP     : Result := TMQTTPUBCOMPPacket.Create;
    ptSUBSCRIBE   : Result := TMQTTSUBSCRIBEPacket.Create;
    ptSUBACK      : Result := TMQTTSUBACKPacket.Create;
    ptUNSUBSCRIBE : Result := TMQTTUNSUBSCRIBEPacket.Create;
    ptUNSUBACK    : Result := TMQTTUNSUBACKPacket.Create;
    ptPINGREQ     : Result := TMQTTPINGREQPacket.Create;
    ptPINGRESP    : Result := TMQTTPINGRESPPacket.Create;
    ptDISCONNECT  : Result := TMQTTDISCONNECTPacket.Create;
  else
    Result := nil;
  end;
  if Assigned(Result) then
    Result.RemainingLength := RemainingLength;

  if MT = ptPUBLISH then
    with Result as TMQTTPUBLISHPacket do
      begin
        Duplicate := (Flags and 8) > 0;
        QOS := TMQTTQOSType((Flags shr 1) and 3);
        Retain := (Flags and 1) > 0;
      end;

end;

function ReadMQTTPacketFromBuffer(ABuffer: TBuffer; out Packet: TMQTTPacket; Connected: Boolean = true): Word;
var
  B,Flags: Byte;
  Size: DWORD;
  PT: TMQTTPacketType;
  BackupBuffer: TBuffer;
begin
  Result := MQTT_ERROR_UNKNOWN;
  if (not Assigned(ABuffer)) or (ABuffer.Size < 2) then
    begin
      Result := MQTT_ERROR_INSUFFICIENT_DATA;
      Exit;
    end;
  BackupBuffer := TBuffer.Create;
  try
    BackupBuffer.CopyFrom(ABuffer);
    ABuffer.Read(@B,1);
    Flags := B and $0F;
    PT := TMQTTPacketType(B shr 4);
    if Connected then
      begin
        if PT = ptCONNECT then
          begin
            Result := MQTT_ERROR_ALREADY_CONNECTED;
            ABuffer.Clear;
            Exit;
          end;
      end
    else
      if (PT <> ptCONNECT) and (PT <> ptCONNACK) then
        begin
          Result := MQTT_ERROR_NOT_CONNECTED;
          ABuffer.Clear;
          Exit;
        end;
    if ValidateFlags(PT,Flags) then
      if ReadRemainingLengthFromBuffer(ABuffer,Size) then
        if Size <= ABuffer.Size then
          begin
            Packet := PacketFactory(PT,Flags,Size);
            Result := Packet.ReadFromBuffer(ABuffer);
          end
        else
          Result := MQTT_ERROR_INSUFFICIENT_DATA
      else
        Result := MQTT_ERROR_REMAINING_LENGTH_ENCODING
    else
      Result := MQTT_ERROR_INVALID_PACKET_FLAGS;
    if Result <> MQTT_ERROR_NONE then
      begin
        ABuffer.Clear;
        if Result = MQTT_ERROR_INSUFFICIENT_DATA then
          ABuffer.CopyFrom(BackupBuffer);
      end;
  finally
    BackupBuffer.Free;
  end;
end;

end.
