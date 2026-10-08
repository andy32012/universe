# Godot 版（移植中）

網頁版（`index.html`）的原生重寫，目標是 iPad Pro（M5），使用 Godot 4.7、Forward+、iPad 上走 Metal。計畫與背景見 [`docs/handoff.md`](../docs/handoff.md)。

目前是**第一階段**：銀河系與本星系群（仙女座、三角座、大小麥哲倫雲），第一人稱飛行、望遠鏡、光暈與色調、HDR、升頻、全景圖、記錄檔。

## 跟網頁版一模一樣的做法

- **資料直接取自網頁版。** 網頁版的星點、星雲位置、地標、標籤和雲氣雜訊，都是用同一串固定種子的亂數依序產生的。`tools/export_web_data.py` 會用加了掛鉤的網頁版把這些產生好的資料存到 `data/`，Godot 直接讀取。連跑兩次匯出結果逐位元相同。
- **著色器逐行移植。** `shaders/galaxy_common.gdshaderinc` 是 `GALV_FS`，`stars.gdshader` 是 `PT_VS`/`PT_FS`，`bloom_*.gdshader` 與 `final.gdshader` 是 `downMat`、`upMat`、`finMat`。
- **網頁的合成順序照搬。** 星系依網頁的繪製順序以預乘 alpha 疊加；星點被前方氣體擋掉的比例（網頁合成時的 `1 − v.a`）改在每顆星的頂點著色器算一次，結果相同但便宜很多。
- **sRGB 處理。** 網頁把色調曲線的結果直接寫到 sRGB 畫面；Godot 開 HDR 2D 後在線性空間畫 2D、最後才轉成 sRGB，所以最後一步先把結果解碼成線性，螢幕上看到的數值就和網頁一樣。
- **抖動圖樣。** 網頁每個像素的取樣抖動用 `gl_FragCoord`，WebGL 的列從下往上數、Godot 從上往下，已經翻轉對齊。

**比對結果**（RTX 3060，1376×1032 左右，關閉升頻，同一位置、同一曝光）：

| 位置 | 平均差（0–255） | 差超過 8 階的像素 |
|---|---|---|
| 銀河上方俯瞰 | 1.0 | 0.17% |
| 遠方側看（含仙女座、三角座） | 0.6 | 0.01% |
| 銀河盤面內 | 1.6 | 0.79% |
| 家（地球附近），望遠鏡 10× | 1.2（最大 5） | 0% |

平均差約 1 階，就是網頁版本身每幀隨機的底片顆粒（±1.8 階）；剩下的少數像素是個別星點落在不同像素上。比對工具：`tools/compare.ps1`（同一視角分別用桌機 Chrome 跑網頁版、用 Godot 跑）、`tools/diff_images.gd`。

## 尺度與精確度

Godot 的向量是單精度，GDScript 的數字是雙精度。你的位置 `P`、所有天體位置都以雙精度存在程式裡。每幀相機固定在原點，光年座標系平移 `−P` 並縮放 `1/S`（`S` 是到最近地標的距離），星系則拿到「你相對星系中心、以星系半徑為單位」的位置。這和網頁版的做法相同，大數字不會進到 GPU。

## 畫面的組成

```
World（SubViewport，MetalFX 時間升頻）   天空 = 星系體積（Sky 著色器，Godot 依相機轉動產生動態向量）
Stars（SubViewport，原生解析度）         星點，與 World 共用同一個 World3D，不經過升頻
Down0…Down4、Up3…Up0（巢狀 SubViewport）  網頁的五層光暈
最後一層（根畫面，ColorRect）             色調曲線、暗角、顆粒、HDR 增亮
```

星點放在不升頻的畫面：時間升頻器會把小於一個像素的亮點抹掉或拖影，星點本來就是相加的，分開畫再相加結果完全相同。

## 預設開啟的 M5 功能

- **MetalFX 時間升頻**：`Viewport.SCALING_3D_MODE_METALFX_TEMPORAL`，比例 0.75（夾在裝置回報的 MetalFX 允許範圍內）。桌機上改用 FSR 2，走同一條路徑（動態向量、歷史）。
- **HDR 輸出**：依 Godot 4.7 文件，渲染器 Forward+、iOS 用 Metal、Windows 用 D3D12、開 `rendering/viewport/hdr_2d` 與 `display/window/hdr/request_hdr_output`，色調對應用 Linear（不用 Filmic、ACES，也不用 Glow 的 Soft Light 或 Adjustments）。網頁 `finMat` 的增亮（`OVER0` 1.2、`OVER1` 5.0、×1.25）一起搬過來，上限是 `Window.get_output_max_linear_value()`。設定面板可關。
- **120 Hz**：不限幀率、垂直同步，Info.plist 加 `CADisableMinimumFrameDurationOnPhone`。實際幀率要看 iPad 的記錄檔確認。網頁版刻意把 120 Hz 螢幕限在 60 幀；Godot 版不限。
- **全景圖**（見下）。
- **著色器預先編譯**：匯出設定 `shader_baker/enabled=true`。

## 全景圖（`scripts/panorama.gd`）

在太陽附近，銀河的樣子幾乎不隨位置改變，所以把星系烘焙成一張立方體全景圖，天空每個像素只讀一次貼圖，不必每個像素走 96 步。

- 用**同一支天空著色器**畫六個 90° 的面，在 GPU 上複製進立方體貼圖。每面切成不超過 1280×1280 的小塊，一幀畫一塊，所以重新烘焙時每幀最多多花大約一幀即時畫面的工作量。
- 只有在跟即時畫面分不出來時才用：離烘焙點 0.5 光年以內、星系的淡入淡出與增益沒變、望遠鏡倍率不會讓貼圖比螢幕像素粗。條件不成立時自動改回即時計算；停在新的地方 0.75 秒後會在背景重新烘焙。
- **解析度跟著螢幕算**：讓面中央的貼圖像素不大於 3D 畫面的像素。iPad（2752 高 × 0.75）是每面 4608×4608，半浮點 RGBA，約 **970 MB**；記錄檔裡有實際數字。
- 與即時畫面比對：各方向平均差 1–2 階，最大 4–20 階（在銀河帶上，是兩者取樣抖動的位置不同，不是結構差異）。
- RTX 3060 上，在家裡看銀河：每幀 GPU 時間從 16.8 ms 降到 0.5 ms。

## 光線追蹤

- 設定面板的「光線追蹤」開關，**預設關**。關閉時畫面就是上面比對過的網頁版畫面。
- 偵測：`RenderingDevice.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE)`（Godot 4.7）。不支援時開關變灰並寫「這台裝置目前不支援」。
- 實測：RTX 3060 用 **Vulkan** 驅動偵測得到（`--rendering-driver vulkan`）；用 D3D12 則回報不支援。另一方面 Windows 的 HDR 輸出只有 D3D12 有，所以 Windows 預設仍是 D3D12。iPad 的 Metal 驅動目前應該會回報不支援，以後 Godot 支援了就會自動可用。
- 第一階段只有開關與偵測，沒有任何天體用光線追蹤。第三階段加入碎石群岩塊互相遮擋的陰影、彗星彗核、穀神星、灶神星、貝努的陰影與環境光遮蔽、土星環與行星間的陰影。氣體（星雲、銀河、海王星大氣）與黑洞維持光線步進。
- 記錄檔寫入：支不支援、開關狀態、開與關時每幀 GPU 時間與差值。

## 記錄檔

`user://universe-log.txt`（上一次的是 `universe-log-previous.txt`）。iPad 上在「檔案」App 的 App 資料夾裡（匯出設定開了 `accessible_from_files_app`）；設定面板的「複製記錄檔」會把內容複製到剪貼簿。內容：裝置、GPU、驅動、螢幕與更新率、光線追蹤、升頻、HDR、全景圖大小與記憶體；每 5 秒的幀率、最慢一幀、每個畫面的 GPU 時間、遊戲程式時間、位置、曝光、顯示記憶體。

## 在電腦上執行與檢查

```bash
godot --path godot
```

命令列參數（放在 `--` 之後），用來比對與量測：`--pos=x,y,z`（光年）、`--face=x,y,z`、`--tele=N`、`--expo=N`、`--bright=0|1|2`、`--upscale=off|fsr2|metalfx_temporal`、`--scale=0.75`、`--pano=on|off`、`--hdr=on|off`、`--rt=on|off`、`--noui`、`--shot=檔名.png`、`--frames=N`、`--seconds=N`、`--raw`。

## iPad 版

`.github/workflows/godot-ios.yml` 在 GitHub 的 Mac 上用 Godot 匯出 Xcode 專案（開 shader baker），再不簽名編譯成 `Universe-Godot-unsigned.ipa`，跟現有 App 一樣用 Sideloadly 安裝。Bundle ID 是 `io.github.andy32012.universe.godot`，跟網頁外殼 App 分開，兩個可以同時裝（免費 Apple ID 最多 3 個 App）。

## 量測（RTX 3060 筆電，1376×1032）

| 位置 | 設定 | GPU 每幀 | 銀河 | 星點 |
|---|---|---|---|---|
| 家 | 即時、不升頻 | 16.8 ms | 16.5 | 0.07 |
| 家 | 即時、FSR 2 0.75 | 10.7 ms | 10.3 | 0.08 |
| 家 | 全景圖、不升頻 | 0.48 ms | 0.16 | 0.08 |
| 銀河上方 | 即時、不升頻 | 22.0 ms | 19.4 | 2.4 |
| 盤面內 | 即時、不升頻 | 20.0 ms | 17.0 | 2.7 |
| 盤面內 | 即時、FSR 2 0.75 | 13.9 ms | 10.9 | 2.8 |

遊戲程式本身每幀約 1.5 ms。

## 已知的待辦

- iPad 實機數據（幀率、120 Hz、MetalFX、HDR、全景圖記憶體）要等第一個 iPad 版的記錄檔。
- 用全景圖時天空本身很便宜，這時 MetalFX 反而多花時間（桌機 FSR 2：0.48 → 0.99 ms）；之後可考慮用全景圖時改回原生解析度。
- 飛行中（即時計算）MetalFX 拿到的天空動態向量只含轉動，不含平移；在星系內高速飛行時可能看得到拖影，要在 iPad 上看。
- 星點每顆在頂點著色器走一次星系（46,860 顆，約 2.7 ms）；可改成只在你移動時重算並存起來。
- 標籤沒有網頁版的小圓點；按鈕外觀還是 Godot 預設。介面在第四階段整理。
