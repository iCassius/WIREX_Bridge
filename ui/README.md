# WIREX Bridge 离线 UI

这是 WIREX Bridge 第一版 PySide6 桌面 UI 和一份无需依赖安装即可查看的静态评审稿。当前仓库只有 DMRD 数据报与 DIRECT envelope 的纯函数库；本 UI 没有可连接的核心、IPC 或真实设备数据源。

## 启动

在已安装 PySide6 的 Python 环境中运行：

```powershell
python ui\main.py
```

默认画面将核心显示为不可用，电台、WIRES-X、音频和 BrandMeister 显示未知。显式运行 `python ui\main.py --demo` 才会载入本地固定演示快照。演示快照在全窗口持续显示“模拟预览：无核心、无电台连接”，退出后不保存，也不会进入默认状态。

本版本不安装依赖。当前 Codex 附带的 Python 环境没有 PySide6，因此此环境不能打开原生窗口；运行入口会给出提示并退出。安装、连接、应用目标等操作没有后端支持，相关控制项会禁用并说明原因。“停止并退出”和窗口关闭都只关闭这个 UI；本版本没有后台线程、核心进程或设备连接需要收尾。

## 静态视觉评审稿

打开 [preview/index.html](preview/index.html) 即可查看单页稿。页脚可在“未接核心”和“演示通话”之间切换；“设置”打开未来配置结构示意。切换只改本地页面显示。

[设计与验收记录](DESIGN_AND_ACCEPTANCE.md) 说明页面选择、字段来源、核心所需状态、未实现范围和本地验证结果。浏览器截图由 `tools/capture_preview.cjs` 生成；脚本使用已有 Playwright 与 Chrome，读取本地 `file://` 文件，不启动服务、不安装依赖。运行前将 `NODE_PATH` 指向现有 `node_modules`，将 `CHROME_PATH` 指向现有 Chrome。四种状态/窗口组合的截图和验收结果见 [设计与验收记录](DESIGN_AND_ACCEPTANCE.md)。