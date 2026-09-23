# moonsynth · 黑客松申报书

## 一、项目简介

**moonsynth —— 浏览器端复音合成器机架，DSP 内核全部由 MoonBit 编译为 WebAssembly。**
振荡器、双二阶滤波、ADSR 包络、乒乓延迟逐样本运行在真实音频线程（AudioWorklet）的 wasm 里；屏幕旋钮实时拧参数、计算机键盘/屏上键盘弹奏、五组预置音色、示波器与频谱实时可视化，另有一键离线自检——不用耳朵也能自动断言 DSP 的物理正确性。

## 二、背景与动机

- 浏览器音频生态里 DSP 要么用 JS 写（GC 抖动、JIT 不稳定），要么用 C/Rust 编译（工具链重、和 Web 语义隔阂）。MoonBit 生成高质量 wasm，但「音频这种无分配、硬实时、小帧预算」的场景还没有现成的 MoonBit 先例——我们想把它做出来。
- 关键技术未知数有三个：AudioWorklet 音频线程里怎么加载 wasm；控制事件与音频数据怎么过边界；渲染路径怎么做到零分配以免 GC 打断实时线程。三个都解决并沉淀为文档。
- 目标是把「MoonBit 能做硬实时多媒体」变成一个拧个旋钮就能听见、看得见波形、还能自动验证的现场演示。

## 三、功能亮点

- **8 复音合成器**：双振荡器（正弦/三角/锯齿/方波，独立失谐 cents、可混音）→ 全局滤波（LP/HP/BP + 共振）→ 每声部 ADSR → 主控 → **乒乓延迟**（左右交替回声）。
- **机架 UI**：13 个可拖拽旋钮（纵拖、双击复位、对数/线性曲线、实时数值读出）、波形/滤波类型分段开关、5 组预置（Fat Bass / Dreamy Pad / Pluck / Acid 303…）、PANIC 立即静音。
- **双输入键盘**：屏上钢琴键（鼠标/触摸，按住滑奏）+ 计算机键盘 DAW 式映射（A W S E D…，Z/X 切八度）。
- **实时可视化**：示波器波形 + 对数频谱同屏，复音数徽章（VOICES n/8）每半秒从音频线程回报。
- **离线自检**：OfflineAudioContext 渲染同一 wasm 引擎并断言三件事——攻击段有声（RMS 0.25 > 0.02）、释放后精确静音（RMS 0.00000）、C4 正弦过零率 270/s（理论 261.6）。

## 四、技术架构与实现（MoonBit 技术要点）

1. **`src/lib`** — 纯 MoonBit 可移植 DSP 库：PolyBLEP 振荡器（两采样多项式带限阶跃修正抗混叠）、RBJ 食谱双二阶滤波、线性 ADSR（释放速率在 gate-off 时刻锁定）、双环形缓冲乒乓延迟、8 声部管理（同音重触/空闲复用/最老偷取）。15 个单元测试。
2. **`src/kernel`** — wasm `foreign_library`：`moon_init / note_on / note_off / set_param / panic / voice_count / render`。音频数据经导出线性内存的约定地址整块写出（交织立体声 f32），控制事件是普通导出函数调用——零分配、零拷贝、零锁。
3. **`web/`** — 机架 UI + `audio-worklet.js`（worklet 侧实例化 wasm、逐块取音、回报复音数）+ 零依赖服务器。

**关键技术攻关**（三个未知数逐个实验探明）：

- **worklet 里没有 `fetch` 也没有 `URL`**（内嵌 Chromium 的 AudioWorklet 全局作用域异常精简）——改为**主线程编译 wasm、字节流经 `postMessage` 传入**（`ArrayBuffer` 可结构化克隆），worklet 用裸 `WebAssembly` 实例化。首个静音渲染正是这条路探出来的。
- **OfflineAudioContext 渲染期间不泵 worklet 消息队列**——控制事件必须在 `startRendering()` 前送达并等待处理；包络只在 `process()` 内推进，因此提前 `note_on` 不会偷跑时序。
- **零分配渲染路径**：声部、暂存缓冲、延迟环全部预分配，每块渲染不分配任何对象，wasm GC 永不在音频线程中途打断。
- 另附 MoonBit 工程实录：`init` 是保留的特殊函数名（必须无参），导出构造器改名 `moon_init`；`pub` 类型对测试块只读，数据枚举需 `pub(all)`。

## 五、性能与验证

- **吞吐**：8 复音全响渲染 10 秒立体声音频约 130 ms（Node，debug 构建）——**约 75 倍实时余量**（实时要求 >1×），逐块渲染零分配。
- **质量门槛全绿**：`moon check` 零警告；`moon test` 15/15（包络时序精确值、滤波器 DC 增益恰为 1、延迟回声落在第 50/100/150 采样、PolyBLEP 最大跳变 1.98→1.48、复音上限/偷取/panic）。
- **真实浏览器端到端**：48 kHz、10 ms 基础延迟实时运行；按和弦 VOICES 4/8；示波器/频谱实时跳动；离线自检 PASS（0.25 / 0.00000 / 270）。
- **延迟测试数据都是实测**：`render` 在 Node 与浏览器同一 wasm 上验证。

## 六、运行与演示

```bash
moon build --target wasm
cp _build/wasm/debug/build/src/kernel/kernel.wasm web/synth.wasm
node web/server.mjs 8090
# 打开 http://127.0.0.1:8090
```

30 秒演示脚本：点「▶ 启动音频」→ 选 **Dreamy Pad** → 按住几个键铺底，看示波器与频谱 → 切 **Acid 303** 拧大 RESO、压低 CUTOFF，听共振扫频 → 用计算机键盘弹旋律 → 点 **⚙ 运行离线自检** 看三条 DSP 断言当场通过。

## 七、展望

- **效果器扩展**：混响（Freeverb 梳理/全通网络）、失真、合唱——同一条音频总线继续挂模块；
- **序列器**：步进音序 + 包络自动化，让 demo 脱手演奏；
- **参数自动化总线**：把 `set_param` 升级为音频速率参数（worklet AudioParam 直接采样）；
- **MIDI**：Web MIDI API 接入硬件键盘；
- **生态**：把 `src/lib` 发到 mooncakes.io，作为 MoonBit 的基础 DSP 组件库。
