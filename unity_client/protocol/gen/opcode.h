// 由 gen_opcodes.py 生成 · 禁止手改 · 只增不改
#pragma once
#include <cstdint>
#include <string_view>

namespace mmo {

inline constexpr uint32_t kOpcodeRegistryVersion = 3;

enum class Channel : uint16_t {
  CLI = 0x0001,
  DB = 0x0002,
  CROSS = 0x0003,
  GATE = 0x0004,
  CHAT = 0x0005,
  AUTH = 0x0006,
};

enum class Opcode : uint32_t {
  AUTH_LOGIN_REQ = 0x00060001,
  AUTH_LOGIN_RSP = 0x00060002,
  AUTH_TICKET_VERIFY_REQ = 0x00060003,
  AUTH_TICKET_VERIFY_RSP = 0x00060004,
  CLI_HEARTBEAT = 0x00010001,
  CLI_HEARTBEAT_ACK = 0x00010002,
  CLI_VERSION_CHECK_REQ = 0x0001000D,
  CLI_VERSION_CHECK_RSP = 0x0001000E,
  CLI_SELECT_SERVER_REQ = 0x00010003,
  CLI_SELECT_SERVER_RSP = 0x00010004,
  CLI_ENTER_GAME_REQ = 0x00010005,
  CLI_ENTER_GAME_RSP = 0x00010006,
  CLI_SYNC_PROPS = 0x00010007,
  CLI_MOVE_REQ = 0x00010008,
  CLI_MOVE_SYNC = 0x00010009,
  CLI_ATTACK_REQ = 0x0001000A,
  CLI_ATTACK_RSP = 0x0001000B,
  CLI_ATTACK_SYNC = 0x0001000C,
  DB_ROLE_LOAD_REQ = 0x00020001,
  DB_ROLE_LOAD_RSP = 0x00020002,
  DB_ROLE_SAVE_REQ = 0x00020003,
  DB_ROLE_SAVE_RSP = 0x00020004,
};

inline std::string_view opcode_name(uint32_t v) {
  switch (v) {
    case 0x00060001: return "AUTH_LOGIN_REQ";
    case 0x00060002: return "AUTH_LOGIN_RSP";
    case 0x00060003: return "AUTH_TICKET_VERIFY_REQ";
    case 0x00060004: return "AUTH_TICKET_VERIFY_RSP";
    case 0x00010001: return "CLI_HEARTBEAT";
    case 0x00010002: return "CLI_HEARTBEAT_ACK";
    case 0x0001000D: return "CLI_VERSION_CHECK_REQ";
    case 0x0001000E: return "CLI_VERSION_CHECK_RSP";
    case 0x00010003: return "CLI_SELECT_SERVER_REQ";
    case 0x00010004: return "CLI_SELECT_SERVER_RSP";
    case 0x00010005: return "CLI_ENTER_GAME_REQ";
    case 0x00010006: return "CLI_ENTER_GAME_RSP";
    case 0x00010007: return "CLI_SYNC_PROPS";
    case 0x00010008: return "CLI_MOVE_REQ";
    case 0x00010009: return "CLI_MOVE_SYNC";
    case 0x0001000A: return "CLI_ATTACK_REQ";
    case 0x0001000B: return "CLI_ATTACK_RSP";
    case 0x0001000C: return "CLI_ATTACK_SYNC";
    case 0x00020001: return "DB_ROLE_LOAD_REQ";
    case 0x00020002: return "DB_ROLE_LOAD_RSP";
    case 0x00020003: return "DB_ROLE_SAVE_REQ";
    case 0x00020004: return "DB_ROLE_SAVE_RSP";
    default: return "UNKNOWN";
  }
}

}  // namespace mmo
