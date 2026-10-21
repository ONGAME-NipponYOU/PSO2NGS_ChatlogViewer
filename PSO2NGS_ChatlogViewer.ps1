Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- [設定項目1] ログフォルダのパス ---
# config.iniがない場合は「ドキュメント\SEGA\PHANTASYSTARONLINE2\log_ngs」を使います
$logDir = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "SEGA\PHANTASYSTARONLINE2\log_ngs"

# --- [設定項目2] 外部設定ファイル(config.ini)の読み込み処理 ---
# EXEとして実行した場合はEXEの場所、.ps1として実行した場合はスクリプトの場所でconfig.iniを探します
if ($MyInvocation.MyCommand.CommandType -eq "ExternalScript") {
    $currentDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
} else {
    $currentDir = Split-Path -Parent -Path ([Environment]::GetCommandLineArgs()[0])
}
$configPath = Join-Path $currentDir "config.ini"

# 各種設定のデフォルト値
$fontType = "Meiryo"
$fontSize = 8
$formSize_X = 640
$formSize_Y = 480
$highlightWords = @("緊急", "募集中", "レア") # 強調ワードの初期値

# config.iniが存在する場合のみ、中身を読み取って変数を上書きします
if (Test-Path $configPath) {
    try {
        $iniContent = Get-Content $configPath -Encoding UTF8
        foreach ($line in $iniContent) {
            $trimmedLine = $line.Trim()
            # 「キー=値」の形式かつ、セクション名（[]）でない行を解析
            if ($trimmedLine -match "=" -and -not $trimmedLine.StartsWith("[")) {
                $pair = $trimmedLine.Split("=", 2)
                if ($pair.Count -eq 2) {
                    $key = $pair[0].Trim()
                    $val = $pair[1].Trim()
                    switch ($key) {
                        "LogPath"    { $logDir = $val }
                        "FontType"   { $fontType = $val }
                        "FontSize"   { $fontSize = [int]$val }
                        "FormSize_X" { $formSize_X = [int]$val }
                        "FormSize_Y" { $formSize_Y = [int]$val }
                        "Keywords"   { 
                            # カンマ区切りの文字列を分割して配列に変換
                            $script:highlightWords = $val.Split(",").ForEach({ $_.Trim().Trim('"') }) 
                        }
                    }
                }
            }
        }
    } catch { 
        # 読み込み失敗時はデフォルト設定で続行 
    }
}

# --- [UI構成] メインウィンドウとテキストエリアの作成 ---
$form = New-Object Windows.Forms.Form
$form.Text = "PSO2 NGS Log Monitor"
$form.Size = New-Object Drawing.Size($formSize_X, $formSize_Y)
$form.TopMost = $true # 常に最前面に表示

# 文字表示用のリッチテキストボックス設定
$richTextBox = New-Object Windows.Forms.RichTextBox
$richTextBox.Dock = "Fill"                   # ウィンドウ全体に広げる
$richTextBox.BackColor = [System.Drawing.Color]::FromArgb(255, 0, 10, 40)
$richTextBox.ForeColor = [Drawing.Color]::White
$richTextBox.Font = New-Object Drawing.Font($fontType, $fontSize)
$richTextBox.ReadOnly = $true                 # ユーザーによる編集を禁止
$richTextBox.WordWrap = $true                 # 端で自動折り返し
$form.Controls.Add($richTextBox)

# --- [中核機能] 1行分のログを解析して表示する関数 ---
function Add-LogLine($line) {
    # 空行やヘッダー行(等)を無視
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("[")) { return }
    
    # タブ区切りでデータを分割
    $parts = $line.Split("`t")
    if ($parts.Length -lt 6) { return }

    # 各要素の抽出 (PSO2ログの標準インデックス)
    $time = if ($parts[0] -match "\d{2}:\d{2}:\d{2}") { $matches[0] } else { "00:00:00" }
    $type = $parts[2]   # チャット種別
    $name = $parts[4]   # キャラクター名
    $message = $parts[5] # 発言本文

    # --- キーワード強調判定 ---
    $isHighlight = $false
    foreach ($word in $script:highlightWords) {
        if ($null -ne $word -and $word -ne "" -and $message.Contains($word)) { 
            $isHighlight = $true
            break 
        }
    }

    # --- 名前の幅を揃える計算 (全角2/半角1バイトとして処理) ---
    # 日本語フォントで「:」の位置を縦に揃えるための処理です
    $encoding = [System.Text.Encoding]::GetEncoding(932)
    $currentByteCount = $encoding.GetByteCount($name)
    $maxByteWidth = 24 # 12文字すべて全角の場合の最大幅
    $padding = ""
    if ($currentByteCount -lt $maxByteWidth) { 
        $padding = " " * ($maxByteWidth - $currentByteCount) 
    }
    $fixedName = $name + $padding

    # 最終的な表示形式の組み立て
    $displayText = "[$time] $fixedName : $message`n"

    # --- 種別ごとの文字色設定 ---
    $color = switch ($type) {
        "PUBLIC" { [Drawing.Color]::White }
        "PARTY"  { [Drawing.Color]::SkyBlue }
        "REPLY"  { [Drawing.Color]::HotPink }
        "GUILD"  { [Drawing.Color]::Orange }
        "GROUP"  { [Drawing.Color]::Lime }
        Default  { [Drawing.Color]::LightGray }
    }

    # ウィンドウが表示されている間のみ更新を実行（終了時のエラー防止）
    if ($form.Visible) {
        $richTextBox.SelectionStart = $richTextBox.TextLength
        # 背景色の設定（強調ワードがあれば赤系、なければ黒）
        $richTextBox.SelectionBackColor = if ($isHighlight) { [Drawing.Color]::FromArgb(20, 80, 40, 40) } else { $richTextBox.BackColor }
        $richTextBox.SelectionColor = $color
        $richTextBox.AppendText($displayText)
        
        # 背景色をリセットして最新行へスクロール
        $richTextBox.SelectionBackColor = $richTextBox.BackColor
        $richTextBox.ScrollToCaret()
    }
}

# --- [監視機能] ログファイルを定期的にチェックするタイマー ---
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1000 # 1000ms = 1秒ごとに実行
$script:reader = $null
$script:lastFile = ""

$timer.add_Tick({
    try {
        # 最新のChatLog*.txtを取得
        $currentFile = Get-ChildItem -Path $logDir -Filter "ChatLog*.txt" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        
        if ($null -eq $currentFile) {
            $form.Text = "エラー: ログが見つかりません"
            return
        }

        # 新しいファイルが生成された場合、読み込み対象を切り替え
        if ($currentFile -ne $script:lastFile) {
            if ($null -ne $script:reader) { 
                $script:reader.Close()
                $script:reader.Dispose()
            }
            # PSO2のログはUnicode(UTF-16)なのでエンコードを指定して開く
            $fs = [System.IO.File]::Open($currentFile, 'Open', 'Read', 'ReadWrite')
            $script:reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::Unicode)
            $script:lastFile = $currentFile
            $form.Text = "監視中: " + [System.IO.Path]::GetFileName($currentFile)
        }

        # 未読の行があれば1行ずつ読み取ってAdd-LogLineへ渡す
        while ($null -ne ($line = $script:reader.ReadLine())) {
            Add-LogLine $line
        }
    } catch {
        # タイマー内での予期せぬエラーは無視してアプリの強制終了を防ぐ
    }
})

# --- [終了処理] EXE化した際のリソース解放 ---
$form.add_FormClosing({
    $timer.Stop()
    $timer.Dispose()
    if ($null -ne $script:reader) {
        $script:reader.Close()
        $script:reader.Dispose()
    }
    # ウィンドウを閉じた際、完全にプロセスを終了させる
    [System.Windows.Forms.Application]::Exit()
})

# 画面が表示されたら監視を開始
$form.add_Shown({ $timer.Start() })

# アプリケーションの起動
$form.ShowDialog() | Out-Null