# Universe: From the Solar System to the Edge of the Cosmos

Fly in first person from the Solar System all the way to the edge of the observable universe.

The whole project is a single `index.html` file. Nothing to install: open it in a browser and it runs.

## What is real

- **Solar System:** planet orbit sizes, their approximate current positions, and the true sizes of each body.
- **Stars:** 3D positions and brightness of 16,166 real stars from the [HYG Database](https://github.com/astronexus/HYG-Database).
- **Deep sky:** directions and distances of named nebulae, galaxies, galaxy clusters and black holes (some coordinates are approximate).

The remaining stars, the unnamed nebulae along the spiral arms, and the cosmic web are generated procedurally to follow real distributions.

## Credits

- Star data: [HYG Database](https://github.com/astronexus/HYG-Database), CC BY-SA 4.0. A 16,166-star subset converted to galactic coordinates is embedded in this project and is also licensed under CC BY-SA 4.0.
- Textures for the Sun, planets, Moon and Saturn's rings: [Solar System Scope](https://www.solarsystemscope.com/textures/), CC BY 4.0 (recompressed and resized).
- Rendering: [three.js](https://github.com/mrdoob/three.js) r128, MIT.
- Black hole ray tracing approach based on [oseiskar/black-hole](https://github.com/oseiskar/black-hole) (MIT).
- Atmospheric scattering based on [wwwtyro/glsl-atmosphere](https://github.com/wwwtyro/glsl-atmosphere) (public domain).

## License

The source code is released under the [MIT License](LICENSE). The embedded star data and textures keep their original licenses listed above.

---

# 從太陽系到宇宙邊緣（中文）

以第一人稱在宇宙中飛行：從太陽系一路到可觀測宇宙的邊界。

整個作品是 `index.html` 一個檔案，不需要安裝任何東西，用瀏覽器打開就能執行。

## 資料與程式來源

- 恆星位置、亮度、顏色：[HYG Database](https://github.com/astronexus/HYG-Database)，CC BY-SA 4.0。本專案內嵌的是其中 16,166 顆恆星的子集，並轉換為銀河座標；這份內嵌資料同樣以 CC BY-SA 4.0 授權。
- 太陽、行星、月球、土星環的表面貼圖：[Solar System Scope](https://www.solarsystemscope.com/textures/)，CC BY 4.0。貼圖經過重新壓縮與縮放。
- 繪圖函式庫：[three.js](https://github.com/mrdoob/three.js) r128，MIT。
- 黑洞光線追蹤的做法參考 [oseiskar/black-hole](https://github.com/oseiskar/black-hole)（MIT）。
- 大氣散射的算法參考 [wwwtyro/glsl-atmosphere](https://github.com/wwwtyro/glsl-atmosphere)（公有領域）。

## 哪些是真的

- 太陽系：行星軌道大小與目前的大致位置、各天體的實際尺寸。
- 16,166 顆恆星的三維位置與亮度。
- 有名字的星雲、星系、星系團、黑洞的方向與距離（部分座標為近似值）。

其餘的恆星、旋臂上未命名的星雲、宇宙網，是依照真實的分布規律生成的。

## 授權

程式碼以 [MIT 授權](LICENSE) 釋出。內嵌的恆星資料與貼圖沿用上面列出的原始授權。
