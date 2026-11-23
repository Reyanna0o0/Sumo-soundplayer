# 第三方材料与重建说明

HibikiCore 是本项目维护的业务源码，不是外购的完整播放器。系统媒体播放与读写主要由 Apple 框架提供；下表说明另外使用的组件。

| 组件 | 用途 / 版本 | 许可与材料 |
| --- | --- | --- |
| LAME | 已保存摘选编码为 MP3；4.0 | LGPL v2 或后续版本；`ThirdParty/Lame/lame-4.0/` 保存完整未修改上游源码，本地适配位于同级 `Package.swift`、`config/`、`include/` |
| FFmpeg | 有限 AVI 读取和 MOV 重封装；n8.0.1 | 附带完整 `ThirdParty/FFmpeg/ffmpeg-n8.0.1.tar.gz`；当前构建未启用 GPL / nonfree，许可副本位于 `VideoSupport/LICENSE-FFmpeg.txt` |
| Depth Anything V2 Small | 图片深度估计；F16 Core ML | Apache 2.0；模型完整放在 App Resources，许可、NOTICE 和原模型说明位于 `ThirdParty/DepthAnythingV2/` |
| ZIPFoundation | 普通 ZIP 解包；0.9.20 | MIT；通过 SwiftPM 精确锁定，App 资源内保留许可副本 |

来源：

- [LAME 官方项目](https://lame.sourceforge.io/download.php)，原归档 SHA-256 与逐文件校验在 `ThirdParty/Lame/provenance.json`。上游源码内自带的 `mac/.DS_Store` 也按原 hash 保留，它不是本地用户生成的 Finder 文件。
- [FFmpeg n8.0.1 官方源码](https://github.com/FFmpeg/FFmpeg/tree/n8.0.1)，归档来自 `https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/n8.0.1`，SHA-256 为 `679aa13a19415d5ddab91e580084e3ab20c963c8240001e5cbb955a97bdd81b1`。
- [Apple 发布的 Core ML 模型](https://huggingface.co/apple/coreml-depth-anything-v2-small/tree/cfef6f6f2a70783dedc0bfae40cecbc2052285d3)，revision 固定为 `cfef6f6f2a70783dedc0bfae40cecbc2052285d3`。未附训练或转换流水线；构建 App 复用该未修改模型。
- [ZIPFoundation 0.9.20](https://github.com/weichsel/ZIPFoundation/tree/22787ffb59de99e5dc1fbfe80b19c97a904ad48d)，精确 revision 写在共享 `Package.resolved`。

`scripts/verify-resources.py` 校验上述本地材料。应用设置中的“开源许可”展示随包文本。

LAME 和 FFmpeg 采用静态链接。本仓库包含 App 对应源码、LAME 源码和适配、FFmpeg 完整源归档与构建选项，以及[替换组件后重新构建和链接的方法](BUILD.md#修改第三方组件后重建)。应用 [LICENSE 第 5 条](../LICENSE) 明确保留适用 LGPL 所要求的为自身使用修改作品、调试修改、替换组件和重新链接的权利；这些权利不受应用新增的商业审批要求限制。第三方组件自身继续按上游许可使用，不要求另外向本项目维护者申请商业授权。

分发官方或修改版 IPA 时，应同时提供该二进制的完整对应源码、必要的适配及构建材料和许可；仅提供许可文字或不对应该版本的源码链接不足以代替这些材料。公开 Release 应在同一下载位置提供可取得的对应源材料，并区分实际二进制源码提交与之后仅修改文档的提交。[LGPL 2.1 第 6 条](https://choosealicense.com/licenses/lgpl-2.1/)、[FFmpeg 官方许可说明](https://www.ffmpeg.org/legal.html)
