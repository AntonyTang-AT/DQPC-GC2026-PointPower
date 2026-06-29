# 提交包合规核查（Enhancement Only）

> 核查时间：2026-06-29  
> 官方要求来源：[UVG-CWI/submissions README](https://github.com/UVG-CWI/submissions/blob/main/README.md)

## 核查结果：**通过**

冒烟报告：[submission_verify_report.json](submission_verify_report.json)（完整日志为本地 `output/meeting_delivery/submission_verify.log`）

## 官方目录要求

| 要求 | 状态 |
|------|------|
| `README.md`（含 Team / Algorithm / Track / How to Run / Hardware / Runtime） | ✅ 已补齐 |
| `src/` 源码 | ✅ |
| `requirements.txt` | ✅ |
| **不含** PLY / 数据集 | ✅ |
| Processing Track = **Enhancement Only** | ✅ |

## 运行验证

| 项 | 结果 |
|----|------|
| 全部 `src/*.sh` 语法 | ✅ |
| 全部 `src/*.py` 编译 | ✅ |
| `verify_pdlts_ckpt.py`（Denoiseflow-light-FBM） | ✅ |
| **2 帧 val 冒烟** `src/run.sh` | ✅ 产出 2 个 ENH PLY |

冒烟输出（本地）：`output/submission_smoke_verify/`

组织者复现：

```bash
export GC2026_ROOT=/path/to/workspace
cd submissions/GC2026_Team_EnhancementOnly
bash src/run_smoke.sh    # 2 帧
bash src/run.sh          # 全量 2155 帧
```

## 已修复问题（本次核查）

1. **`GC2026_ROOT` 路径**：提交包通过 `gc2026_paths.py` 读取环境变量，不再把包目录当 workspace。
2. **README 被 manifest 生成覆盖**：已恢复符合官方模板的完整 README。
3. **双 GPU 异步**：PD-LTS 分片脚本会等待 worker 结束再计数。

## 组织者环境前置（SETUP.md）

- `export GC2026_ROOT=...`（含 `data/`、`code/PD-LTS/`）
- `conda activate superpc` + `pip install -r requirements.txt`
- `bash src/download_pdlts.sh` + `bash src/setup_pdlts_deps.sh`

## 提交物路径

- 源码目录：[submissions/GC2026_Team_EnhancementOnly/](../../submissions/GC2026_Team_EnhancementOnly/)
- 本地 tar 备份（不入库）：`output/meeting_delivery/submission/GC2026_submission_EnhancementOnly.tar.gz`
