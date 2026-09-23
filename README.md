# MeloX-CyMusic-Source

基于 MeloX 的个人实验项目，目标是在保留 MeloX 原生 SwiftUI 界面与播放器的前提下，增加 CyMusic/LX Music 自定义音源支持。

## 当前进度

当前分支包含 MeloX 上游工程基底、`MeloXSource/` 音源模型/本地存储/JavaScriptCore 运行器原型，以及未签名 iOS IPA 的 GitHub Actions 工作流。

**音源功能尚未完成接入**：运行器目前是协议原型，尚未兼容 CyMusic/LX 的完整异步请求桥、加密工具和回调协议；源码也尚未纳入 Xcode Target，未接入 MeloX 播放源解析和设置 UI。因此当前构建仍是 MeloX 基础应用，不代表音源功能已可用。

## 构建

仓库包含 `.github/workflows/build-unsigned.yml`，可从 Actions 手动运行构建未签名 IPA。MeloX 要求 Xcode 26.6+、iOS 26.0+。

## 许可证

MeloX 主体为 GPLv3。第三方代码、字体、模型及 PV Tool 资源仍适用各自许可证，详情见对应 NOTICE/LICENSE 文件。CyMusic 自有源码为 Apache-2.0；其 `@rntp/player` 有独立许可证。本实验分支不包含 RNTP。
