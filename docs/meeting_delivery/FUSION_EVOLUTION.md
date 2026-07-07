# ft PD-LTS 融合线演进：Line B 与 frame_gate v2

> 回答：**为什么提交 preset 不是「全程先填充」？Line B 当时结论是什么？中间换了哪些模型、效果如何？**

---

## 1. 先澄清三个「顺序」

| 阶段 | frame_gate v2 实际顺序 | 能否改成「先填充」 |
|------|------------------------|-------------------|
| **① 神经网络** | **PD-LTS 去噪一定最先**（在 CG 上跑 ft 权重） | 不能对调：必须先有去噪几何，再谈 snap/fill |
| **② Primary refine**（ft 表面） | **snap 1.0 → fill 0.6 density** | 实验表明先 snap 再 fill 更稳（保 accuracy 再补 completeness） |
| **③ SuperPC 填洞支路** | **fill → snap**（`fill_before_snap=true`，继承 Line B 思路） | 仅 TrumanShow 等 gate 通过的帧；VH/VL **整序列跳过** |

因此：**不是「否定了 Line B」**，而是把 Line B 的「先填再 snap」**限定在 SuperPC 支路 + 门控**，Primary 仍用 snap→fill；VH/VL 上 Line B 全量应用会显著变差，故 v2 直接 skip SuperPC。

---

## 2. Line B（holefill-first）当时定了什么

**Preset**：`holefill_first_secondary_cg_hybrid_pdlts_superpc_fill0.6_post25_density`

**含义**：
- Primary：ft PD-LTS 几何
- Secondary：SuperPC blend_cg 填 CG 洞
- **`fill_before_snap=true`**：SuperPC 点 **先填入** 再 snap
- **fill 0.6 + post SOR**（std=2.5）：填完后统计去飞点

**val565 全量结果（564 帧）**：

| 指标 | ft PD-LTS only | **Line B holefill-first** | Δ (LineB − ft) |
|------|----------------|---------------------------|----------------|
| **全局 CD** | **14.883 mm** | **15.159 mm** | **+0.276 mm（更差）** |
| TrumanShow | 16.549 | 16.441 | **−0.108（TS 略好）** |
| VictoryHeart | 13.982 | 14.678 | **+0.696（VH 明显变差）** |
| VirtualLife | 14.336 | 14.525 | **+0.189（VL 略差）** |

**结论（当时分析，见 `output/ft_val565_fusion/lineb_failure_analysis.json`）**：
- **TrumanShow**：大比例 SuperPC 填洞 → completeness 提升，CD 可降（如 #0072 单帧 −0.83 mm）
- **VictoryHeart**：填得少 + **post SOR** → completeness 损失，**197/197 帧 CD 均差于 ft**
- **VirtualLife**：180/196 帧变差

→ Line B「先填再 snap」在 **TS 稀疏帧有效**，**不能全序列无脑开**；全量平均 **不如纯 ft**。

---

## 3. 中间换了哪些模型（时间线 + 数值）

基准：**CG = 17.552 mm**；**ft PD-LTS only = 14.883 mm**（无 SuperPC 融合）。

| 序号 | Preset / 名称 | 核心改动（相对上一档） | val565 CD | vs ft | 备注 |
|------|---------------|------------------------|-----------|-------|------|
| 0 | **ft PD-LTS only** | UVG ft + snap1 + fill0.6 density | **14.883** | — | 融合基线 |
| 1 | region_hybrid（冻结 PD-LTS） | 区域 mask + SuperPC | 16.502 | +1.62 | 未 ft，仅对照 |
| 2 | holefill_secondary_cg | CG 洞 mask + secondary | 16.643 | +1.76 | 早期 hybrid 失败 |
| 3 | **Line B holefill-first** | fill→snap + post SOR，fill0.6 | **15.159** | **+0.276** | TS 好、VH 差 |
| 4 | holefill_lite max10% | fill0.25、max 10% 点、adaptive post SOR | **15.128** | +0.245 | 减轻 Line B 副作用 |
| 5 | frame_gate **v1** | 逐帧 gate；架构缺陷：skip 帧输出裸 primary | **15.078** | +0.195 | 仍差于 ft |
| 6 | **frame_gate v2（提交）** | v1 + **恒 primary density** + VH/VL skip SuperPC + tier gate | **14.870** | **−0.013** | **当前最优** |

**v2 相对 ft 分序列**：

| 序列 | ft | frame_gate v2 | Δ |
|------|-----|---------------|---|
| TrumanShow | 16.549 | 16.505 | **−0.044** |
| VictoryHeart | 13.982 | 13.982 | **0.000**（与 ft 完全一致） |
| VirtualLife | 14.336 | 14.336 | **0.000** |

v2 只在 **TS 上略优于 ft**，VH/VL **不吃 SuperPC 亏**，全局略赢 0.013 mm。

---

## 4. 为什么 v2 没有「全盘采用 Line B」

1. **Primary 不能 fill-first**：ft PD-LTS 表面已较密，先 fill 再 snap 易引入 floaters；固定 **snap→fill** 与 sheet5 ft-only 一致。
2. **Line B 全量 CD 15.159 > ft 14.883**：VH 上 post SOR + 微量 fill 伤 completeness。
3. **v2 保留 Line B 精华、去掉伤害**：
   - SuperPC 支路仍 **fill→snap**（与 Line B 相同）
   - **frame_fill_gate**：`est_add_ratio` 低 → skip，避免 VH 式无效 fill
   - **VH / VL 序列级 skip**：这两序列 CD 与 ft 完全相同
   - **lite tier**：fill 0.25、max 10%，不用 full 0.6 + 强 post SOR
   - **adaptive_post_sor**：新增点 &lt; 2% 不做 SOR

**一句话**：Line B 证明「SuperPC **先填再 snap**」在 **TS 洞大的帧** 有用；v2 用 **门控 + 序列 skip** 只在有用处启用，避免 VH/VL 重蹈 Line B 全量覆辙。

---

## 5. 与「先去噪再填充」的关系

- **去噪（PD-LTS 网络）**：永远第一步，与 Line B / v2 无关。
- **填充**：
  - Primary：**snap 后 fill**（不是 Line B 顺序）
  - SuperPC：**fill 后 snap**（**就是 Line B 顺序**，但 **可选、门控**）

没有矛盾：Line B 指的是 **SuperPC 几何融合子阶段** 的顺序，不是把整个管线改成「先 fill 再跑 PD-LTS」。

---

## 6. 关键单帧例证（Line B vs ft）

| 帧 | ft CD | Line B CD | 说明 |
|----|-------|-----------|------|
| TrumanShow #0072 | 20.71 | 19.88 | Line B 大填洞，**−0.83 mm** |
| VictoryHeart #0041 | 13.18 | 14.19 | Line B **+1.01 mm**（配图帧） |
| VictoryHeart 平均 | 13.98 | 14.68 | 全序列系统性变差 |

---

*数值来源：`output/ft_val565_fusion/*/evaluation_gc_baseline_val565.json`、`lineb_failure_analysis.json`。*
