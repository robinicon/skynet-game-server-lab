// 由 gen_opcodes.py 生成 · 禁止手改 · 只增不改
namespace Legend3D.Protocol {
  public static class OpcodeRegistryVersion { public const uint Value = 3u; }
  public static class Channel {
    public const ushort CLI = 0x0001;
    public const ushort DB = 0x0002;
    public const ushort CROSS = 0x0003;
    public const ushort GATE = 0x0004;
    public const ushort CHAT = 0x0005;
    public const ushort AUTH = 0x0006;
  }
  public static class Opcode {
    public const uint AUTH_LOGIN_REQ = 0x00060001u;
    public const uint AUTH_LOGIN_RSP = 0x00060002u;
    public const uint AUTH_TICKET_VERIFY_REQ = 0x00060003u;
    public const uint AUTH_TICKET_VERIFY_RSP = 0x00060004u;
    public const uint CLI_HEARTBEAT = 0x00010001u;
    public const uint CLI_HEARTBEAT_ACK = 0x00010002u;
    public const uint CLI_VERSION_CHECK_REQ = 0x0001000Du;
    public const uint CLI_VERSION_CHECK_RSP = 0x0001000Eu;
    public const uint CLI_SELECT_SERVER_REQ = 0x00010003u;
    public const uint CLI_SELECT_SERVER_RSP = 0x00010004u;
    public const uint CLI_ENTER_GAME_REQ = 0x00010005u;
    public const uint CLI_ENTER_GAME_RSP = 0x00010006u;
    public const uint CLI_SYNC_PROPS = 0x00010007u;
    public const uint CLI_MOVE_REQ = 0x00010008u;
    public const uint CLI_MOVE_SYNC = 0x00010009u;
    public const uint CLI_ATTACK_REQ = 0x0001000Au;
    public const uint CLI_ATTACK_RSP = 0x0001000Bu;
    public const uint CLI_ATTACK_SYNC = 0x0001000Cu;
    public const uint DB_ROLE_LOAD_REQ = 0x00020001u;
    public const uint DB_ROLE_LOAD_RSP = 0x00020002u;
    public const uint DB_ROLE_SAVE_REQ = 0x00020003u;
    public const uint DB_ROLE_SAVE_RSP = 0x00020004u;
  }
}
