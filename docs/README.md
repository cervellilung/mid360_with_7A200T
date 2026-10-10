# 文档索引

**接手先读[项目总交接](项目总交接.md)，再读[长期问题记录](LONG_RUNNING_ISSUES.md)。每批实现或测试后更新总交接顶部赛题进度表；长期问题保留排查证据。**

## 主题文档

- [项目方案与联调指南](01_项目方案与联调指南.md)
- [硬件接口与协议](02_硬件接口与协议.md)
- [上板验证与采集记录](03_上板验证与采集记录.md)
- [FPGA工程构建与优化](04_FPGA工程构建与优化.md)
- [上位机与用户界面](05_上位机与用户界面.md)
- [历史方案与迁移记录](06_历史方案与迁移记录.md)
- [开发工具与规范](07_开发工具与规范.md)

## 独立规则和协议

- [仓库同步规则](AI_REPOSITORY_SYNC_RULES.md)
- [FPGA编译前检查规则](FPGA编译前检查规则.md)
- [M3TL遥测协议](telemetry_protocol.md)

## 整理规则

以后把普通更新写入对应主题文档，不再每次新建日期文件；进度仍写总交接，持续问题写LONG_RUNNING_ISSUES。源码、约束、录制和构建产物本次未移动。Markdown文档统一放在docs，本文件作为文档索引入口。

历史正文保留原日期、结论及证据；相同正文只保留一份，不把历史未完成状态或旧板卡方案冒充当前状态。原Markdown压缩备份见根README。

## 旧文件名到新章节

总交接和长期问题记录逐字保留，因此其中引用已归并文件的历史链接仍是旧路径；请在下表查旧文件名并进入新章节，不将它们视为现行独立文件。机器可读映射见[文档合并记录](文档合并记录_2026-10-03.json)。

| 原位置（相对docs） | 现入口 |
|---|---|
| `AC880继续修复交接_2026-10-03.md` | [FPGA工程构建与优化](04_FPGA工程构建与优化.md#doc-001) |
| `AC880资源与时序优化_2026-10-02.md` | [FPGA工程构建与优化](04_FPGA工程构建与优化.md#doc-002) |
| `ACX750待办清单.md` | [项目方案与联调指南](01_项目方案与联调指南.md#doc-001) |
| `ACX750通信版HDMI离线改造_2026-10-01.md` | [FPGA工程构建与优化](04_FPGA工程构建与优化.md#doc-003) |
| `ACX750通信版上板记录_2026-10-01.md` | [上板验证与采集记录](03_上板验证与采集记录.md#doc-001) |
| `AI_HANDOFF.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-001) |
| `FPGA与嵌入式桌面开发规范.md` | [开发工具与规范](07_开发工具与规范.md#doc-001) |
| `Full存储结构优化_2026-10-02.md` | [FPGA工程构建与优化](04_FPGA工程构建与优化.md#doc-004) |
| `HDMI工程标准结构整理_2026-10-02.md` | [FPGA工程构建与优化](04_FPGA工程构建与优化.md#doc-005) |
| `HDMI迁移交接_2026-10-01.md` | [FPGA工程构建与优化](04_FPGA工程构建与优化.md#doc-006) |
| `LAST_SESSION_SUMMARY.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-002) |
| `MIGRATION_HANDOFF.md` | [FPGA工程构建与优化](04_FPGA工程构建与优化.md#doc-007) |
| `PROJECT_STATUS.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-003) |
| `results/delegations/20260923T055313Z_pc-ar-todo/result.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-004) |
| `results/delegations/20260923T085009Z_mid-360-ac880-zynq-ps-udp-pl-ov5640-/result.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-005) |
| `results/delegations/20260923T093358Z_ac880-xc7z020-zynq-ps-gem0-lwip-udp-/result.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-006) |
| `Route_Design专项审计_2026-10-01.md` | [FPGA工程构建与优化](04_FPGA工程构建与优化.md#doc-008) |
| `routine/acx750_full_docs/asset_inventory_880.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-001) |
| `routine/acx750_full_docs/bringup_checklist.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-002) |
| `routine/acx750_full_docs/chassis_750.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-003) |
| `routine/acx750_full_docs/control_plane_750.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-004) |
| `routine/acx750_full_docs/final_status_2026-10-01.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-005) |
| `routine/acx750_full_docs/known_gaps.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-006) |
| `routine/acx750_full_docs/m3tl_full_tx_750.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-007) |
| `routine/acx750_full_docs/m3tl_targets_750.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-008) |
| `routine/acx750_full_docs/migration_ac880_to_acx750.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-009) |
| `routine/acx750_full_docs/pin_hunt_uart_gpio.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-010) |
| `routine/acx750_full_docs/pinout_acx750.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-011) |
| `routine/acx750_full_docs/ported_perception_modules.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-012) |
| `routine/acx750_full_docs/recon_880_perception.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-013) |
| `routine/acx750_full_docs/recon_880_top.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-014) |
| `routine/acx750_full_docs/udp_rx_750.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-015) |
| `routine/acx750_full_docs/vendor_sources.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-016) |
| `routine/acx750_full_docs/video_pipeline_750.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-017) |
| `routine/references/README.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-018) |
| `tools/README_GLM_DELEGATE.md` | [开发工具与规范](07_开发工具与规范.md#doc-002) |
| `vivado_project/source_snapshot/fpga_acx750/constraints/README.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-019) |
| `vivado_project/source_snapshot/fpga_acx750/constraints/REVIEW.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-020) |
| `vivado_project/source_snapshot/fpga_acx750/docs/bringup_checklist.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-021) |
| `vivado_project/source_snapshot/fpga_acx750/docs/known_gaps.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-022) |
| `vivado_project/source_snapshot/fpga_acx750/docs/migration_ac880_to_acx750.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-009) |
| `vivado_project/source_snapshot/fpga_acx750/docs/pinout_acx750.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-023) |
| `vivado_project/source_snapshot/fpga_acx750/docs/vendor_sources.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-016) |
| `vivado_project/source_snapshot/fpga_acx750/host/README.md` | [上位机与用户界面](05_上位机与用户界面.md#doc-001) |
| `vivado_project/source_snapshot/fpga_acx750/README.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-024) |
| `vivado_project/source_snapshot/fpga_acx750/scripts/README.md` | [FPGA工程构建与优化](04_FPGA工程构建与优化.md#doc-009) |
| `vivado_project/source_snapshot/fpga_acx750/sim/README.md` | [FPGA工程构建与优化](04_FPGA工程构建与优化.md#doc-010) |
| `vivado_project/source_snapshot/fpga_acx750_full/constraints/README.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-025) |
| `vivado_project/source_snapshot/fpga_acx750_full/constraints/REVIEW.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-026) |
| `vivado_project/source_snapshot/fpga_acx750_full/docs/asset_inventory_880.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-001) |
| `vivado_project/source_snapshot/fpga_acx750_full/docs/bringup_checklist.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-002) |
| `vivado_project/source_snapshot/fpga_acx750_full/docs/chassis_750.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-003) |
| `vivado_project/source_snapshot/fpga_acx750_full/docs/control_plane_750.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-004) |
| `vivado_project/source_snapshot/fpga_acx750_full/docs/final_status_2026-10-01.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-005) |
| `vivado_project/source_snapshot/fpga_acx750_full/docs/known_gaps.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-006) |
| `vivado_project/source_snapshot/fpga_acx750_full/docs/m3tl_full_tx_750.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-007) |
| `vivado_project/source_snapshot/fpga_acx750_full/docs/m3tl_targets_750.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-008) |
| `vivado_project/source_snapshot/fpga_acx750_full/docs/migration_ac880_to_acx750.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-009) |
| `vivado_project/source_snapshot/fpga_acx750_full/docs/pin_hunt_uart_gpio.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-010) |
| `vivado_project/source_snapshot/fpga_acx750_full/docs/pinout_acx750.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-011) |
| `vivado_project/source_snapshot/fpga_acx750_full/docs/ported_perception_modules.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-012) |
| `vivado_project/source_snapshot/fpga_acx750_full/docs/recon_880_perception.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-013) |
| `vivado_project/source_snapshot/fpga_acx750_full/docs/recon_880_top.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-014) |
| `vivado_project/source_snapshot/fpga_acx750_full/docs/udp_rx_750.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-015) |
| `vivado_project/source_snapshot/fpga_acx750_full/docs/vendor_sources.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-016) |
| `vivado_project/source_snapshot/fpga_acx750_full/docs/video_pipeline_750.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-017) |
| `vivado_project/source_snapshot/fpga_acx750_full/host/README.md` | [上位机与用户界面](05_上位机与用户界面.md#doc-002) |
| `vivado_project/source_snapshot/fpga_acx750_full/PROJECT_HANDOFF.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-027) |
| `vivado_project/source_snapshot/fpga_acx750_full/README.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-028) |
| `vivado_project/source_snapshot/fpga_acx750_full/scripts/README.md` | [FPGA工程构建与优化](04_FPGA工程构建与优化.md#doc-011) |
| `vivado_project/source_snapshot/fpga_acx750_full/sim/README.md` | [FPGA工程构建与优化](04_FPGA工程构建与优化.md#doc-012) |
| `vivado_project/source_snapshot/mid360_pc_fpga/fpga_ac880/sensor_capture_linux/BOARD_VALIDATION_STATUS.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-007) |
| `vivado_project/source_snapshot/mid360_pc_fpga/fpga_ac880/sensor_capture_linux/CAMERA_MOUNT_NOTES.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-008) |
| `vivado_project/source_snapshot/mid360_pc_fpga/fpga_ac880/sensor_capture_linux/PROJECT_HANDOFF.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-009) |
| `vivado_project/source_snapshot/mid360_pc_fpga/fpga_ac880/sensor_capture_linux/README.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-010) |
| `vivado_project/source_snapshot/mid360_pc_fpga/fpga_ac880/sensor_perception_ar/BOARD_VALIDATION_STATUS.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-011) |
| `vivado_project/source_snapshot/mid360_pc_fpga/fpga_ac880/sensor_perception_ar/PROJECT_HANDOFF.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-012) |
| `vivado_project/source_snapshot/mid360_pc_fpga/fpga_ac880/sensor_perception_ar/PROTOCOL.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-013) |
| `vivado_project/source_snapshot/mid360_pc_fpga/fpga_ac880/sensor_perception_ar/README.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-014) |
| `web_server/car_showcase/README.md` | [上位机与用户界面](05_上位机与用户界面.md#doc-003) |
| `web_server/README.md` | [上位机与用户界面](05_上位机与用户界面.md#doc-002) |
| `上板逐项测试记录_2026-10-02.md` | [上板验证与采集记录](03_上板验证与采集记录.md#doc-002) |
| `下一步工作计划_2026-10-02.md` | [项目方案与联调指南](01_项目方案与联调指南.md#doc-002) |
| `千兆网口RX修复_2026-10-02.md` | [上板验证与采集记录](03_上板验证与采集记录.md#doc-003) |
| `厂商基线网口重建_2026-10-02.md` | [上板验证与采集记录](03_上板验证与采集记录.md#doc-004) |
| `历史根目录说明.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-015) |
| `原始雷达转发录制_2026-10-03.md` | [上板验证与采集记录](03_上板验证与采集记录.md#doc-005) |
| `双工程HDMI候选bit验收_2026-10-02.md` | [上板验证与采集记录](03_上板验证与采集记录.md#doc-006) |
| `双工程HDMI链路测试_2026-10-01.md` | [上板验证与采集记录](03_上板验证与采集记录.md#doc-007) |
| `存储结构修复交接_2026-10-01.md` | [FPGA工程构建与优化](04_FPGA工程构建与优化.md#doc-013) |
| `当前项目方案_2026-09-29.md` | [项目方案与联调指南](01_项目方案与联调指南.md#doc-003) |
| `旧项目/2026-10-01_目录整理/fpga_ac880/README.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-016) |
| `旧项目/2026-10-01_目录整理/fpga_ac880/sensor_capture_linux/BOARD_VALIDATION_STATUS.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-007) |
| `旧项目/2026-10-01_目录整理/fpga_ac880/sensor_capture_linux/CAMERA_MOUNT_NOTES.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-008) |
| `旧项目/2026-10-01_目录整理/fpga_ac880/sensor_capture_linux/PROJECT_HANDOFF.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-009) |
| `旧项目/2026-10-01_目录整理/fpga_ac880/sensor_capture_linux/README.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-010) |
| `旧项目/2026-10-01_目录整理/fpga_ac880/sensor_perception_ar/BOARD_VALIDATION_STATUS.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-011) |
| `旧项目/2026-10-01_目录整理/fpga_ac880/sensor_perception_ar/PROJECT_HANDOFF.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-012) |
| `旧项目/2026-10-01_目录整理/fpga_ac880/sensor_perception_ar/PROTOCOL.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-013) |
| `旧项目/2026-10-01_目录整理/fpga_ac880/sensor_perception_ar/README.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-014) |
| `旧项目/2026-10-01_目录整理/fpga_ac880/sw/telemetry/README.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-017) |
| `旧项目/2026-10-01_目录整理/fpga_acx750/constraints/README.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-019) |
| `旧项目/2026-10-01_目录整理/fpga_acx750/constraints/REVIEW.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-020) |
| `旧项目/2026-10-01_目录整理/fpga_acx750/docs/bringup_checklist.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-021) |
| `旧项目/2026-10-01_目录整理/fpga_acx750/docs/known_gaps.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-022) |
| `旧项目/2026-10-01_目录整理/fpga_acx750/docs/migration_ac880_to_acx750.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-009) |
| `旧项目/2026-10-01_目录整理/fpga_acx750/docs/pinout_acx750.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-023) |
| `旧项目/2026-10-01_目录整理/fpga_acx750/docs/vendor_sources.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-016) |
| `旧项目/2026-10-01_目录整理/fpga_acx750/host/README.md` | [上位机与用户界面](05_上位机与用户界面.md#doc-001) |
| `旧项目/2026-10-01_目录整理/fpga_acx750/README.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-018) |
| `旧项目/2026-10-01_目录整理/fpga_acx750/scripts/README.md` | [FPGA工程构建与优化](04_FPGA工程构建与优化.md#doc-009) |
| `旧项目/2026-10-01_目录整理/fpga_acx750/sim/README.md` | [FPGA工程构建与优化](04_FPGA工程构建与优化.md#doc-010) |
| `旧项目/2026-10-01_目录整理/fpga_acx750_full/constraints/README.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-025) |
| `旧项目/2026-10-01_目录整理/fpga_acx750_full/constraints/REVIEW.md` | [硬件接口与协议](02_硬件接口与协议.md#doc-026) |
| `旧项目/2026-10-01_目录整理/fpga_acx750_full/PROJECT_HANDOFF.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-019) |
| `旧项目/2026-10-01_目录整理/fpga_acx750_full/README.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-020) |
| `旧项目/2026-10-01_目录整理/fpga_acx750_full/scripts/README.md` | [FPGA工程构建与优化](04_FPGA工程构建与优化.md#doc-011) |
| `旧项目/2026-10-01_目录整理/fpga_acx750_full/sim/README.md` | [FPGA工程构建与优化](04_FPGA工程构建与优化.md#doc-012) |
| `旧项目/fpga_ac880/camera_tft_chassis/README.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-021) |
| `旧项目/fpga_ac880/pl_eth_mid360/MID360_STARTUP_POLICY.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-022) |
| `旧项目/fpga_ac880/pl_eth_mid360/README.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-023) |
| `旧项目/fpga_ac880/pl_mid360_point_parser/MID360_STARTUP_POLICY.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-022) |
| `旧项目/fpga_ac880/pl_mid360_point_parser/README.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-024) |
| `旧项目/fpga_ac880/ps_udp_heartbeat/README.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-025) |
| `旧项目/fpga_ac880/sensor_capture_ps/BOARD_VALIDATION_STATUS.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-026) |
| `旧项目/fpga_ac880/sensor_capture_ps/PROJECT_HANDOFF.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-027) |
| `旧项目/fpga_ac880/sensor_capture_ps/README.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-028) |
| `旧项目/fpga_ac880/sensor_capture_ps/REVIEW_SUMMARY.md` | [历史方案与迁移记录](06_历史方案与迁移记录.md#doc-029) |
| `时序修复归档_2026-10-01.md` | [FPGA工程构建与优化](04_FPGA工程构建与优化.md#doc-014) |
| `目录与材料索引说明.md` | [项目方案与联调指南](01_项目方案与联调指南.md#doc-004) |
| `相机屏幕排查_2026-10-03.md` | [上板验证与采集记录](03_上板验证与采集记录.md#doc-008) |
| `系统联调架构_树莓派5.md` | [项目方案与联调指南](01_项目方案与联调指南.md#doc-005) |
| `编译监视器.md` | [开发工具与规范](07_开发工具与规范.md#doc-003) |
| `网口遥测MAC学习修复_2026-10-03.md` | [上板验证与采集记录](03_上板验证与采集记录.md#doc-009) |
| `联调清单.md` | [项目方案与联调指南](01_项目方案与联调指南.md#doc-006) |

## 保留的旧长期问题记录

- [旧项目/2026-10-01_目录整理/fpga_ac880/sensor_capture_linux/LONG_RUNNING_ISSUES.md](旧项目/2026-10-01_目录整理/fpga_ac880/sensor_capture_linux/LONG_RUNNING_ISSUES.md)
- [vivado_project/source_snapshot/mid360_pc_fpga/fpga_ac880/sensor_perception_ar/LONG_RUNNING_ISSUES.md](vivado_project/source_snapshot/mid360_pc_fpga/fpga_ac880/sensor_perception_ar/LONG_RUNNING_ISSUES.md)
- [旧项目/2026-10-01_目录整理/fpga_ac880/sensor_perception_ar/LONG_RUNNING_ISSUES.md](旧项目/2026-10-01_目录整理/fpga_ac880/sensor_perception_ar/LONG_RUNNING_ISSUES.md)
- [旧项目/fpga_ac880/sensor_capture_ps/LONG_RUNNING_ISSUES.md](旧项目/fpga_ac880/sensor_capture_ps/LONG_RUNNING_ISSUES.md)
- [vivado_project/source_snapshot/mid360_pc_fpga/fpga_ac880/sensor_capture_linux/LONG_RUNNING_ISSUES.md](vivado_project/source_snapshot/mid360_pc_fpga/fpga_ac880/sensor_capture_linux/LONG_RUNNING_ISSUES.md)

