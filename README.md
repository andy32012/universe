# 從太陽系到宇宙邊緣

以第一人稱在宇宙中飛行：從太陽系一路到可觀測宇宙的邊界。

整個作品是 `index.html` 一個檔案，不需要安裝任何東西，用瀏覽器打開就能執行。

放在網站上（http 或 https）時，可以從瀏覽器「加到主畫面」安裝。`sw.js` 會把整個作品存一份在裝置上，之後沒有網路也能打開；直接用瀏覽器打開本機檔案時不會用到它。更新 `sw.js` 裡的檔案清單時，記得一起改 `VERSION`。

右上角的「畫質」可以選自動、標準、高、極致。自動會從「高」開始，畫面變卡時自動往下調；高和極致會開啟反鋸齒、讓星雲和星系取樣更多、行星更圓、黑洞的光線追蹤更細。選擇會記在這台裝置上。

## 資料與程式來源

- 恆星位置、亮度、顏色：[HYG Database](https://github.com/astronexus/HYG-Database)，CC BY-SA 4.0。本專案內嵌的是其中 16,166 顆恆星的子集，並轉換為銀河座標；這份內嵌資料同樣以 CC BY-SA 4.0 授權。
- 太陽、行星、月球、土星環的表面貼圖：[Solar System Scope](https://www.solarsystemscope.com/textures/)，CC BY 4.0。貼圖經過重新壓縮與縮放。
- 繪圖函式庫：[three.js](https://github.com/mrdoob/three.js) r128，MIT。
- 黑洞光線追蹤的做法參考 [oseiskar/black-hole](https://github.com/oseiskar/black-hole)（MIT）。
- 大氣散射的算法參考 [wwwtyro/glsl-atmosphere](https://github.com/wwwtyro/glsl-atmosphere)（公有領域）。
- 行星與冥王星的軌道根數：E. M. Standish（JPL），[Keplerian Elements for Approximate Positions of the Major Planets](https://ssd.jpl.nasa.gov/planets/approx_pos.html)，適用 1800–2050 年。
- 月球位置的算法參考 Paul Schlyter，[How to compute planetary positions](https://stjarnhimlen.se/comp/ppcomp.html)。

## 哪些是真的

- 太陽系：八大行星和冥王星真實的橢圓軌道（包含傾角），以及打開頁面當下的位置；跟完整星曆比對，2000–2050 年間誤差在 0.2° 以內。
- 月球：當下的位置和月相，誤差在 0.1° 以內。
- 各天體的實際尺寸。
- 16,166 顆恆星的三維位置與亮度。
- 有名字的星雲、星系、星系團、黑洞的方向與距離（部分座標為近似值）。

其餘的恆星、旋臂上未命名的星雲、宇宙網，是依照真實的分布規律生成的。
