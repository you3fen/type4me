# Codex handoff: build the existing Dev identity and hand over for manual testing

这是已授权的个人 fork A 方案后续构建任务，不是重新调研或重构。
只允许 `you3fen/type4me` 的 `feat/personal-dictation`；不写上游、main、
旧 PR 来源分支，不重复应用 #303/#309/#310，不强制推送。

1. 读取本分支最新提交及 `PLAN-A.md`，核对 CI 的被测 SHA、原始日志和
   源码 manifest。用户交接的 SHA 是核验锚点，不要盲目覆盖后来新增工作。
   若上一阶段留下待验证的补丁/工作流，只在独立 worktree 核验并完成它，
   不把 staging 提交当作已经通过测试的产品。已有最终产品提交则不要再套补丁。
2. 先检查本机已有工作与已安装的 **Dev App**。记录其实际路径、名称、
   Bundle ID、URL scheme、签名身份、designated requirement、偏好域及数据
   目录。不要猜测 App 名，也不要因为构建方便改成全新 Personal 身份。
   不打印或上传密钥、真实词库/历史/偏好导出，备份只留本机且限制权限。
3. 在独立、干净 worktree 构建该确切提交。测试使用隔离的
   `CFFIXED_USER_HOME`、临时 DB 和测试词表，不启动真实 App、不读真实钥匙串、
   不调用 ASR/LLM 或付费模型。至少跑新 Plan A 测试、已有 reference、词汇、
   destination、provenance、backup、namespace 和相关 session 测试。
   构建条件为 `TYPE4ME_PERSONAL_BUILD=1 TYPE4ME_DEV_BUILD=1`。
   如有真实编译/测试问题，修复根因并重测；不要删除断言或默默扩大功能范围。
4. 使用 `scripts/package-app.sh` **先打包到临时 staging 路径**，不使用
   `package-personal.sh`、生产 deploy 脚本或会立即安装的 dev-run 默认流程。
   同时保留上述两个编译标志，`APP_FLAVOR=public VARIANT=cloud ARCH=universal`，
   APP_NAME、APP_BUNDLE_ID、URL_SCHEME、CODESIGN_IDENTITY 均取本机现有 Dev
   的实际值，APP_PATH 指向 staging，APP_BUILD 使用不冲突的新 Dev build。
   保留现有可选能力需求，不擅自改正在使用的 worktree/capability markers。
5. 校验 universal 架构、版本、实际 Bundle ID、签名及 requirement。
   代码预期共享 `~/Library/Application Support/Type4Me/` 与 `com.type4me`
   凭据前缀；UserDefaults 继续是既有 Dev Bundle 域，不能导入 production
   偏好代替它。签名证书不可用或 identity 不一致时停止在 staging，说明具体
   阻塞；不重置钥匙串/权限，不生成新身份冒充兼容替换。
6. 签名与备份校验通过后，退出会共享数据的 stable/Dev，备份旧 Dev App、
   shared data（包括 correction-references.json，SQLite 用一致性备份）与
   相关偏好域，再**仅替换原 Dev App**。不替换 stable，不修改/批量迁移真实
   词库、历史、模型配置或凭据。保留完整回退路径。
7. 交给用户实际录音和界面验收，不代替用户调用付费模型测试，不宣称离线
   mock 证明了识别准确率。报告实际提交 SHA、测试结果、App 路径/构建号、
   签名与数据共享校验、备份路径，以及仍未验证项目。

## Manual acceptance (user, not unattended agent)

- 已有历史、热词、模型选择和 API 配置仍在；不要求重新积累或配置。
- 快速原文仍可使用既有“我的邮箱”等明确快捷展开，不新增润色调用。
- 智能感知下手动确认一个名称，下次相同错写能提供对应参考；跨 App 仅在
  用户明确选择共享之后复用。不同错写没有证据时不冒称已学会。
- 历史纠错默认为正确名称；显式选全局替换后，同触发词旧值可以更新。
- 在热词页改名，确认参考同步；删名称会提示联动范围，快捷展开不被删除。
- 新词排在 20 个词之后，出现可识别的相关文字/已确认错写时能进入受限参考。
- 真实名称 Cortex/Typeform、否定句、引用、路径、数字不被无关改写；对照
  必须记录 ASR 原文与最终输出，区分旧强制规则、模型候选和 guard 回退。
- 记录真实首字/结束等待体感及必要耗时；不把引用/否定保护测试说成全语义保证。
