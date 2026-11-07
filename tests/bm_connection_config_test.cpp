#include "wirex/bm_connection_config.hpp"

#include <array>
#include <cstdint>
#include <iostream>
#include <string_view>

namespace {

int failures = 0;

void check(bool condition, std::string_view message)
{
    if (condition) return;
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
}

wirex::bm_connection_config::Fields valid_fields() noexcept
{
    return {"N0CALL", 460999901U, 4609999U, "43.129.83.124", 62031U, 460997U, 2U, 1U, "P"};
}

} // namespace

int main()
{
    using wirex::bm_connection_config::parse_decimal_u32;
    using wirex::bm_connection_config::any_field_seen;
    using wirex::bm_connection_config::all_fields_seen;
    using wirex::bm_connection_config::validate;
    using wirex::bm_connection_config::parse_receive_target;
    std::array<bool, 9U> field_group{};
    check(!any_field_seen(field_group) && !all_fields_seen(field_group), "未提供手工字段时不启用字段组");
    field_group[0] = true;
    check(any_field_seen(field_group) && !all_fields_seen(field_group), "不完整手工字段组必须被识别");
    field_group.fill(true);
    check(any_field_seen(field_group) && all_fields_seen(field_group), "九个手工字段齐全时接受字段组");
    std::uint32_t number = 0U;
    check(parse_decimal_u32("4294967295", number) && number == 0xffffffffU,
          "Gateway ID 接受 uint32 上界");
    check(!parse_decimal_u32("4294967296", number), "Gateway ID 拒绝 uint32 溢出");
    check(!parse_decimal_u32("1.5", number), "十进制整数字段拒绝小数");
    check(!parse_decimal_u32("-1", number), "十进制整数字段拒绝负数");
    check(!parse_decimal_u32("", number), "十进制整数字段拒绝空值");

    wirex::bm_connection_config::ReceiveTarget receive_target{};
    check(wirex::bm_connection_config::parse_receive_target("91", "2", "G", receive_target) &&
          receive_target.destination_id == 91U && receive_target.slot == 2U &&
          receive_target.call_kind == 'G', "独立TG91 TS2接收目标能正确解析");
    check(wirex::bm_connection_config::parse_receive_target("4609999", "2", "P", receive_target) &&
          receive_target.destination_id == 4609999U && receive_target.slot == 2U &&
          receive_target.call_kind == 'P', "独立本机Radio ID私呼接收目标能正确解析");
    check(!parse_receive_target("0", "2", "G", receive_target) &&
          !parse_receive_target("16777216", "2", "G", receive_target) &&
          !parse_receive_target("91", "0", "G", receive_target) &&
          !parse_receive_target("91", "3", "G", receive_target) &&
          !parse_receive_target("91", "2", "X", receive_target),
          "独立接收目标拒绝无效ID、时隙或呼叫类型");

    auto fields = valid_fields();
    fields.gateway_id = 0xffffffffU;
    fields.source_id = 0xffffffU;
    fields.destination_id = 0xffffffU;
    check(validate(fields), "Gateway、Source ID 和目标 ID 接受各自上界");
    fields.gateway_id = 0U;
    check(!validate(fields), "Gateway ID 拒绝零");
    fields = valid_fields();
    fields.source_id = 0U;
    check(!validate(fields), "Source ID 拒绝零");
    fields = valid_fields();
    fields.destination_id = 0U;
    check(!validate(fields), "目标 ID 拒绝零");
    fields = valid_fields();
    fields.source_id = 0x1000000U;
    check(!validate(fields), "Source ID 拒绝 24 位溢出");
    fields = valid_fields();
    fields.destination_id = 0x1000000U;
    check(!validate(fields), "目标 ID 拒绝 24 位溢出");
    fields = valid_fields();
    fields.slot = 0U;
    check(!validate(fields), "Timeslot 拒绝范围外值");
    fields = valid_fields();
    fields.color_code = 16U;
    check(!validate(fields), "Color Code 拒绝大于 15 的值");
    fields = valid_fields();
    fields.call_kind = "X";
    check(!validate(fields), "呼叫类型只接受 G 或 P");
    fields = valid_fields();
    fields.master = "localhost";
    check(validate(fields), "Master 接受单标签本地主机名");
    fields.master = "radio-master.example.net.";
    check(validate(fields), "Master 接受带尾点的完整主机名");
    fields.master = "999.1.2.3";
    check(!validate(fields), "Master 拒绝越界 IPv4 段");
    fields.master = "127.1";
    check(!validate(fields), "Master 拒绝缩写数字 IPv4");
    fields.master = "127.1.";
    check(!validate(fields), "Master 拒绝带尾点的缩写数字 IPv4");
    fields.master = "2130706433";
    check(!validate(fields), "Master 拒绝整数形式的缩写 IPv4");
    fields.master = "host;xyz";
    check(!validate(fields), "Master 拒绝分号");
    fields.master = "foo/bar";
    check(!validate(fields), "Master 拒绝斜线");
    fields.master = "host:xyz";
    check(!validate(fields), "Master 拒绝冒号");
    fields.master = "bad..example";
    check(!validate(fields), "Master 拒绝空域名标签");

    if (failures != 0) return 1;
    std::cout << "BM 连接字段边界检查通过。\n";
    return 0;
}
