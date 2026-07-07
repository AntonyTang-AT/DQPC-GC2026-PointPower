# 数据集目录说明（相对 `$GC2026_ROOT`）

所有路径均相对于工作区根目录 `GC2026_ROOT`（组委会自行指定，如 `./workspace`）。

## 推理（仅需 CG）

```
data/raw/UVG-CWI-DQPC/
  <Sequence>/
    consumer-grade_capture_system/CG/15fps/*.ply
```

12 序列：`BlueSpeech` `BlueVolley` `BouncingBlue` `FitFluencer` `GoodVision` `Mannequin` `OrangeKettlebell` `PinkNoir` `TicTacToe` `TrumanShow` `VictoryHeart` `VirtualLife`

## 训练 PD-LTS 微调（需 CG + HE，9 train 序列）

Train 序列（**不含** val 三序列）：

```
data/raw/UVG-CWI-DQPC/
  BlueSpeech/consumer-grade_capture_system/CG/15fps/*.ply
  BlueSpeech/high-end_capture_system/HE/15fps/*.ply
  ...（共 9 个 train 序列，CG 与 HE 文件名一一对应，CG→HE 替换即可）
```

Train 9 序列：`BlueSpeech` `BlueVolley` `BouncingBlue` `FitFluencer` `GoodVision` `Mannequin` `OrangeKettlebell` `PinkNoir` `TicTacToe`

Val 3 序列（**不参与训练**，仅评估）：`TrumanShow` `VictoryHeart` `VirtualLife`

## 脚本生成的索引（勿手动编辑）

```
data/processed/all_cg_only_cgv2.txt           # 推理 CG 列表
data/processed/train_pairs_official_cgv2.txt  # 训练 CG/HE 对
data/processed/val_pairs_official_cgv2.txt    # val565 评估对
```

生成命令：`bash data/generate_pair_lists.sh`

## 权重（提交包内 + 可选自训）

| 用途 | 相对路径 |
|------|----------|
| 推理默认 PD-LTS | `models/DenoiseFlow-light-UVG-finetune.ckpt`（包内） |
| 自训后新权重 | `output/pdlts_finetune_uvg/run_*/DenoiseFlow-light-UVG-finetune.ckpt` |
| SuperPC | `models/kitti360_com.pth`（包内） |
| PD-LTS 官方预训练（仅训练起点） | `code/PD-LTS/product/ckpt/Denoiseflow-light-FBM.ckpt` |

推理时若存在自训权重，自动优先使用；否则使用包内 fine-tune 权重。
