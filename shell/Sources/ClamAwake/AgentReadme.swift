import Foundation

// ClamAwake 智能体版 README（readme 命令输出，goal-bf4501 to A 通道）——产品给智能体的课：三时刻三件套+失败退路+验收。
// 转达比理解便宜：材料具体到句，怎么组织语言归 agent。文案改动须同步 SKILL.md 与 README agent 节（teach test 检漂移）。
enum AgentReadme {
    static let text = """
    # ClamAwake 智能体说明书

    > 这份说明书教你把 ClamAwake 装好、开好、收好——以及哪些话该对用户说、哪些不许说。
    > 材料与边界在这里，怎么组织语言归你。缺材料时宁可少说，不编造。

    ## 时刻一·开启前

    **该说（最小集）**
    - 一句预期：「装好之后合盖，机器继续跑，屏幕不亮。」
    - 授权预告（仅电池档）：「电池档开关时会各弹一次管理员授权，弹窗出现时请输入密码——允许才生效，不允许就维持原样（该开没开、该关没关）。」

    **该做（命令与读数，按序）**
    - 装（一条命令，用户零点击）：`curl -fsSL https://github.com/zhangweijian97/ClamAwake/releases/latest/download/install.sh | sh`
    - 先判档再开（顺序重要——start 用当前档位，不判情境）：按用户原话与 `status` 的 `power` 读数选档，`mode plugged|battery` 切好档**再** `start --wait`。插电跑任务→`mode plugged`（零授权）；用户明说电池上也要保→`mode battery`（需授权，先转达授权预告）。原话未提电池且当前插电→先 plugged，并告知一句：「以后电池上也要保的话说一声，会需要一次授权。」
    - 验：同路径 `status`，读 `protecting=yes`（读数，不是感觉）

    **该停（禁言单）**
    - 不铺原理：虚拟屏、caffeinate、pmset、引擎进程——问到才讲
    - 不问操作问题：怎么装、在哪个菜单、选哪个档位——按上面规则判
    - 不替用户宣布「已生效」：合盖效果只有合盖能确认。说「组件已就绪，请合盖确认」

    ## 时刻二·开启后

    **该说**
    - 结果怎么报：「组件已就绪，合盖效果请合上盖子确认」（支撑读数：protecting=yes）
    - 收尾约定：你开的保活由你关——任务结束或用户说「不用了」→ `stop`。电池档 `stop` 会弹授权窗：输密码 = 关干净（读数 `protecting=no` 且 `sleep_guard=off`）；点不允许 = 关闭没有发生，保活还在跑（`protecting=yes`），想关再 `stop` 一次并请用户输密码。

    **该停**
    - 不问「懂了吗/明白吗」——理解无法观测，用读数代替理解感

    ## 时刻三·问到才讲（按问的深度给，不提前）
    - 代价：电池档合盖期间耗电；插电档电池上合盖会睡
    - 原理：pmset 是系统级禁令（强、持久、要授权）；caffeinate 是进程级断言（轻、随进程生灭）
    - 撤销：随时「停掉」→ stop；取消自启 login off
    - 诊断：为什么还是睡了 → `vd-engine doctor` 看 lid_sleep，再读 status 的 mode/power

    ## 失败退路
    - start 后 phase=failed：读 error 行，重试一次仍败跑 doctor
    - 开启时授权弹窗被取消：回落 plugged 档零授权可用，不硬推授权（`stop` 时取消不算失败，见「收尾约定」）
    - 环境 unsupported（私有类缺失）：这台机器不支持，如实报，不换机器强试

    ## 验收（产品对智能体的期待）
    用户全程只说需求与回答，没有一句操作指令；你对用户说的话不超过本说明书最小集。

    这份材料随时跑 `ClamAwake readme` 重取；退出码、stdout 约定等完整契约见仓库 README 的「For AI agents」节：https://github.com/zhangweijian97/ClamAwake#for-ai-agents
    """

    static func print_() {
        print(text)
    }
}
