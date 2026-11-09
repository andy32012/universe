# 100 顆系外行星：分階段實作

## 目前狀態
本分支完成**第一階段資料管線與 Godot 讀取驗證器**，**尚未加入 100 顆可遊玩的行星**。
原網頁開發分支已包含 215 顆系外行星；不能把這次目標誤算成新增 100 顆。
第二階段先比對名稱與既有資料，避免重複，再建立兩版共用的清單與渲染接線。

## 來源與重現
使用 NASA Exoplanet Archive 的 Planetary Systems Composite Parameters（pscomppars），不是自造資料。
下載網址（可直接在瀏覽器開啟）：
https://exoplanetarchive.ipac.caltech.edu/TAP/sync?query=select%20pl_name%2Chostname%2Cdisc_year%2Cpl_rade%2Cpl_bmasse%2Cpl_orbper%2Cpl_orbsmax%2Csy_dist%2Cra%2Cdec%2Cst_teff%2Cst_rad%20from%20pscomppars&format=json

儲存為 `nasa_pscomppars.json`，執行：
```sh
python tools/planet_catalog.py --input nasa_pscomppars.json --output assets/planet-catalog-100.json
```
建置時再將已驗證 JSON 複製到 `godot/data/planet-catalog-100.json`。**不可在未下載資料時假造 100 筆。**

## 品質規則
必須有名稱、母恆星、半徑、公轉週期、距離、赤經赤緯；優先額外具備質量、軌道半長軸、恆星溫度及半徑者，再依距離排序。資料欄位是 NASA 彙整值，可能包含推算，不能一律標為直接量測。未知的表面及軌道朝向只能標示為視覺示意。距離與方向也不等於精密三維即時軌道。

## 接下來
1. 下載並保存 100 筆資料，檢查資料來源、版本日期與原網頁 215 顆的重複情況。
2. 網頁版增加可搜尋的行星資料索引，延用原有近距離才建立模型的機制。
3. Godot 增加母恆星、行星渲染、相機導航、資訊卡；距離換算保持 64 位元。
4. 驗證桌機 WebGL、Godot 編輯器與 iPad 實機幀率、記憶體及導航，才考慮合併主分支。
