# MoonBit 复音合成器项目申报书

## 一、项目名称

moonsynth：MoonBit 复音合成器（浏览器端 wasm DSP）

## 二、项目说明

合成器由 DSP 库、wasm 内核与 Web 宿主三部分构成。本项目（0.1.0）以 MoonBit 实现 DSP 库与内核：PolyBLEP 抗混叠振荡器（锯齿/方波断点两样本多项式修正，正弦、三角为朴素实现）、RBJ 双二阶滤波（LP/HP/BP，系数仅参数变化时重算）、线性 ADSR（释放速率在 gate-off 时刻锁定）、双环形缓冲乒乓延迟与 8 声部管理（同音重触、空闲声部复用、最老声部偷取）。内核为 wasm foreign_library，逐块渲染交织立体声样本写入导出线性内存，控制事件为普通导出函数调用，声部、暂存缓冲、延迟环全部预分配，渲染路径零分配。宿主为 AudioWorklet：主线程编译 wasm 字节经 MessagePort 送入音频线程实例化，每帧取音一次、拷贝一次，60 Hz 计时。

## 三、核心功能

- 完整信号链：双振荡器（波形/失谐分/混合）→ 声部求和 → 全局滤波（LP/HP/BP + 共振 Q）→ 主控 → 乒乓延迟（左右交替回声，反馈 0–0.9，回声间隔至 1 秒）→ 立体声输出。
- 8 复音与声部策略：按音符重触、空闲声部优先、最老声部偷取；`voice_count` 每半秒回报 UI。
- 16 个参数即时生效：振荡器波形与失谐（分）、滤波类型/截止/共振、ADSR 四段、延迟时间/反馈/湿度、主控增益；包络参数对已发声声部同步，释放从起始电平线性下降不产生爆音。
- 确定性自检：页面内置离线渲染自检，攻击段 RMS 0.2531（>0.02）、释放后 RMS 0.00000（<0.001）、C4 正弦过零率 270/秒（理论 261.6）；Node 端内核测试 10 项含 C4 实测 258.4 Hz（含 −7 音分失谐）。
- 吞吐：8 复音全响渲染 10 秒立体声 113.9 毫秒，实时余量约 88 倍。
- 控制台 UI：13 个可拖拽旋钮（对数/线性曲线、双击复位）、5 组预置音色、屏上 25 键 + 计算机键盘（A W S E D…，Z/X 切八度）、示波器与对数频谱、PANIC 立即静音。

## 四、预期使用场景

**场景一：浏览器演奏。** `moon build --target wasm --release`、`cp _build/wasm/release/build/src/kernel/kernel.wasm web/synth.wasm`、`node web/server.mjs 8090` 后打开页面，点「启动音频」（浏览器要求一次用户手势）→ 选预置音色 → 计算机键盘直接弹奏，`Z`/`X` 切换八度，拖动旋钮实时改音色。

**场景二：无耳自动验证。** `node web/test-kernel.mjs` 在无浏览器环境下对 wasm 内核跑 10 项断言：未发声时静音、C4 频率落窗、复音上限、panic 后峰值恰为 0、释放尾静音、实时余量；页面「运行离线自检」按钮经 OfflineAudioContext 走同一 wasm 验证包络与音高，适用于无音频设备的 CI 环境。

**场景三：程序化控制。** 宿主经 worklet MessagePort 逐条下发 `{type:'note_on', note, vel}`、`{type:'note_off', note}`、`{type:'param', id, value}`，与 Web MIDI 桥接即为硬件键盘接入路径；`{type:'panic'}` 一条消息静音全部声部。

**场景四：DSP 组件复用。** `src/lib` 为纯 MoonBit、零依赖，可在任意后端单独编译；PolyBLEP 振荡器、RBJ 滤波、ADSR、乒乓延迟均为独立结构体，供其他 MoonBit 音频项目直接取用。

## 五、方向与通用性

属应用工具/实时多媒体方向，同时是 MoonBit 音频实时性的参考工程。AudioWorklet 与 wasm 的边界方案（主线程编译字节经 postMessage 入 worklet、线性内存整块取音）可直接迁移到任何 wasm 实时音频项目；开发中实测的两条平台限制——该 worklet 全局作用域无 `fetch`/`URL`、OfflineAudioContext 渲染期间不泵 worklet 消息队列——已写入代码注释，对他人在同一环境避坑有直接参考价值。

## 六、验证与原创性说明

`moon check` 零警告；DSP 库 15 组单元测试通过（闭式断言：包络按采样数精确到位、滤波器脉冲响应和恰为 1、延迟回声落在第 50/100/150 采样、方波 PolyBLEP 符号经数值实验确定无过冲）；内核测试 10 项、浏览器离线自检 3 项与真实演奏均通过；CI（moonbit-community/setup-moonbit）绿灯。信号链为合成器通行结构，PolyBLEP 与 RBJ 系数为公开算法（分别源自 music-dsp 社区惯例与 Audio EQ Cookbook），实现从零手写，未复制任何现有合成器或 DSP 库代码。README 如实声明：吞吐为同权重同算法的测量，非音质评价；暂未实现 MIDI 硬件接入、录音导出与更多效果器，列入后续计划。项目源码采用 Apache-2.0 许可证。

## 七、仓库链接

https://github.com/sdjm5/moonsynth
