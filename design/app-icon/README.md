# Modu 应用图标 · 柔和杏橙

依据用户标注的「已完成第 1 款『柔和杏橙』精修，最后一张为优化版」中的最后一张图重建，参考图标识为 `exec-9f3c3afe-57ce-4ab6-9f3a-cadf2ba8183c.png`。

- [可编辑 SVG 母稿](modu-soft-apricot-master.svg)：路径、渐变、遮罩与滤镜均保留，不嵌入位图、不依赖字体或外部资源。
- [PNG 预览](modu-soft-apricot-preview.png)：直接从 SVG 渲染，1254 × 1254，包含灰色展示背景。

应用现已接入 [AppIcon.icon](../../ModuDesktop/AppIcon.icon) 的 Icon Composer 版本。上面的 SVG 保留为造型参考母稿；运行时外观由 `.icon` 文档及其内部 SVG 决定。应用界面图标规则见 [DESIGN 第 1.2 节](../../docs/DESIGN.md#12-密度图标与排序)。

## Icon Composer 运行时母稿

[AppIcon.icon](../../ModuDesktop/AppIcon.icon) 可以直接用 Icon Composer 打开。内部 [icon.json](../../ModuDesktop/AppIcon.icon/icon.json) 保留外观覆盖、分组、材质与阴影设置，三个 SVG 位于其 `Assets` 子目录。画布统一为 1024 × 1024，按原母稿底板区域重新设定留白，不包含展示背景、底板遮罩或 SVG 模糊滤镜。

| 外观 | 设计 |
| --- | --- |
| Default | 暖白底；杏橙前层、橙色中央立柱与珊瑚后层；关闭前景强高光，保留轻微原生半透明材质 |
| Dark | 石墨底；沿用暖色主体，保留清晰的内拱和中央折叠 |
| Mono / Clear / Tinted | 前层、珊瑚后层、中央立柱分别使用 `1.00 / 0.82 / 0.58` 的灰度填充，系统生成透明与着色变体；前层启用单色专用高光 |

文档中的组和层按从前到后排列：`Apricot Fold` 在前，`Coral Foundation` 在后；后组内中央立柱覆盖珊瑚轮廓，采用 Combined 材质避免将同一平面当作多个独立玻璃对象。前组原生阴影透明度为 `0.25`、半透明程度为 `0.08`；后组阴影透明度为 `0.12`，关闭半透明。

中央立柱的方向渐变表达折叠处的固有明暗，保留几何边界；环境投影、光照、系统遮罩与材质由 Icon Composer 生成。这一渐变不包含额外的模糊或投影层。单色外观覆盖为三档灰度，避免折叠关系在系统着色后消失。

Xcode 的 Debug / Release 均通过 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` 选择该文档，`ModuDesktop` 文件夹的同步组自动纳入构建。原空白的 `AppIcon.appiconset` 已移除，无需修改 SwiftUI 或手写 `CFBundleIconFile`。

[原生外观预览](modu-native-appearances.png) 由 Apple 随 Icon Composer 提供的 `ictool` 渲染后排版；依次展示 Default、Dark、ClearLight 与 TintedLight。其中单色底色和着色色相由系统预览样式决定。可用 [导出脚本](../../script/export_app_icon_previews.sh) 重新生成各外观 PNG；预览只供设计对照，应用直接编译 `.icon`。

官方说明：[Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)。

## 图层与编辑入口

SVG 使用与参考图一致的 `0 0 1254 1254` 坐标系。宽高可以等比例更改，路径坐标和阴影参数随视图一起缩放。Inkscape 图层名称和标准 SVG 对象 ID 均保留；可用支持 SVG 路径、渐变、遮罩和滤镜的矢量编辑器继续编辑。

| 图层 / ID | 可编辑内容 |
| --- | --- |
| `preview-backdrop` | 灰色展示背景；隐藏该组可导出带透明外缘的图标 |
| `tile-shadows` | 底板的环境投影与接触投影，可分别隐藏 |
| `tile-shape` | 白色底板轮廓，使用三次贝塞尔曲线 |
| `rear-ribbon` | 珊瑚后层轮廓；所有后层裁切引用同一路径 |
| `center-stem` | 中央橙色立柱，保留与前层共用的内拱圆弧 |
| `overlap-shadows` | 上方交叠阴影、中央折叠阴影和端点渐隐遮罩 |
| `front-ribbon` | 杏橙前层轮廓，斜边与内拱在 45° 切点相接 |

## 精调参数

以下尺寸均为母稿坐标单位，颜色、透明度与坐标可直接在 SVG 的 `defs` 中编辑。

| 关注点 | 入口与当前参数 |
| --- | --- |
| 上肩圆角 | 两个主体路径的 `A 36 36` 圆弧；改半径时须同步调整相邻切点 |
| 左内拱 | 圆心 `(501.5, 558.5)`、半径 `64.5`；前层、中央立柱和后层左边界共用该圆弧 |
| 右内拱 | 圆心 `(754, 558)`，水平半径 `63`、垂直半径 `64` |
| 三个圆底 | 左侧 `R56`、中央 `R62.5`、右侧 `R57.5`，保留参考图不同的笔画宽度 |
| 杏橙、珊瑚、中央色 | `apricot-fill`、`coral-fill`、`center-fill` 的渐变色标；`coral-warmth` 控制后层左上暖光 |
| 折叠阴影 | `fold-shadow-falloff`：沿斜边法线淡出，宽度 `46`、颜色 `#81350F`、最大透明度 `0.34` |
| 折叠端点 | `fold-end-fade` 与 `fold-end-mask`：独立控制两端渐隐，不模糊主体轮廓 |
| 后层阴影 | `upper-overlap-shadow`：高斯标准差 `14`、偏移 `(18, 3)`、颜色 `#78351C`、透明度 `0.55` |
| 底板环境投影 | `tile-ambient-shadow`：高斯标准差 `25`、偏移 `(0, 26)`、透明度 `0.20` |
| 底板接触投影 | `tile-contact-shadow`：高斯标准差 `7`、偏移 `(0, 7)`、透明度 `0.10` |

中央阴影采用矢量渐变与端点遮罩，其他阴影使用 SVG 高斯滤镜；所有重叠阴影最终由 `rear-clip` 限制在后层内。修改内拱时需同步调整三处共用圆弧；修改折叠斜边时需同步调整 `fold-shadow`、渐变法线和端点遮罩。底板投影通过引用主体路径更新，无须重复描边。

直接使用 SVG 为权威母稿。若某个编辑器导入时转换或忽略滤镜、遮罩，应对照 PNG 预览检查结果；当前验证使用 Sharp / librsvg 离线渲染，未验证 Figma 导入往返。

## 验证

已对照指定参考图检查整体轮廓、配色与折叠关系，并检查放大的圆角、内拱、阴影末端及小尺寸渲染。SVG 的内部引用、XML 结构与资源独立性均经过检查。PNG 预览由最终 SVG 直接生成。

Icon Composer 文档已在原生编辑器中打开，确认三层、两组及外观覆盖均可继续编辑；六种 Default / Dark / Clear / Tinted 渲染均已成功导出。`./script/build_and_run.sh --verify` 构建和启动通过，编译后的 `Assets.car` 包含 Aqua / DarkAqua 的 `IconGroup`，应用的 `CFBundleIconName` 与 `CFBundleIconFile` 均指向 `AppIcon`。
